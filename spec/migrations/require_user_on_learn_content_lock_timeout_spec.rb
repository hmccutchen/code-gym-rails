require "rails_helper"
require Rails.root.join("db/migrate/20261113190000_require_user_on_learn_content").to_s

RSpec.describe "Requiring an owner on Learn content while another session holds a table" do
  around { |example| with_shared_learn_rows { example.run } }

  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let!(:shared_guide_id) do
    connection.select_value(<<~SQL)
      INSERT INTO recognition_guides (group_key, questions, contrast, misfires, created_at, updated_at)
      VALUES ('lock_wait_#{SecureRandom.hex(6)}', 'q', 'c', 'm', now(), now()) RETURNING id
    SQL
  end

  after { connection.execute("DELETE FROM recognition_guides WHERE id = #{Integer(shared_guide_id)}") }

  def hold_guides_lock_for(seconds, locked)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |other|
        other.transaction do
          other.execute("LOCK TABLE recognition_guides IN ACCESS SHARE MODE")
          locked << true
          sleep seconds
        end
      end
    end
  end

  it "gives up after the lock timeout and changes nothing" do
    stub_const("RequireUserOnLearnContent::LOCK_TIMEOUT", "200ms")
    locked = Queue.new
    holder = hold_guides_lock_for(3, locked)
    locked.pop

    expect {
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
        connection.transaction { RequireUserOnLearnContent.require_owner(connection) }
      end
    }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(RecognitionGuide.exists?(shared_guide_id)).to be(true)
    expect(connection.columns(:recognition_guides).find { |column| column.name == "user_id" }.null).to be(true)
  ensure
    holder&.join
  end

  it "keeps the timeout to its own transaction" do
    connection.transaction { RequireUserOnLearnContent.require_owner(connection) }

    expect(connection.select_value("SHOW lock_timeout")).to eq("0")
  end
end
