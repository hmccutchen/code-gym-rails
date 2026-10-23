require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create_user_with_key }

  it "identifies the connection's current_user from the session" do
    connect session: { user_id: user.id, signed_in_at: User.session_stamp }
    expect(connection.current_user).to eq(user)
  end

  it "rejects a session that still names an anonymized user" do
    user.anonymize!

    expect { connect session: { user_id: user.id, signed_in_at: User.session_stamp } }.to have_rejected_connection
  end

  it "rejects the connection when there is no logged-in user in the session" do
    expect { connect session: {} }.to have_rejected_connection
  end

  it "rejects a session still waiting on its second factor" do
    marker = { "user_id" => user.id, "at" => User.session_stamp(user.issue_second_factor_challenge!) }

    expect { connect session: { pending_second_factor: marker } }.to have_rejected_connection
  end

  it "rejects a session with no sign-in stamp" do
    expect { connect session: { user_id: user.id } }.to have_rejected_connection
  end

  it "rejects a session signed in before the user's sessions_valid_after" do
    signed_in_at = User.session_stamp(1.minute.ago)
    user.update!(sessions_valid_after: Time.current)

    expect { connect session: { user_id: user.id, signed_in_at: signed_in_at } }.to have_rejected_connection
  end
end
