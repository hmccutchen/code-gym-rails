require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create_user_with_key }

  def warden_with(signed_in) = instance_double(Warden::Proxy, user: signed_in)

  it "identifies the connection's current_user from the Devise session" do
    connect env: { "warden" => warden_with(user) }
    expect(connection.current_user).to eq(user)
  end

  it "rejects the connection when nobody is signed in" do
    expect { connect env: { "warden" => warden_with(nil) } }.to have_rejected_connection
  end
end
