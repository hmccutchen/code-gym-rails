require "rails_helper"

RSpec.describe "Sessions ended by sessions_valid_after", type: :request do
  let(:user) { create_user_with_key(email: "dev@example.com") }

  it "keeps a session signed in after the cutoff" do
    user.update!(sessions_valid_after: 1.minute.ago)
    login_as(user)

    get history_path

    expect(response).to have_http_status(:ok)
  end

  it "sends a session signed in before the cutoff back to the login page" do
    login_as(user)
    user.update!(sessions_valid_after: 1.second.from_now)

    get history_path

    expect(response).to redirect_to(login_path)
  end

  it "sends a session with no sign-in stamp, as every session from before the stamp has, back to the login page" do
    allow(User).to receive(:session_stamp).and_return(nil)
    login_as(user)
    allow(User).to receive(:session_stamp).and_call_original

    get history_path

    expect(response).to redirect_to(login_path)
  end
end
