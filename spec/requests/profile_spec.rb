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
      expect(JSON.parse(response.body)).to eq("name" => "Renamed", "time_zone" => "UTC", "adaptive_set_size" => true)
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

    it "updates the time_zone and returns 200" do
      login_as(user)
      patch profile_path,
            params: { user: { time_zone: "America/Los_Angeles" } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(user.reload.time_zone).to eq("America/Los_Angeles")
    end

    it "strips surrounding whitespace from a time_zone before validating" do
      login_as(user)
      patch profile_path,
            params: { user: { time_zone: "  America/Los_Angeles  " } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(user.reload.time_zone).to eq("America/Los_Angeles")
    end

    it "stores a blank time_zone as nil (leaves it to auto-detect)" do
      user.update!(time_zone: "America/Chicago")
      login_as(user)
      patch profile_path,
            params: { user: { time_zone: "" } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(user.reload.time_zone).to be_nil
    end

    it "rejects an invalid time_zone with 422 and no change" do
      user.update!(time_zone: "America/Chicago")
      login_as(user)
      patch profile_path,
            params: { user: { time_zone: "Mars/Phobos" } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.time_zone).to eq("America/Chicago")
    end
  end

  describe "PATCH /profile with the adaptive set size preference" do
    it "saves the preference and echoes it back" do
      login_as(user)

      patch profile_path,
            params: { user: { adaptive_set_size: false } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["adaptive_set_size"]).to be(false)
      expect(user.reload.adaptive_set_size).to be(false)
    end
  end
end
