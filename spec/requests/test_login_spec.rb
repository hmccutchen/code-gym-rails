require "rails_helper"

RSpec.describe "Test login", type: :request do
  let!(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  def with_test_login_secret(value)
    previous = ENV["TEST_LOGIN_SECRET"]
    ENV["TEST_LOGIN_SECRET"] = value
    yield
  ensure
    ENV["TEST_LOGIN_SECRET"] = previous
  end

  context "when TEST_LOGIN_SECRET is set" do
    it "logs in the matching user with the correct secret" do
      with_test_login_secret("s3kr1t") do
        get test_login_path(secret: "s3kr1t", email: " Dev@Example.com ")

        expect(response).to redirect_to(root_path)
        expect(session[:user_id]).to eq(user.id)
      end
    end

    it "returns 404 for a wrong secret and does not log in" do
      with_test_login_secret("s3kr1t") do
        get test_login_path(secret: "wrong", email: "dev@example.com")

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end

    it "returns 404 with no secret param at all" do
      with_test_login_secret("s3kr1t") do
        get test_login_path(email: "dev@example.com")

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end

    it "returns 404 for an unknown email and creates no user" do
      with_test_login_secret("s3kr1t") do
        expect {
          get test_login_path(secret: "s3kr1t", email: "ghost@example.com")
        }.not_to change(User, :count)

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end
  end

  context "when TEST_LOGIN_SECRET is unset" do
    it "returns 404 even with a matching-looking secret" do
      with_test_login_secret(nil) do
        get test_login_path(secret: "anything", email: "dev@example.com")

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end
  end
end
