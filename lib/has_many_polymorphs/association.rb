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

    end

  end
end
