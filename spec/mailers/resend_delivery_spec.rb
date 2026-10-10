require "rails_helper"
require "httparty"

# httparty 0.24.2 passed quirks_mode, which json 3.0 removed, so every delivery raised after sending.
RSpec.describe "Resend delivery" do
  it "parses an API reply with the installed json gem" do
    reply = HTTParty::Parser.call('{"id":"49a3999c-0ce1-4ea6-ab68-afcd6dc2e794"}', :json)

    expect(reply).to eq("id" => "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794")
  end

  # Pins the reason the parser above is the one that matters.
  it "is what production sends mail through" do
    production = Rails.root.join("config/environments/production.rb").read

    expect(production).to match(/delivery_method\s*=\s*:resend/)
  end
end
