require "rails_helper"

RSpec.describe "Profile", type: :request do
  let(:user) { create_user_with_key }

  describe "PATCH /profile" do
    it "requires login" do
      patch profile_path, params: { user: { name: "New" } }
      expect(response).to redirect_to(login_path)
    end

    it "updates the name and returns it as JSON" do
      login_as(user)

      patch profile_path,
            params: { user: { name: "  Renamed  " } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("name" => "Renamed")
      expect(user.reload.name).to eq("Renamed")
    end

    it "rejects a blank name without changing the record" do
      login_as(user)
      original = user.name

      patch profile_path,
            params: { user: { name: "   " } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to be_present
      expect(user.reload.name).to eq(original)
    end
  end
end
