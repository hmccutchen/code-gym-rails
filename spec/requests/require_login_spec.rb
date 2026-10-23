require "rails_helper"

RSpec.describe "Signed-out requests", type: :request do
  let(:browser_accept) { "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }

  it "redirects a JSON request to the login page without saving it as the return address" do
    get dashboard_status_path, headers: { "Accept" => "application/json" }

    expect(response).to have_http_status(:found)
    expect(response.location).to end_with("/login")
    expect(session[:return_to]).to be_nil
  end

  it "saves nothing for a bare fetch's Accept: */*" do
    get history_path, headers: { "Accept" => "*/*" }

    expect(response).to redirect_to(login_path)
    expect(session[:return_to]).to be_nil
  end

  it "saves nothing for an image request's Accept list, which Rails reads as HTML" do
    get history_path, headers: { "Accept" => "image/avif,image/webp,*/*" }

    expect(response).to redirect_to(login_path)
    expect(session[:return_to]).to be_nil
  end

  it "saves a page navigation as the return address" do
    get history_path, headers: { "Accept" => browser_accept }

    expect(response).to redirect_to(login_path)
    expect(session[:return_to]).to eq(history_path)
  end

  it "saves nothing for a signed-out PATCH" do
    patch profile_path, headers: { "Accept" => browser_accept }

    expect(response).to redirect_to(login_path)
    expect(session[:return_to]).to be_nil
  end

  it "lands on the dashboard after a JSON redirect, not on the JSON path" do
    user = create_user_with_key
    get dashboard_status_path, headers: { "Accept" => "application/json" }

    login_as(user)

    expect(response).to redirect_to(root_path)
  end
end
