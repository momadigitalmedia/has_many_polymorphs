module ActiveRecord #:nodoc:
  module Associations #:nodoc:

    class PolymorphicError < ActiveRecordError #:nodoc:
    end

    class PolymorphicMethodNotSupportedError < ActiveRecordError #:nodoc:
    end

    # The association class for a <tt>has_many_polymorphs</tt> association.
    class PolymorphicAssociation < HasManyAssociation


      def scoped
        association_scope.where(reflection.additional_conditions)
      end


      def concat(*records)
        return if records.empty?

        if reflection.options[:skip_duplicates]
          _logger_debug "Loading instances for polymorphic duplicate push check; use :skip_duplicates => false and perhaps a database constraint to avoid this possible performance issue"
          load_target
        end

        reflection.klass.transaction do
          records.flatten.each do |record|
            if owner.new_record? or not record.respond_to?(:new_record?) or record.new_record?
              raise PolymorphicError, "You can't associate unsaved records."
            end
            next if reflection.options[:skip_duplicates] and target.include? record
            owner.send(reflection.options[:through]).create(construct_join_attributes(record))
            @target << record if loaded?
          end
        end

        self
      end

      def delete(*records)
        records = records.flatten
        records.reject! {|record| @target.delete(record) if record.new_record?}
        return if records.empty?

        reflection.klass.transaction do
          records.each do |record|
            owner.send(reflection.options[:through]).where(construct_join_attributes(record)).delete_all
            @target.delete(record)
          end
        end
      end


      private

      def construct_join_attributes(record)

        join_attributes = {
            record.association(reflection.options[:through]).reflection.foreign_key => record.send(record.association(reflection.options[:through]).reflection.association_primary_key(reflection.klass))
        }

        join_attributes[record.association(reflection.options[:through]).reflection.type] = record.class.base_class.name

        join_attributes
      end

    end

  end
end
