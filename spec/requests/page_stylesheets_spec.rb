require "rails_helper"

RSpec.describe "Page stylesheets", type: :request do
  let(:user) { create_user_with_key }

  before do
    user.update!(language: "ruby_rails", display_preferences: { "theme" => "light" })
    login_as(user)
  end

  def stylesheets
    Nokogiri::HTML(response.body).css("head link[rel=stylesheet]").map { |link| link["href"][%r{/assets/(.+?)-[0-9a-f]+\.css}, 1] }
  end

  def page_sheets = stylesheets.grep(%r{\Apages/})

  { "history" => :history_path, "progress" => :progress_path, "learn" => :learn_path,
    "account" => :account_path, "settings" => :setup_path }.each do |page, path|
    it "links #{page}'s own sheet, after the desktop sheet and before the display sheets" do
      get public_send(path)

      expect(page_sheets).to eq([ "pages/#{page}" ])
      sheet = stylesheets.index("pages/#{page}")
      expect(sheet).to be > stylesheets.index("desktop")
      expect(sheet).to be < stylesheets.index("display")
      expect(sheet).to be < stylesheets.index("display_light")
    end
  end

  it "links no page sheet on a page that has none" do
    [ root_path, learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one") ].each do |path|
      get path
      expect(page_sheets).to be_empty, "#{path} links #{page_sheets.inspect}"
    end
  end
end
