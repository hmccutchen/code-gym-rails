require Rails.root.join("db/migrate/20261113190000_require_user_on_learn_content").to_s

# The L1, L4 and L5 migration specs build shared rows, which RequireUserOnLearnContent no longer lets the schema hold.
module SharedLearnRows
  def with_shared_learn_rows
    change_learn_schema { |connection| RequireUserOnLearnContent.allow_shared_rows(connection) }
    begin
      yield
    ensure
      change_learn_schema { |connection| RequireUserOnLearnContent.require_owner(connection) }
    end
  end

  private

  def change_learn_schema
    connection = ActiveRecord::Base.connection
    connection.transaction { yield connection }
    [ ConceptReference, RecognitionGuide ].each(&:reset_column_information)
  end
end

RSpec.configure { |config| config.include SharedLearnRows, file_path: %r{spec/migrations/} }
