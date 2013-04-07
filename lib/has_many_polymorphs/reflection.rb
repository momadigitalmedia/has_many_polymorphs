module ActiveRecord #:nodoc:
  module Reflection #:nodoc:

    class PolymorphicError < ActiveRecordError #:nodoc:
    end

=begin rdoc

The reflection built by the <tt>has_many_polymorphs</tt> method.

Inherits from ActiveRecord::Reflection::AssociationReflection.

=end

    class PolymorphicReflection < AssociationReflection

      attr_reader :additional_conditions

      def initialize(macro, name, options, active_record)
        super(macro, name, options, active_record)
        @additional_conditions = ""
        initialize_additional_conditions
      end



      # Stub out the validity check. Has_many_polymorphs checks validity on macro creation, not on reflection.
      def check_validity!
        # nothing
      end

      # Return the source reflection.
      def source_reflection
        # normally is the has_many to the through model, but we return ourselves,
        # since there isn't a real source class for a polymorphic target
        self
      end


      def source_options
        options
      end
      #
      def type
        @type = nil
      end


      def chain
        @chain ||= begin
          chain = [self]
          chain
        end
      end

      def association_class
        ActiveRecord::Associations::PolymorphicAssociation
      end

      # Set the classname of the target. Uses the join class name.
      def class_name
        # normally is the classname of the association target
        @class_name ||= options[:join_class_name]
      end

      private

      def initialize_additional_conditions
        aliases = options[:table_aliases]
        @additional_conditions = options[:from].map(&:to_s).sort.map(&:to_sym).map do |plural|
          model_class = plural._as_class
          table = model_class.table_name
          "#{aliases["#{table}.#{model_class.primary_key}"]} > 0"
        end.join(" OR ")
      end

    end

  end
end


ActiveRecord::Reflection::ClassMethods.module_eval do


  # Update the default reflection switch so that <tt>:has_many_polymorphs</tt> types get instantiated.
  # It's not a composed method so we have to override the whole thing.
  def create_reflection(macro, name, options, active_record)
    case macro
      when :has_many, :belongs_to, :has_one, :has_and_belongs_to_many
        klass = options[:through] ? ActiveRecord::Reflection::ThroughReflection : ActiveRecord::Reflection::AssociationReflection
        reflection = klass.new(macro, name, options, active_record)
      when :composed_of
        reflection = ActiveRecord::Reflection::AggregateReflection.new(macro, name, options, active_record)
      # added by has_many_polymorphs #
      when :has_many_polymorphs
        reflection = ActiveRecord::Reflection::PolymorphicReflection.new(macro, name, options, active_record)
    end

    self.reflections = self.reflections.merge(name => reflection)

    # DEPRICATED for Rails 3.2
    #write_inheritable_hash :reflections, name => reflection
    reflection
  end


end