require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create_user_with_key }

  it "identifies the connection's current_user from the session" do
    connect session: { user_id: user.id }
    expect(connection.current_user).to eq(user)
  end

  it "rejects the connection when there is no logged-in user in the session" do
    expect { connect session: {} }.to have_rejected_connection
  end
end
