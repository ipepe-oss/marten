module Marten
  module DB
    module Field
      abstract class Base
        @primary_key : ::Bool
        @blank : ::Bool
        @null : ::Bool
        @name : ::String?

        getter id

        def initialize(
          @id : ::String,
          @primary_key = false,
          @blank = false,
          @null = false,
          @name = nil
        )
        end

        abstract def from_db_result_set(result_set : ::DB::ResultSet)
        abstract def to_db(value) : ::DB::Any

        # Runs custom validation logic for a specific model field and model object.
        #
        # This method should be overriden for each field implementation that requires custom validation logic.
        def validate(record : Model)
        end

        protected def perform_validation(record : Model)
          value = record.get_field_value(id)

          if value.nil? && !@null
            record.errors.add(id, null_error_message(record), type: :null)
          end

          validate(record)
        end

        private def null_error_message(_record)
          # TODO: add I18n support.
          "This field cannot be null."
        end
      end
    end
  end
end
