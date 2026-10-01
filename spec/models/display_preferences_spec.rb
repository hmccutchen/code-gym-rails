require "rails_helper"

RSpec.describe DisplayPreferences do
  it "defaults the background pattern on and stores only an explicit off" do
    expect(described_class.new({})["background_pattern"]).to eq("on")
    expect(described_class.new(nil)["background_pattern"]).to eq("on")
    expect(described_class.new("background_pattern" => "invalid")["background_pattern"]).to eq("on")
    expect(described_class.sparse("background_pattern" => "on")).to eq({})
    expect(described_class.sparse("background_pattern" => "off")).to eq("background_pattern" => "off")
    expect(described_class.problems_with("background_pattern" => "off")).to be_empty
    expect(described_class.problems_with("background_pattern" => false)).not_to be_empty
  end

  it "lists each setting's default first, as the value an untouched user reads" do
    preferences = described_class.new({})

    DisplayPreferences::OPTIONS.each { |key, values| expect(preferences[key]).to eq(values.first) }
    expect(preferences.html_attributes).to eq({})
  end

  it "reads a stored value outside the lists as the default" do
    preferences = described_class.new("theme" => "neon", "text_size" => 200, "unknown" => "x")

    expect(preferences["theme"]).to eq("dark")
    expect(preferences["text_size"]).to eq("100")
    expect(preferences.any?).to be(false)
  end

  it "renders only the chosen settings as data attributes" do
    preferences = described_class.new("theme" => "light", "line_spacing" => "loose")

    expect(preferences.html_attributes).to eq("data-theme" => "light", "data-line-spacing" => "loose")
  end

  it "drops defaults and keeps anything unknown for validation to refuse" do
    expect(described_class.sparse("theme" => "dark", "font" => "atkinson", "bogus" => "1"))
      .to eq("font" => "atkinson", "bogus" => "1")
  end

  it "names what is wrong with a malformed object" do
    expect(described_class.problems_with([])).to eq([ "must be an object" ])
    expect(described_class.problems_with("theme" => "neon", "size" => "1"))
      .to contain_exactly("has an unsupported theme: neon", "names an unknown setting: size")
    expect(described_class.problems_with("theme" => "light")).to be_empty
  end

  it "applies the light palette everywhere for light, by media query for device, and nowhere otherwise" do
    expect(described_class.new("theme" => "light").light_palette_media).to eq("all")
    expect(described_class.new("theme" => "device").light_palette_media).to eq("(prefers-color-scheme: light)")
    expect(described_class.new({}).light_palette_media).to eq("not all")
  end

  it "asks for the white iOS status bar only for an explicit light theme" do
    expect(described_class.new("theme" => "light").status_bar_style).to eq("default")
    expect(described_class.new("theme" => "device").status_bar_style).to eq("black")
    expect(described_class.new({}).status_bar_style).to eq("black")
  end

  it "follows the device on a signed-out page" do
    expect(described_class.signed_out.html_attributes).to eq("data-theme" => "device")
  end

  describe "on User" do
    let(:user) { User.create!(email: "display@example.com", name: "Display") }

    it "stores nothing for a default and keeps the store sparse" do
      user.update!(display_preferences: { "theme" => "light", "text_size" => "100" })
      expect(user.reload.display_preferences).to eq("theme" => "light")

      user.update!(display_preferences: { "theme" => "dark" })
      expect(user.reload.display_preferences).to eq({})
    end

    it "refuses an unknown setting or value" do
      user.display_preferences = { "font" => "comic_sans" }
      expect(user).not_to be_valid
      expect(user.errors[:display_preferences]).to include("has an unsupported font: comic_sans")
    end
  end
end
