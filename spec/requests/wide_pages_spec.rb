require "rails_helper"

# A page widens only by calling wide_page; each later desktop PR moves its page from this list.
RSpec.describe "Page width", type: :request do
  let(:user) { create_user_with_key }

  def container_class
    Nokogiri::HTML(response.body).at_css("#main-content").ancestors(".container").first["class"]
  end

  before { login_as(user) }

  it "keeps the standard container on every page that hasn't asked to be wide" do
    user.update!(language: "ruby_rails")
    [ learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one") ].each do |path|
      get path
      expect(container_class).to eq("container"), "#{path} has #{container_class.inspect}"
    end
  end

  it "widens Today, History, Progress, Learn, Account and Settings" do
    [ root_path, history_path, progress_path, learn_path, account_path, setup_path ].each do |path|
      get path
      expect(container_class).to eq("container container-wide"), "#{path} has #{container_class.inspect}"
    end
  end
end
