require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  it "gives the standard container by default" do
    expect(helper.container_class).to eq("container")
  end

  it "adds the wide modifier once a view asks for it" do
    helper.wide_page
    expect(helper.container_class).to eq("container container-wide")
  end

  it "stays wide, and no wider, when a view asks twice" do
    2.times { helper.wide_page }
    expect(helper.container_class).to eq("container container-wide")
  end

  it "names the page's own stylesheet, the last call winning" do
    expect(helper.content_for?(:page_stylesheet)).to be(false)
    helper.page_stylesheet "history"
    helper.page_stylesheet "learn"
    expect(helper.content_for(:page_stylesheet)).to eq("learn")
  end

  it "links no sheet of its own on a page that names none" do
    expect(helper.linked_stylesheets).to eq([])
  end

  it "links each component sheet once, in the order first named, ahead of the page's own sheet" do
    helper.page_stylesheet "account"
    helper.component_stylesheet "authenticator"
    helper.component_stylesheet "copy_row"
    helper.component_stylesheet "authenticator"

    expect(helper.linked_stylesheets).to eq(%w[components/authenticator components/copy_row pages/account])
  end
end
