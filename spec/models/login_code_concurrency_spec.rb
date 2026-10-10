require "rails_helper"

# Spawned threads cannot see records inside the example's transaction, so rows are cleaned up by hand.
RSpec.describe "Login code verification under concurrency", type: :model do
  self.use_transactional_tests = false

  let!(:user) { User.create!(email: "race@example.com", name: "Race") }

  after { User.where(email: "race@example.com").delete_all }

  def guess_concurrently(code, times:)
    times.times.map {
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          User.authenticate_login_code(email: user.email, code: code)
        end
      end
    }.map(&:value)
  end

  # Verified to discriminate: without the row lock this returns 5 users instead of 1.
  it "redeems a correct code exactly once when posted concurrently" do
    code = user.generate_login_code!

    results = guess_concurrently(code, times: 8)

    expect(results.compact.size).to eq(1)
  end
end
