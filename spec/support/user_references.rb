module UserReferences
  Reference = Data.define(:table, :column, :target)

  def schema_tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]

  def record_models
    Rails.application.eager_load!
    tables = schema_tables
    ActiveRecord::Base.descendants.reject { |model| model.abstract_class? || model.name.nil? || tables.exclude?(model.table_name) }
  end

  def user_references(tables: schema_tables, models: record_models)
    found = (named_user_references(tables) + belongs_to_user(models)).to_set
    loop do
      before = found.size
      found.merge(foreign_key_references(tables, found.to_set(&:table) << "users"))
      return found if found.size == before
    end
  end

  def user_ids_held(user, references)
    held = { "users" => [ user.id ] }
    loop do
      before = held.values.sum(&:size)
      references.select { |ref| held.key?(ref.target) }.each do |ref|
        held[ref.table] = (held.fetch(ref.table, []) | rows_naming(ref, held[ref.target]).pluck(:id))
      end
      return held if held.values.sum(&:size) == before
    end
  end

  def rows_naming(ref, ids)
    return reference_table(ref).where(ref.column => ids.map(&:downcase)) if ref.target == :email

    reference_table(ref).where(ref.column => ids)
  end

  private

  def reference_table(ref) = Class.new(ActiveRecord::Base) { self.table_name = ref.table }.unscoped

  def user_column_target(name)
    return :email if name.include?("email")

    "users" if name == "user_id" || name.end_with?("_by_id")
  end

  def named_user_references(tables)
    tables.flat_map do |table|
      ActiveRecord::Base.connection.columns(table).filter_map do |column|
        target = user_column_target(column.name)
        Reference.new(table: table, column: column.name, target: target) if target
      end
    end
  end

  def belongs_to_user(models)
    models.flat_map do |model|
      model.reflect_on_all_associations(:belongs_to).select { |association| !association.polymorphic? && association.class_name == "User" }
           .map { |association| Reference.new(table: model.table_name, column: association.foreign_key.to_s, target: "users") }
    end
  end

  def foreign_key_references(tables, owned)
    tables.flat_map do |table|
      ActiveRecord::Base.connection.foreign_keys(table).select { |key| owned.include?(key.to_table) }
                        .map { |key| Reference.new(table: table, column: key.column, target: key.to_table) }
    end
  end
end

RSpec.configure { |config| config.include UserReferences, file_path: %r{spec/(conventions/user_data_coverage|services/account_deletion)_spec\.rb} }
