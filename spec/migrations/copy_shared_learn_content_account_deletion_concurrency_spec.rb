require "rails_helper"
require Rails.root.join("db/migrate/20261113150000_copy_shared_learn_content").to_s

RSpec.describe "Copying shared Learn content racing account deletion on PostgreSQL" do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let!(:user) { User.create!(email: "copy-race-#{SecureRandom.hex(8)}@example.com") }
  let!(:shared_guide_id) do
    connection.select_value(<<~SQL)
      INSERT INTO recognition_guides (group_key, questions, contrast, misfires, created_at, updated_at)
      VALUES ('copy_race_#{SecureRandom.hex(6)}', 'q', 'c', 'm', now(), now()) RETURNING id
    SQL
  end
  let(:copied_rows) { RecognitionGuide.where(user_id: user.id) }

  after do
    AccountDeletion.call(user)
    connection.execute("DELETE FROM recognition_guides WHERE id = #{Integer(shared_guide_id)}")
  end

  def deletion_in_another_connection(backend_pid)
    Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |other|
        backend_pid << other.select_value("SELECT pg_backend_pid()")
        other.execute("SET lock_timeout = '10s'")
        AccountDeletion.call(user)
      ensure
        other.execute("RESET lock_timeout")
      end
    end
  end

  def wait_until_blocked(thread, backend_pid)
    Timeout.timeout(10) do
      loop do
        raise "deletion finished without waiting" unless thread.alive?
        break if backend_pid.any? && blocked?(backend_pid.first)

        Thread.pass
      end
    end
  end

  def blocked?(pid)
    ActiveRecord::Base.uncached do
      connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?
    end
  end

  def start_deletion_before_first_insert
    deletion = nil
    allow(connection).to receive(:execute).and_wrap_original do |original, sql, *args, **kwargs|
      if sql.include?("INSERT INTO") && sql.include?("SELECT #{user.id},")
        deletion ||= ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
          backend_pid = []
          deletion_in_another_connection(backend_pid).tap { |thread| wait_until_blocked(thread, backend_pid) }
        end
      end
      original.call(sql, *args, **kwargs)
    end
    -> { deletion }
  end

  it "makes deletion wait for the user's copy, then deletes the copied rows with the account" do
    deletion = start_deletion_before_first_insert

    CopySharedLearnContent.copy_to_active_users(connection)

    expect(deletion.call).to be_present
    expect(deletion.call.value.status).to eq(:deleted)
    expect([ User.exists?(user.id), copied_rows.exists? ]).to eq([ false, false ])
  ensure
    deletion&.call&.join
  end
end
