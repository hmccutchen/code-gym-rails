require "rails_helper"

# Real threads against real connections, so transactional fixtures are off for
# this file — the spawned threads cannot see a record held open in the
# example's transaction. Rows are cleaned up by hand below.
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

  # Verified to discriminate: with the row lock removed this returns 5 users
  # instead of 1, so a correct code is redeemable as many times as an attacker
  # can post it in parallel.
  it "redeems a correct code exactly once when posted concurrently" do
    code = user.generate_login_code!

    results = guess_concurrently(code, times: 8)

    expect(results.compact.size).to eq(1)
  end
end
