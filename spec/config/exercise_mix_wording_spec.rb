require "rails_helper"

# Exercise mix skips a kind with a switch labeled "Skip this kind", which is on while the kind is skipped.
RSpec.describe "Copy that sends someone to Exercise mix" do
  def strings(tree, path = [])
    tree.flat_map do |key, value|
      value.is_a?(Hash) ? strings(value, path + [ key ]) : [ [ (path + [ key ]).join("."), value.to_s ] ]
    end
  end

  def exercise_mix_strings
    strings(YAML.load_file(Rails.root.join("config/locales/en.yml"))["en"]).select { |_, text| text.include?("Exercise mix") }
  end

  def turns_a_kind_on_or_off?(text)
    text.gsub(/turn Skip off/i, "").match?(/\bturn(?:ed|s)?\b[^.]{0,40}?\b(?:on|off)\b/i)
  end

  it "never tells someone to turn a kind on or off, which reads as the opposite of the Skip switch" do
    offenders = exercise_mix_strings.select { |_, text| turns_a_kind_on_or_off?(text) }.map(&:first)

    expect(offenders).to be_empty
  end

  it "recognises the wording it guards against, and lets the switch's own name through" do
    expect(turns_a_kind_on_or_off?("You turned Coding Challenge off in Exercise mix.")).to be(true)
    expect(turns_a_kind_on_or_off?("Swap it back, or turn it on again, to see it.")).to be(true)
    expect(turns_a_kind_on_or_off?("Turn Skip off for one of them first.")).to be(false)
  end
end
