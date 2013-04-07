require 'active_support/core_ext/object/inclusion'

module ActiveRecord::Associations::Builder
  class HasManyPolymorphs < CollectionAssociation #:nodoc:
    self.macro = :has_many_polymorphs

    self.valid_options += [:from, :through, :as, :conflicts, :polymorphic_key, :association_foreign_key, :polymorphic_type_key, :skip_duplicates, :dependent, :join_class_name, :table_aliases, :join_extend, :parent_extend]

    def build
      validate_options
      reflection = create_has_many_polymorphs_reflection(name, options, &block_extension)
      define_readers
      reflection
    end


    private

    # Composed method that assigns option defaults,  builds the reflection
    # object, and sets up all the related associations on the parent, join,
    # and targets.
    def create_has_many_polymorphs_reflection(association_id, options, &extension) #:nodoc:
      options.assert_valid_keys(
          :from,
          :as,
          :through,
          :foreign_key,
          :foreign_type_key,
          :polymorphic_key, # same as :association_foreign_key
          :polymorphic_type_key,
          :dependent, # default :destroy, only affects the join table
          :skip_duplicates, # default true, only affects the polymorphic collection
          :ignore_duplicates, # deprecated
          :is_double,
          :rename_individual_collections,
          :reverse_association_id, # not used
          :singular_reverse_association_id,
          :conflicts,
          :extend,
          :join_class_name,
          :join_extend,
          :parent_extend,
          :table_aliases,
          :select, # applies to the polymorphic relationship
          :conditions, # applies to the polymorphic relationship, the children, and the join
          # :include,
          :parent_conditions,
          :parent_order,
          :order, # applies to the polymorphic relationship, the children, and the join
          :group, # only applies to the polymorphic relationship and the children
          :limit, # only applies to the polymorphic relationship and the children
          :offset, # only applies to the polymorphic relationship
          :parent_order,
          :parent_group,
          :parent_limit,
          :parent_offset,
          # :source,
          :namespace,
          :uniq, # XXX untested, only applies to the polymorphic relationship
          # :finder_sql,
          # :counter_sql,
          # :before_add,
          # :after_add,
          # :before_remove,
          # :after_remove
          :dummy
      )

      # validate against the most frequent configuration mistakes
      verify_pluralization_of(association_id)
      raise PolymorphicError, ":from option must be an array" unless options[:from].is_a? Array
      options[:from].each{|plural| verify_pluralization_of(plural)}

      options[:as] ||= model.name.demodulize.underscore.to_sym
      options[:conflicts] = Array(options[:conflicts])
      options[:foreign_key] ||= "#{options[:as]}_id"

      options[:association_foreign_key] =
          options[:polymorphic_key] ||= "#{association_id._singularize}_id"
      options[:polymorphic_type_key] ||= "#{association_id._singularize}_type"

      if options.has_key? :ignore_duplicates
        _logger_warn "DEPRECATION WARNING: please use :skip_duplicates instead of :ignore_duplicates"
        options[:skip_duplicates] = options[:ignore_duplicates]
      end
      options[:skip_duplicates] = true unless options.has_key? :skip_duplicates
      options[:dependent] = :destroy unless options.has_key? :dependent
      options[:conditions] = model.send(:sanitize_sql,options[:conditions])

      # options[:finder_sql] ||= "(options[:polymorphic_key]

      options[:through] ||= build_join_table_symbol(association_id, (options[:as]._pluralize or model.table_name))

      # set up namespaces if we have a namespace key
      # XXX needs test coverage
      if options[:namespace]
        namespace = options[:namespace].to_s.chomp("/") + "/"
        options[:from].map! do |child|
          "#{namespace}#{child}".to_sym
        end
        options[:through] = "#{namespace}#{options[:through]}".to_sym
      end

      options[:join_class_name] ||= options[:through]._classify
      options[:table_aliases] ||= build_table_aliases([options[:through]] + options[:from])
      options[:select] ||= build_select(association_id, options[:table_aliases])

      options[:through] = "#{options[:through]}_as_#{options[:singular_reverse_association_id]}" if options[:singular_reverse_association_id]
      options[:through] = demodulate(options[:through]).to_sym

      options[:extend] = spiked_create_extension_module(association_id, Array(options[:extend]) + Array(extension))
      options[:join_extend] = spiked_create_extension_module(association_id, Array(options[:join_extend]), "Join")
      options[:parent_extend] = spiked_create_extension_module(association_id, Array(options[:parent_extend]), "Parent")

      options[:joins] = construct_joins
      

      # create the reflection object
      model.create_reflection(:has_many_polymorphs, association_id, options, model).tap do |reflection|
        # set up the other related associations
        create_join_association(association_id, reflection)
        create_has_many_through_associations_for_parent_to_children(association_id, reflection)
        create_has_many_through_associations_for_children_to_parent(association_id, reflection)
      end
    end


    # table mapping for use at the instantiation point

    def build_table_aliases(from)
      # for the targets
      {}.tap do |aliases|
        from.map(&:to_s).sort.map(&:to_sym).each_with_index do |plural, t_index|
          begin
            table = plural._as_class.table_name
          rescue NameError => e
            raise PolymorphicError, "Could not find a valid class for #{plural.inspect} (tried #{plural.to_s._classify}). If it's namespaced, be sure to specify it as :\"module/#{plural}\" instead."
          end
          begin
            plural._as_class.columns.map(&:name).each_with_index do |field, f_index|
              aliases["#{table}.#{field}"] = "t#{t_index}_r#{f_index}"
            end
          rescue ActiveRecord::StatementInvalid => e
            _logger_warn "Looks like your table doesn't exist for #{plural.to_s._classify}.\nError #{e}\nSkipping..."
          end
        end
      end
    end

    def build_select(association_id, aliases)
      # <tt>instantiate</tt> has to know which reflection the results are coming from
      (["\'#{model.name}\' AS polymorphic_parent_class",
        "\'#{association_id}\' AS polymorphic_association_id"] +
          aliases.map do |table, _alias|
            "#{table} AS #{_alias}"
          end.sort).join(", ")
    end

    def construct_joins(custom_joins = nil) #:nodoc:
                                            # build the string of default joins
      "JOIN #{model.quoted_table_name} AS polymorphic_parent ON #{options[:through]}.#{options[:foreign_key]} = polymorphic_parent.#{model.primary_key} " +
          options[:from].map do |plural|
            klass = plural._as_class
            "LEFT JOIN #{klass.quoted_table_name} ON #{options[:through]}.#{options[:polymorphic_key]} = #{klass.quoted_table_name}.#{klass.primary_key} AND #{options[:through]}.#{options[:polymorphic_type_key]} = #{klass.quote_value(klass.base_class.name)}"
          end.uniq.join(" ") + " #{custom_joins}"
    end

    # method sub-builders

    def create_join_association(association_id, reflection)

      options = {
          :foreign_key => reflection.options[:foreign_key],
          :dependent => reflection.options[:dependent],
          :class_name => reflection.klass.name,
          :extend => reflection.options[:join_extend]
          # :limit => reflection.options[:limit],
          # :offset => reflection.options[:offset],
          # :order => devolve(association_id, reflection, reflection.options[:order], reflection.klass, true),
          # :conditions => devolve(association_id, reflection, reflection.options[:conditions], reflection.klass, true)
      }

      if reflection.options[:foreign_type_key]
        type_check = "#{reflection.options[:join_class_name].constantize.quoted_table_name}.#{reflection.options[:foreign_type_key]} = #{quote_value(model.base_class.name)}"
        conjunction = options[:conditions] ? " AND " : nil
        options[:conditions] = "#{options[:conditions]}#{conjunction}#{type_check}"
        options[:as] = reflection.options[:as]
      end

      model.has_many(reflection.options[:through], options)

      inject_before_save_into_join_table(association_id, reflection)
    end

    def inject_before_save_into_join_table(association_id, reflection)
      sti_hook = "sti_class_rewrite"
      polymorphic_type_key = reflection.options[:polymorphic_type_key]

      reflection.klass.class_eval %{
          unless [self._save_callbacks.map(&:raw_filter)].flatten.include?(:#{sti_hook})
            before_save :#{sti_hook}

            def #{sti_hook}
              self.send(:#{polymorphic_type_key}=, self.#{polymorphic_type_key}.constantize.base_class.name)
            end
          end
        }
    end

    def create_has_many_through_associations_for_children_to_parent(association_id, reflection)

      child_pluralization_map(association_id, reflection).each do |plural, singular|
        if singular == reflection.options[:as]
          raise PolymorphicError, if reflection.options[:is_double]
                                    "You can't give either of the sides in a double-polymorphic join the same name as any of the individual target classes."
                                  else
                                    "You can't have a self-referential polymorphic has_many :through without renaming the non-polymorphic foreign key in the join model."
                                  end
        end

        parent = model
        plural._as_class.instance_eval do
          # this shouldn't be called at all during doubles; there is no way to traverse to a double polymorphic parent (XXX is that right?)
          unless reflection.options[:is_double] or reflection.options[:conflicts].include? self.name.tableize.to_sym

            # the join table
            through = "#{reflection.options[:through]}#{'_as_child' if parent == self}".to_sym
            has_many(through,
                     :as => association_id._singularize,
                     #                :source => association_id._singularize,
                     # :source_type => reflection.options[:polymorphic_type_key],
                     :class_name => reflection.klass.name,
                     :dependent => reflection.options[:dependent],
                     :extend => reflection.options[:join_extend],
                     #              :limit => reflection.options[:limit],
                     #              :offset => reflection.options[:offset],
                     :order => devolve(association_id, reflection, reflection.options[:parent_order], reflection.klass),
                     :conditions => devolve(association_id, reflection, reflection.options[:parent_conditions], reflection.klass)
            )

            # the association to the target's parents
            association = "#{reflection.options[:as]._pluralize}#{"_of_#{association_id}" if reflection.options[:rename_individual_collections]}".to_sym
            has_many(association,
                     :through => through,
                     :class_name => parent.name,
                     :source => reflection.options[:as],
                     :foreign_key => reflection.options[:foreign_key],
                     :extend => reflection.options[:parent_extend],
                     :conditions => reflection.options[:parent_conditions],
                     :order => reflection.options[:parent_order],
                     :offset => reflection.options[:parent_offset],
                     :limit => reflection.options[:parent_limit],
                     :group => reflection.options[:parent_group])

#                debugger if association == :parents
#
#                nil

          end
        end
      end
    end

    def create_has_many_through_associations_for_parent_to_children(association_id, reflection)
      child_pluralization_map(association_id, reflection).each do |plural, singular|
        #puts ":source => #{child}"
        current_association = demodulate(child_association_map(association_id, reflection)[plural])
        source = demodulate(singular)

        if reflection.options[:conflicts].include? plural
          # XXX check this
          current_association = "#{association_id._singularize}_#{current_association}" if reflection.options[:conflicts].include? model.name.tableize.to_sym
          source = "#{source}_as_#{association_id._singularize}".to_sym
        end

        # make push/delete accessible from the individual collections but still operate via the general collection
        extension_module = model.class_eval %[
            module #{model.name + current_association._classify + "PolymorphicChildAssociationExtension"}
              def push *args; proxy_owner.send(:#{association_id}).send(:push, *args); self; end
              alias :<< :push
              def delete *args; proxy_owner.send(:#{association_id}).send(:delete, *args); end
              def clear; proxy_owner.send(:#{association_id}).send(:clear, #{singular._classify}); end
              self
            end]

        model.has_many(current_association.to_sym,
                 :through => reflection.options[:through],
                 :source => association_id._singularize,
                 :source_type => plural._as_class.base_class.name,
                 :class_name => plural._as_class.name, # make STI not conflate subtypes
                 :extend => (Array(extension_module) + reflection.options[:extend]),
                 :limit => reflection.options[:limit],
                 #        :offset => reflection.options[:offset],
                 :order => model.send(:devolve,association_id, reflection, reflection.options[:order], plural._as_class),
                 :conditions => model.send(:devolve,association_id, reflection, reflection.options[:conditions], plural._as_class),
                 :group => model.send(:devolve, association_id, reflection, reflection.options[:group], plural._as_class)
        )

      end
    end

    # some support methods

    def child_pluralization_map(association_id, reflection)
      Hash[*reflection.options[:from].map do |plural|
        [plural,  plural._singularize]
      end.flatten]
    end

    def child_association_map(association_id, reflection)
      Hash[*reflection.options[:from].map do |plural|
        [plural, "#{association_id._singularize.to_s + "_" if reflection.options[:rename_individual_collections]}#{plural}".to_sym]
      end.flatten]
    end

    def demodulate(s)
      s.to_s.gsub('/', '_').to_sym
    end

    def build_join_table_symbol(association_id, name)
      [name.to_s, association_id.to_s].sort.join("_").to_sym
    end

    def all_classes_for(association_id, reflection)
      klasses = [model, reflection.klass, *child_pluralization_map(association_id, reflection).keys.map(&:_as_class)]
      klasses += klasses.map(&:base_class)
      klasses.uniq
    end



    def verify_pluralization_of(sym)
      sym = sym.to_s
      singular = sym.singularize
      plural = singular.pluralize
      raise PolymorphicError, "Pluralization rules not set up correctly. You passed :#{sym}, which singularizes to :#{singular}, but that pluralizes to :#{plural}, which is different. Maybe you meant :#{plural} to begin with?" unless sym == plural
    end

    def spiked_create_extension_module(association_id, extensions, identifier = nil)
      module_extensions = extensions.select{|e| e.is_a? Module}
      proc_extensions = extensions.select{|e| e.is_a? Proc }

      # support namespaced anonymous blocks as well as multiple procs
      proc_extensions.each_with_index do |proc_extension, index|
        module_name = "#{model.to_s}#{association_id._classify}Polymorphic#{identifier}AssociationExtension#{index}"
        the_module = model.class_eval "module #{module_name}; self; end" # XXX hrm
        the_module.class_eval &proc_extension
        module_extensions << the_module
      end
      module_extensions
    end

  end
end
