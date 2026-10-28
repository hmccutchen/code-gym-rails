require "rails_helper"

RSpec.describe "Navigation", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  it "renders the installed app's tab bar with every destination, marking the current one" do
    get history_path

    tabs = Nokogiri::HTML(response.body).css(".tab-bar a")
    expect(tabs.map { |tab| tab.text.strip }).to eq(%w[Today Learn Progress History Settings Account])
    expect(tabs.select { |tab| tab["aria-current"] == "page" }.map { |tab| tab.text.strip }).to eq(%w[History])
  end

  it "marks the current page in the top nav too" do
    get learn_path

    current = Nokogiri::HTML(response.body).css("#nav-links a[aria-current='page']")
    expect(current.map(&:text)).to eq(%w[Learn])
  end

  it "lists the same destinations in the top nav as in the tab bar, Today first and current on the dashboard" do
    get root_path

    html = Nokogiri::HTML(response.body)
    links = html.css("#nav-links a")
    expect(links.map(&:text)).to eq(html.css(".tab-bar a").map { |tab| tab.text.strip })
    expect(links.first).to have_attributes(text: "Today")
    expect(links.first["href"]).to eq(root_path)
    expect(links.select { |link| link["aria-current"] == "page" }.map(&:text)).to eq(%w[Today])
  end

  it "renders no tab bar for someone signed out" do
    reset!
    get login_path

    expect(response.body).not_to include("tab-bar\" role")
  end
end
