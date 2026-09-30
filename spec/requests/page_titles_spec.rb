require "rails_helper"

# Each page names itself in <title>, which is what a screen reader announces
# on arrival and what the iOS app switcher shows.
RSpec.describe "Page titles", type: :request do
  def title
    Nokogiri::HTML(response.body).at_css("title").text
  end

  it "names the login page" do
    get login_path

    expect(title).to eq("Log in – Code Gym")
  end

  context "when signed in" do
    let(:user) { create_user_with_key }

    before { login_as(user) }

    {
      "Today's Workout" => -> { root_path },
      "History"         => -> { history_path },
      "Learn"           => -> { learn_path },
      "Progress"        => -> { progress_path },
      "Account"         => -> { account_path },
      "Settings"        => -> { setup_path }
    }.each do |expected, path|
      it "titles #{expected}" do
        travel_to(Date.new(2026, 7, 18)) { get instance_exec(&path) }

        expect(title).to eq("#{expected} – Code Gym")
      end
    end

    it "titles the admin page" do
      ENV["ADMIN_EMAILS"] = user.email
      get admin_suggested_concepts_path

      expect(title).to eq("Suggested concepts – Code Gym")
    ensure
      ENV.delete("ADMIN_EMAILS")
    end

    it "titles a Learn concept page with the concept" do
      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(title).to eq("N plus one – Learn – Code Gym")
    end
  end
end
