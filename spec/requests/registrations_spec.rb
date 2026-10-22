require "rails_helper"

RSpec.describe "Signing up", type: :request do
  let(:password) { AuthHelpers::SPEC_PASSWORD }

  def sign_up(email: "new@example.com", name: "New Dev", password: self.password, confirmation: password)
    post user_registration_path, params: { user: { name: name, email: email, password: password,
                                                   password_confirmation: confirmation } }
  end

  def confirmation_token
    ActionMailer::Base.deliveries.last.body.encoded[/confirmation_token=([^"&\s]+)/, 1]
  end

  it "creates an unconfirmed account, mails the confirmation link and sends the visitor to log in" do
    expect { sign_up }.to change(User, :count).by(1).and change(ActionMailer::Base.deliveries, :count).by(1)

    expect(response).to redirect_to(new_user_session_path)
    expect(flash[:notice]).to match(/emailed you a confirmation link/)
    expect(User.find_by!(email: "new@example.com")).to have_attributes(name: "New Dev", confirmed_at: nil)
  end

  it "confirms the account from the emailed link, signs it in and sends it to set up the authenticator" do
    sign_up
    get user_confirmation_path(confirmation_token: confirmation_token)

    expect(User.find_by!(email: "new@example.com")).to be_confirmed
    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response).to redirect_to(two_factor_setup_path)
  end

  it "signs nobody in from a confirmation link that was already used" do
    sign_up
    token = confirmation_token
    get user_confirmation_path(confirmation_token: token)
    delete destroy_user_session_path

    get user_confirmation_path(confirmation_token: token)

    expect(session["warden.user.user.key"]).to be_nil
  end

  it "never signs in an account that already has an authenticator from a confirmation link" do
    enrolled = enroll_two_factor(create_user_with_key(email: "enrolled@example.com"))
    enrolled.send_confirmation_instructions

    get user_confirmation_path(confirmation_token: confirmation_token)

    expect(enrolled.reload).to be_confirmed
    expect(session["warden.user.user.key"]).to be_nil
  end

  it "limits confirmation emails per address" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    sign_up
    5.times { post user_confirmation_path, params: { user: { email: "new@example.com" } } }

    expect { post user_confirmation_path, params: { user: { email: "new@example.com" } } }
      .not_to change(ActionMailer::Base.deliveries, :count)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "refuses a short password, a mismatched confirmation, a missing name and a taken address" do
    create_user_with_key(email: "taken@example.com")

    [ { password: "short" }, { confirmation: "#{password}!" }, { name: "" }, { email: "taken@example.com" } ]
      .each do |change|
        expect { sign_up(**change) }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end
  end

  it "refuses a sign-up with no password at all" do
    expect { sign_up(password: "", confirmation: "") }.not_to change(User, :count)
  end

  it "limits sign-ups from one address" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    10.times { |n| sign_up(email: "dev#{n}@example.com") }

    expect { sign_up(email: "dev10@example.com") }.not_to change(User, :count)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "has no route to edit or delete an account through Devise, which Account owns" do
    expect(Rails.application.routes.url_helpers).not_to respond_to(:edit_user_registration_path)
  end
end
