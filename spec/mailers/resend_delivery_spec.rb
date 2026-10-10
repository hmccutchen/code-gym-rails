require "rails_helper"
require "httparty"

# Production delivers mail through Resend's HTTP API, and the resend gem reads
# every reply with HTTParty's JSON parser. httparty 0.24.2 passed `quirks_mode`
# to JSON.parse, which json 3.0 removed, so each delivery raised
# `ArgumentError: unknown keyword: quirks_mode` after the mail had already been
# sent. Login codes are the only way into this app, so a parser that cannot read
# a success reply locks every teammate out.
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
