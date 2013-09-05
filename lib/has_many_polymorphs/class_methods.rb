module ActiveRecord #:nodoc:
  module Associations #:nodoc:

=begin rdoc

Class methods added to ActiveRecord::Base for setting up polymorphic associations.

== Notes

STI association targets must enumerated and named. For example, if Dog and Cat both inherit from Animal, you still need to say <tt>[:dogs, :cats]</tt>, and not <tt>[:animals]</tt>.

Namespaced models follow the Rails <tt>underscore</tt> convention. ZooAnimal::Lion becomes <tt>:'zoo_animal/lion'</tt>.

You do not need to set up any other associations other than for either the regular method or the double. The join associations and all individual and reverse associations are generated for you. However, a join model and table are required.

There is a tentative report that you can make the parent model be its own join model, but this is untested.

=end
   module PolymorphicClassMethods

     RESERVED_DOUBLES_KEYS = [:conditions, :order, :limit, :offset, :extend, :skip_duplicates,
                                   :join_extend, :dependent, :rename_individual_collections,
                                   :namespace] #:nodoc:

=begin rdoc

This method creates a doubled-sided polymorphic relationship. It must be called on the join model:

  class Devouring < ActiveRecord::Base
    belongs_to :eater, :polymorphic => true
    belongs_to :eaten, :polymorphic => true

    acts_as_double_polymorphic_join(
      :eaters => [:dogs, :cats],
      :eatens => [:cats, :birds]
    )
  end

The method works by defining one or more special <tt>has_many_polymorphs</tt> association on every model in the target lists, depending on which side of the association it is on. Double self-references will work.

The two association names and their value arrays are the only required parameters.

== Available options

These options are passed through to targets on both sides of the association. If you want to affect only one side, prepend the key with the name of that side. For example, <tt>:eaters_extend</tt>.

<tt>:dependent</tt>:: Accepts <tt>:destroy</tt>, <tt>:nullify</tt>, or <tt>:delete_all</tt>. Controls how the join record gets treated on any association delete (whether from the polymorph or from an individual collection); defaults to <tt>:destroy</tt>.
<tt>:skip_duplicates</tt>:: If <tt>true</tt>, will check to avoid pushing already associated records (but also triggering a database load). Defaults to <tt>true</tt>.
<tt>:rename_individual_collections</tt>:: If <tt>true</tt>, all individual collections are prepended with the polymorph name, and the children's parent collection is appended with <tt>"\_of_#{association_name}"</tt>.
<tt>:extend</tt>:: One or an array of mixed modules and procs, which are applied to the polymorphic association (usually to define custom methods).
<tt>:join_extend</tt>:: One or an array of mixed modules and procs, which are applied to the join association.
<tt>:conditions</tt>:: An array or string of conditions for the SQL <tt>WHERE</tt> clause.
<tt>:order</tt>:: A string for the SQL <tt>ORDER BY</tt> clause.
<tt>:limit</tt>:: An integer. Affects the polymorphic and individual associations.
<tt>:offset</tt>:: An integer. Only affects the polymorphic association.
<tt>:namespace</tt>:: A symbol. Prepended to all the models in the <tt>:from</tt> and <tt>:through</tt> keys. This is especially useful for Camping, which namespaces models by default.

=end
      def acts_as_double_polymorphic_join options={}, &extension

        collections, options = extract_double_collections(options)

        # handle the block
        options[:extend] = (if options[:extend]
          Array(options[:extend]) + [extension]
        else
          extension
        end) if extension

        collection_option_keys = make_general_option_keys_specific!(options, collections)

        join_name = self.name.tableize.to_sym
        collections.each do |association_id, children|
          parent_hash_key = (collections.keys - [association_id]).first # parents are the entries in the _other_ children array

          begin
            parent_foreign_key = self.reflect_on_association(parent_hash_key._singularize).active_record_primary_key
          rescue NoMethodError
            raise PolymorphicError, "Couldn't find 'belongs_to' association for :#{parent_hash_key._singularize} in #{self.name}." unless parent_foreign_key
          end

          parents = collections[parent_hash_key]
          conflicts = (children & parents) # set intersection
          parents.each do |plural_parent_name|

            parent_class = plural_parent_name._as_class
            singular_reverse_association_id = parent_hash_key._singularize

            internal_options = {
              :is_double => true,
              :from => children,
              :as => singular_reverse_association_id,
              :through => join_name.to_sym,
              :foreign_key => parent_foreign_key,
              :foreign_type_key => parent_foreign_key.to_s.sub(/_id$/, '_type'),
              :singular_reverse_association_id => singular_reverse_association_id,
              :conflicts => conflicts
            }

            general_options = Hash[*options._select do |key, value|
              collection_option_keys[association_id].include? key and !value.nil?
            end.map do |key, value|
              [key.to_s[association_id.to_s.length+1..-1].to_sym, value]
            end._flatten_once] # rename side-specific options to general names

            general_options.each do |key, value|
              # avoid clobbering keys that appear in both option sets
              if internal_options[key]
                general_options[key] = Array(value) + Array(internal_options[key])
              end
            end

            parent_class.send(:has_many_polymorphs, association_id, internal_options.merge(general_options))

            if conflicts.include? plural_parent_name
              # unify the alternate sides of the conflicting children
              (conflicts).each do |method_name|
                unless parent_class.instance_methods.include?(method_name)
                  parent_class.send(:define_method, method_name) do
                    (self.send("#{singular_reverse_association_id}_#{method_name}") +
                      self.send("#{association_id._singularize}_#{method_name}")).freeze
                  end
                end
              end

              # unify the join model... join model is always renamed for doubles, unlike child associations
              unless parent_class.instance_methods.include?(join_name)
                parent_class.send(:define_method, join_name) do
                  (self.send("#{join_name}_as_#{singular_reverse_association_id}") +
                    self.send("#{join_name}_as_#{association_id._singularize}")).freeze
                end
              end
            else
              unless parent_class.instance_methods.include?(join_name)
                # ensure there are no forward slashes in the aliased join_name_method (occurs when namespaces are used)
                join_name_method = join_name.to_s.gsub('/', '_').to_sym
                parent_class.send(:alias_method, join_name_method, "#{join_name_method}_as_#{singular_reverse_association_id}")
              end
            end

          end
        end
      end

=begin rdoc

This method createds a single-sided polymorphic relationship.

  class Petfood < ActiveRecord::Base
    has_many_polymorphs :eaters, :from => [:dogs, :cats, :birds]
  end

The only required parameter, aside from the association name, is <tt>:from</tt>.

The method generates a number of associations aside from the polymorphic one. In this example Petfood also gets <tt>dogs</tt>, <tt>cats</tt>, and <tt>birds</tt>, and Dog, Cat, and Bird get <tt>petfoods</tt>. (The reverse association to the parents is always plural.)

== Available options

<tt>:from</tt>:: An array of symbols representing the target models. Required.
<tt>:as</tt>:: A symbol for the parent's interface in the join--what the parent 'acts as'.
<tt>:through</tt>:: A symbol representing the class of the join model. Follows Rails defaults if not supplied (the parent and the association names, alphabetized, concatenated with an underscore, and singularized).
<tt>:dependent</tt>:: Accepts <tt>:destroy</tt>, <tt>:nullify</tt>, <tt>:delete_all</tt>. Controls how the join record gets treated on any associate delete (whether from the polymorph or from an individual collection); defaults to <tt>:destroy</tt>.
<tt>:skip_duplicates</tt>:: If <tt>true</tt>, will check to avoid pushing already associated records (but also triggering a database load). Defaults to <tt>true</tt>.
<tt>:rename_individual_collections</tt>:: If <tt>true</tt>, all individual collections are prepended with the polymorph name, and the children's parent collection is appended with "_of_#{association_name}"</tt>. For example, <tt>zoos</tt> becomes <tt>zoos_of_animals</tt>. This is to help avoid method name collisions in crowded classes.
<tt>:extend</tt>:: One or an array of mixed modules and procs, which are applied to the polymorphic association (usually to define custom methods).
<tt>:join_extend</tt>:: One or an array of mixed modules and procs, which are applied to the join association.
<tt>:parent_extend</tt>:: One or an array of mixed modules and procs, which are applied to the target models' association to the parents.
<tt>:conditions</tt>:: An array or string of conditions for the SQL <tt>WHERE</tt> clause.
<tt>:parent_conditions</tt>:: An array or string of conditions which are applied to the target models' association to the parents.
<tt>:order</tt>:: A string for the SQL <tt>ORDER BY</tt> clause.
<tt>:parent_order</tt>:: A string for the SQL <tt>ORDER BY</tt> which is applied to the target models' association to the parents.
<tt>:group</tt>:: An array or string of conditions for the SQL <tt>GROUP BY</tt> clause. Affects the polymorphic and individual associations.
<tt>:limit</tt>:: An integer. Affects the polymorphic and individual associations.
<tt>:offset</tt>:: An integer. Only affects the polymorphic association.
<tt>:namespace</tt>:: A symbol. Prepended to all the models in the <tt>:from</tt> and <tt>:through</tt> keys. This is especially useful for Camping, which namespaces models by default.
<tt>:uniq</tt>:: If <tt>true</tt>, the records returned are passed through a pure-Ruby <tt>uniq</tt> before they are returned. Rarely needed.
<tt>:foreign_key</tt>:: The column name for the parent's id in the join.
<tt>:foreign_type_key</tt>:: The column name for the parent's class name in the join, if the parent itself is polymorphic. Rarely needed--if you're thinking about using this, you almost certainly want to use <tt>acts_as_double_polymorphic_join()</tt> instead.
<tt>:polymorphic_key</tt>:: The column name for the child's id in the join.
<tt>:polymorphic_type_key</tt>:: The column name for the child's class name in the join.

If you pass a block, it gets converted to a Proc and added to <tt>:extend</tt>.

== On condition nullification

When you request an individual association, non-applicable but fully-qualified fields in the polymorphic association's <tt>:conditions</tt>, <tt>:order</tt>, and <tt>:group</tt> options get changed to <tt>NULL</tt>. For example, if you set <tt>:conditions => "dogs.name != 'Spot'"</tt>, when you request <tt>.cats</tt>, the conditions string is changed to <tt>NULL != 'Spot'</tt>.

Be aware, however, that <tt>NULL != 'Spot'</tt> returns <tt>false</tt> due to SQL's 3-value logic. Instead, you need to use the <tt>:conditions</tt> string <tt>"dogs.name IS NULL OR dogs.name != 'Spot'"</tt> to get the behavior you probably expect for negative matches.

=end
      def has_many_polymorphs(association_id, options = {}, &extension)
        _logger_debug "associating #{self}.#{association_id}"
        #reflection = create_has_many_polymorphs_reflection(association_id, options, &extension)
        ## puts "Created reflection #{reflection.inspect}"
        ## configure_dependency_for_has_many(reflection)
        ActiveRecord::Associations::Builder::HasManyPolymorphs.build(self, association_id, options, &extension)
      end


      private

      def extract_double_collections(options)
        collections = options._select do |key, value|
          value.is_a? Array and key.to_s !~ /(#{RESERVED_DOUBLES_KEYS.map(&:to_s).join('|')})$/
        end

        raise PolymorphicError, "Couldn't understand options in acts_as_double_polymorphic_join. Valid parameters are your two class collections, and then #{RESERVED_DOUBLES_KEYS.inspect[1..-2]}, with optionally your collection names prepended and joined with an underscore." unless collections.size == 2

        options = options._select do |key, value|
          !collections[key]
        end

        [collections, options]
      end

      def make_general_option_keys_specific!(options, collections)
        collection_option_keys = Hash[*collections.keys.map do |key|
          [key, RESERVED_DOUBLES_KEYS.map{|option| "#{key}_#{option}".to_sym}]
        end._flatten_once]

        collections.keys.each do |collection|
          options.each do |key, value|
            next if collection_option_keys.values.flatten.include? key
            # shift the general options to the individual sides
            collection_key = "#{collection}_#{key}".to_sym
            collection_value = options[collection_key]
            case key
              when :conditions
                collection_value, value = sanitize_sql(collection_value), sanitize_sql(value)
                options[collection_key] = (collection_value ? "(#{collection_value}) AND (#{value})" : value)
              when :order
                options[collection_key] = (collection_value ? "#{collection_value}, #{value}" : value)
              when :extend, :join_extend
                options[collection_key] = Array(collection_value) + Array(value)
              else
                options[collection_key] ||= value
            end
          end
        end

        collection_option_keys
      end

     def devolve(association_id, reflection, string, klass, remove_inappropriate_clauses = false)
       # XXX remove_inappropriate_clauses is not implemented; we'll wait until someone actually needs it
       return unless string
       string = string.dup
       # _logger_debug "devolving #{string} for #{klass}"
       inappropriate_classes = (all_classes_for(association_id, reflection) - # the join class must always be preserved
           [klass, klass.base_class, reflection.klass, reflection.klass.base_class])
       inappropriate_classes.map do |klass|
         klass.columns.map do |column|
           [klass.table_name, column.name]
         end.map do |table, column|
           ["#{table}.#{column}", "`#{table}`.#{column}", "#{table}.`#{column}`", "`#{table}`.`#{column}`"]
         end
       end.flatten.sort_by(&:size).reverse.each do |quoted_reference|
         # _logger_debug "devolved #{quoted_reference} to NULL"
         # XXX clause removal would go here
         string.gsub!(quoted_reference, "NULL")
       end
       # _logger_debug "altered to #{string}"
       string
     end


    end
  end
end
