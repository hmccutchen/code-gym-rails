require "rails_helper"

RSpec.describe "A concept write-up racing account deletion on PostgreSQL", type: :job do
  self.use_transactional_tests = false

  let!(:user) { create_user_with_key(email: "reference-race-#{SecureRandom.hex(8)}@example.com") }
  let(:reference) { ConceptReference::WRITTEN_FIELDS.index_with { "Written text." } }
  let(:own_rows) { ConceptReference.where(user_id: user.id) }

  before do
    service = instance_double(ClaudeService, generate_concept_reference: reference)
    allow(AiService).to receive(:for).and_return(service)
  end

  after { AccountDeletion.call(user) }

  def deletion_in_another_connection(backend_pid)
    Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend_pid << connection.select_value("SELECT pg_backend_pid()")
        connection.execute("SET lock_timeout = '10s'")
        AccountDeletion.call(user)
      ensure
        connection.execute("RESET lock_timeout")
      end
    end
  end

  def wait_until_blocked(thread, backend_pid)
    Timeout.timeout(10) do
      loop do
        raise "the other connection finished without waiting" unless thread.alive?
        break if backend_pid.any? && blocked?(backend_pid.first)

        Thread.pass
      end
    end
  end

  def blocked?(pid)
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?
    end
  end

  def save_in_another_connection(backend_pid, &save)
    Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend_pid << connection.select_value("SELECT pg_backend_pid()")
        connection.execute("SET lock_timeout = '10s'")
        save.call
        nil
      rescue StandardError => e
        e
      ensure
        connection.execute("RESET lock_timeout")
      end
    end
  end

  def delete_account_while_save_waits(&save)
    saving = nil
    deleted = User.transaction do
      User.lock.find_by!(id: user.id)
      backend_pid = []
      saving = save_in_another_connection(backend_pid, &save)
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { wait_until_blocked(saving, backend_pid) }
      AccountDeletion.call(user)
    end
    [ deleted, ActiveSupport::Dependencies.interlock.permit_concurrent_loads { saving.value } ]
  ensure
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { saving&.join }
  end

  def start_deletion_after_owner_check
    deletion = nil
    allow_any_instance_of(User).to receive(:concept_references).and_wrap_original do |original, *args, **kwargs|
      if ActiveRecord::Base.connection.transaction_open?
        deletion ||= ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
          backend_pid = []
          deletion_in_another_connection(backend_pid).tap { |thread| wait_until_blocked(thread, backend_pid) }
        end
      end
      original.call(*args, **kwargs)
    end
    -> { deletion }
  end

  def perform(refresh: false)
    GenerateConceptReferenceJob.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: refresh)
  end

  it "makes deletion wait for a new write-up's insert, then deletes it with the account" do
    deletion = start_deletion_after_owner_check

    perform

    expect(deletion.call).to be_present
    expect(deletion.call.value.status).to eq(:deleted)
    expect([ User.exists?(user.id), own_rows.exists? ]).to eq([ false, false ])
  ensure
    deletion&.call&.join
  end

  it "makes deletion wait for a refresh's rewrite, then deletes the rewritten row with the account" do
    row = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "old", user: user)
    deletion = start_deletion_after_owner_check

    perform(refresh: true)

    expect(deletion.call).to be_present
    expect(deletion.call.value.status).to eq(:deleted)
    expect([ User.exists?(user.id), ConceptReference.exists?(row.id) ]).to eq([ false, false ])
  ensure
    deletion&.call&.join
  end

  it "makes a write-up that starts after deletion's user lock wait, then write nothing for the deleted account" do
    allow(Rails.logger).to receive(:info).and_call_original

    deleted, save_error = delete_account_while_save_waits { perform }

    expect([ deleted.status, save_error ]).to eq([ :deleted, nil ])
    expect(Rails.logger).to have_received(:info).with(/the account was deleted/)
    expect([ User.exists?(user.id), own_rows.exists? ]).to eq([ false, false ])
  end
end
