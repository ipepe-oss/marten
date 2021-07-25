module Marten
  module DB
    module Management
      module SchemaEditor
        # Base implementation of a database schema editor.
        #
        # The database schema editor is used in the context of DB management in order to perform operation on models:
        # create / delete models, add new fields, etc. It's heavily used by the migrations mechanism.
        abstract class Base
          getter deferred_statements

          def initialize(@connection : Connection::Base)
            @deferred_statements = [] of Statement
          end

          # Returns the database type for a specific built-in column implementation.
          #
          # Note that this method is only used when handling column types of Marten built-in types as custom column
          # implementations must define a `#db_type` method.
          abstract def column_type_for_built_in_column(id)

          # Returns the database type suffix for a specific built-in column implementation.
          #
          # Note that this method is only used when handling column types of Marten built-in types.
          abstract def column_type_suffix_for_built_in_column(id)

          # Returns the SQL statement allowing to create a database index.
          abstract def create_index_deferred_statement(
            table : TableState,
            columns : Array(Column::Base),
            name : String? = nil
          ) : Statement

          # Returns the SQL statement allowing to create a database table.
          abstract def create_table_statement(table_name : String, definitions : String) : String

          # Returns a boolean indicating if the schema editor implementation supports rollbacking DDL statements.
          abstract def ddl_rollbackable? : Bool

          # Returns the SQL statement allowing to delete a specific column from a table.
          abstract def delete_column_statement(table : TableState, column : Column::Base) : String

          # Returns the SQL statement allowing to delete a specific foreign key constraint from a table.
          abstract def delete_foreign_key_constraint_statement(table : TableState, name : String) : String

          # Returns the SQL statement allowing to delete a database table.
          abstract def delete_table_statement(table_name : String) : String

          # Returns the SQL statements allowing to flush the passed database tables.
          abstract def flush_tables_statements(table_names : Array(String)) : Array(String)

          # Given an existing table, new column and column SQL statement, prepares the foreign key for the new column.
          abstract def prepare_foreign_key_for_new_column(
            table : TableState,
            column : Column::ForeignKey,
            column_definition : String
          ) : String

          # Given a new table, column and column SQL statement, prepares the foreign key corresponding to the column.
          abstract def prepare_foreign_key_for_new_table(
            table : TableState,
            column : Column::ForeignKey,
            column_definition : String
          ) : String

          # Returns a prepared default value that can be inserted in a column definition.
          abstract def quoted_default_value_for_built_in_column(value : ::DB::Any) : String

          # Returns the SQL statement allowing to remove an index from a given table.
          abstract def remove_index_statement(table : TableState, name : String) : String

          # Returns the SQL statement allowing to remove a unique constraint from a given table.
          abstract def remove_unique_constraint_statement(table : TableState, name : String) : String

          # Returns the SQL statement allowing to rename a column.
          abstract def rename_column_statement(table : TableState, column : Column::Base, new_name : String) : String

          # Returns the SQL statement allowing to rename a database table.
          abstract def rename_table_statement(old_name : String, new_name : String) : String

          # Adds a column to a specific table.
          def add_column(table : TableState, column : Column::Base) : Nil
            column_type = column_sql_for(column)
            column_definition = "#{quote(column.name)} #{column_type}"

            if column.is_a?(Column::ForeignKey)
              column_definition = prepare_foreign_key_for_new_column(table, column, column_definition)
            end

            execute("ALTER TABLE #{quote(table.name)} ADD COLUMN #{column_definition}")

            if column.index? && !column.unique?
              @deferred_statements << create_index_deferred_statement(table, [column])
            end
          end

          # Adds an index to a specific table.
          def add_index(table : TableState, index : Management::Index) : Nil
            execute(
              create_index_deferred_statement(
                table,
                columns: index.column_names.map { |cname| table.get_column(cname) },
                name: index.name
              ).to_s
            )
          end

          # Adds a unique constraint to a specific table.
          def add_unique_constraint(table : TableState, unique_constraint : Management::Constraint::Unique) : Nil
            execute(
              build_sql do |s|
                s << "ALTER TABLE #{table.name}"
                s << "ADD"
                s << unique_constraint_sql_for(unique_constraint)
              end
            )
          end

          # Changes a column on a specific table.
          def change_column(
            project : ProjectState,
            table : TableState,
            old_column : Column::Base,
            new_column : Column::Base
          ) : Nil
            fk_constraint_names = [] of String

            # Step 1: drop possible foreign key constraints if applicable.
            if old_column.is_a?(Column::ForeignKey)
              fk_constraint_names += @connection.introspector.foreign_key_constraint_names(table.name, old_column.name)
              fk_constraint_names.each do |constraint_name|
                execute(delete_foreign_key_constraint_statement(table, constraint_name))
              end
            end

            # Step 2: drop unique constraints if the new column is no longer unique (or if it became a primary key).
            if old_column.unique? && (!new_column.unique? || (!old_column.primary_key? && new_column.primary_key?))
              constraint_names = @connection.introspector.unique_constraint_names(table.name, old_column.name)
              constraint_names.select! { |cname| !table.unique_constraints.map(&.name).includes?(cname) }
              constraint_names.each do |cname|
                execute(remove_unique_constraint_statement(table, cname))
              end
            end

            # Step 3: drop incoming FK constraints if the field is primary key that is going to be updated.
            remake_fk_columns = (
              old_column.class != new_column.class &&
              old_column.primary_key? &&
              new_column.primary_key?
            )

            incoming_foreign_keys = project.tables.values.flat_map do |other_table|
              incoming_fk_columns = other_table.columns.select(Column::ForeignKey).select do |fk_column|
                fk_column.to_table == table.name && fk_column.to_column == old_column.name
              end

              incoming_fk_columns.map { |fk_column| {other_table, fk_column} }
            end

            if remake_fk_columns
              incoming_foreign_keys.each do |other_table, fk_column|
                constraint_names = @connection.introspector.foreign_key_constraint_names(
                  other_table.name,
                  fk_column.name
                )

                constraint_names.each do |constraint_name|
                  execute(delete_foreign_key_constraint_statement(other_table, constraint_name))
                end
              end
            end

            # Step 4: delete column index if it was previously indexed (but not unique) and if the new column is not
            # indexed or is unique.
            if old_column.index? && !old_column.unique? && (!new_column.index? || new_column.unique?)
              index_names = @connection.introspector.index_names(table.name, old_column.name)
              index_names.select! { |iname| !table.indexes.map(&.name).includes?(iname) }
              index_names.each do |iname|
                execute(remove_index_statement(table, iname))
              end
            end

            # Step 5: alter the column type if the column type changed.
            # Step 6: alter the column default value if it changed.
            # Step 7: alter the column nullability if it changed.
          end

          # Creates a new table directly from a model class.
          def create_model(model : Model.class) : Nil
            create_table(TableState.from_model(model))
          end

          # Creates a new table from a migration table state.
          def create_table(table : TableState) : Nil
            definitions = [] of String

            table.columns.each do |column|
              column_type = column_sql_for(column)
              column_definition = "#{quote(column.name)} #{column_type}"

              if column.is_a?(Column::ForeignKey)
                column_definition = prepare_foreign_key_for_new_table(table, column, column_definition)
              end

              definitions << column_definition
            end

            table.unique_constraints.each do |unique_constraint|
              definitions << unique_constraint_sql_for(unique_constraint)
            end

            execute(create_table_statement(table.name, definitions.join(", ")))

            # Forwards indexes configured as part of specific columns and the corresponding SQL statements to the array
            # of deferred SQL statements.
            table.columns.each do |column|
              next if !column.index? || column.unique?
              @deferred_statements << create_index_deferred_statement(table, [column])
            end

            # Forwards custom indexes (indexes targetting multiple columns) to the array of deferred SQL statements.
            table.indexes.each do |index|
              @deferred_statements << create_index_deferred_statement(
                table,
                columns: index.column_names.map { |cname| table.get_column(cname) },
                name: index.name
              )
            end
          end

          # Deletes the table of a specific model.
          def delete_model(model : Model.class)
            delete_table(TableState.from_model(model))
          end

          # Deletes the table corresponding to a migration table state.
          def delete_table(table : TableState)
            execute(delete_table_statement(table.name))

            # Removes all deferred statements that still reference the deleted table.
            @deferred_statements.reject! { |s| s.references_table?(table.name) }
          end

          # Executes a custom SQL statement.
          def execute(sql : String)
            @connection.open do |db|
              db.exec(sql)
            end
          end

          # Flushes all model tables.
          def flush_model_tables : Nil
            table_names = @connection.introspector.model_table_names.map { |n| quote(n) }
            flush_statements = flush_tables_statements(table_names)
            @connection.open do |db|
              flush_statements.each do |sql|
                db.exec(sql)
              end
            end
          end

          # Removes a column from a specific table.
          def remove_column(table : TableState, column : Column::Base) : Nil
            # First drops possible foreign key constraints if applicable.
            fk_constraint_names = @connection.introspector.foreign_key_constraint_names(table.name, column.name)
            fk_constraint_names.each do |constraint_name|
              execute(delete_foreign_key_constraint_statement(table, constraint_name))
            end

            # Now drops the column.
            execute(delete_column_statement(table, column))

            # Removes all deferred statements that still reference the deleted column.
            @deferred_statements.reject! { |s| s.references_column?(table.name, column.name) }
          end

          # Removes an index from a specific table.
          def remove_index(table : TableState, index : Management::Index) : Nil
            execute(remove_index_statement(table, index))
          end

          # Removes a unique constraint from a specific table.
          def remove_unique_constraint(table : TableState, unique_constraint : Management::Constraint::Unique) : Nil
            execute(remove_unique_constraint_statement(table, unique_constraint))
          end

          # Renames a specific column.
          def rename_column(table : TableState, column : Column::Base, new_name : String)
            execute(rename_column_statement(table, column, new_name))
            @deferred_statements.each do |statement|
              statement.rename_column(table.name, column.name, new_name)
            end
          end

          # Renames a specific table.
          def rename_table(table : TableState, new_name : String) : Nil
            execute(rename_table_statement(table.name, new_name))
            @deferred_statements.each do |statement|
              statement.rename_table(table.name, new_name)
            end
          end

          # Syncs all models for the current database connection.
          #
          # Every model whose table is not yet created will be created at the database level. This method should not be
          # used on production databases (those are likely to be mutated using migrations), but this can be usefull when
          # initializing a database for the first time in development or when running tests.
          def sync_models : Nil
            table_names = @connection.introspector.table_names
            Marten.apps.app_configs.each do |app|
              app.models.each do |model|
                next if table_names.includes?(model.db_table)
                create_model(model)
              end
            end
          end

          protected def execute_deferred_statements
            @deferred_statements.each do |sql|
              execute(sql.to_s)
            end
            @deferred_statements.clear
          end

          private delegate build_sql, to: @connection
          private delegate quote, to: @connection

          private macro defined?(t)
            {% if t.resolve? %}
              {{ yield }}
            {% end %}
          end

          private def column_sql_for(column)
            sql = column.sql_type(@connection)
            suffix = column.sql_type_suffix(@connection)

            if !column.default.nil?
              sql += " DEFAULT #{column.sql_quoted_default_value(@connection)}"
            end

            sql += column.null? ? " NULL" : " NOT NULL"

            if column.primary_key?
              sql += " PRIMARY KEY"
            elsif column.unique?
              sql += " UNIQUE"
            end

            sql += " #{suffix}" unless suffix.nil?

            sql
          end

          private def index_name(table_name, columns, suffix)
            index_name = "index_#{table_name}_on_#{columns.join("_")}#{suffix}"
            return index_name if index_name.size <= @connection.max_name_size

            digest = Digest::MD5.new
            digest.update(table_name)
            columns.each { |c| digest.update(c) }
            index_suffix = digest.final.hexstring[...8] + suffix

            remaining_size = @connection.max_name_size - index_suffix.size - 8

            String.build do |s|
              s << "index_"

              table_columns = "#{table_name}_#{columns.join("_")}"[..remaining_size]
              s << table_columns
              s << "_" unless table_columns.ends_with?('_')

              s << index_suffix
            end
          end

          private def remove_index_statement(table : TableState, index : Management::Index) : String
            remove_index_statement(table, index.name)
          end

          private def remove_unique_constraint_statement(
            table : TableState,
            unique_constraint : Management::Constraint::Unique
          ) : String
            remove_unique_constraint_statement(table, unique_constraint.name)
          end

          private def statement_columns(*args, **kwargs)
            Statement::Columns.new(->quote(String), *args, **kwargs)
          end

          private def statement_foreign_key_name(*args, **kwargs)
            Statement::ForeignKeyName.new(->index_name(String, Array(String), String), *args, **kwargs)
          end

          private def statement_index_name(*args, **kwargs)
            Statement::IndexName.new(->index_name(String, Array(String), String), *args, **kwargs)
          end

          private def statement_table(*args, **kwargs)
            Statement::Table.new(->quote(String), *args, **kwargs)
          end

          private def unique_constraint_sql_for(unique_constraint)
            String.build do |s|
              s << "CONSTRAINT #{unique_constraint.name} "
              s << "UNIQUE "
              s << "("
              s << unique_constraint.column_names.join(", ") { |cname| quote(cname) }
              s << ")"
            end
          end
        end
      end
    end
  end
end
