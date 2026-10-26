require "rails_helper"

# Exercise mix skips a kind with a switch labeled "Skip this kind", which is on while the kind is skipped.
RSpec.describe "Conventions held over config/locales" do
  def strings(tree, path = [])
    tree.flat_map do |key, value|
      value.is_a?(Hash) ? strings(value, path + [ key ]) : [ [ (path + [ key ]).join("."), value.to_s ] ]
    end
  end

  def locale = YAML.load_file(Rails.root.join("config/locales/en.yml"))["en"]

  def skip_copy
    strings(locale).select do |key, text|
      key.start_with?("exercise_mix.", "daily_kinds.") || text.match?(/exercise mix/i)
    end
  end

  def turns_a_kind_on_or_off?(text)
    without_switch_name = text.gsub(/turn Skip (?:on|off)/i, "")
    without_switch_name.match?(/\b(?:turn|switch)(?:s|ed|ing)?\b[^.]{0,40}?\b(?:on|off)\b/i) ||
      without_switch_name.match?(/\b(?:re-?enabl|enabl|disabl)(?:e|es|ed|ing)\b/i)
  end

  it "never describes skipping a kind as turning it on or off, in Exercise mix or the swap picker" do
    offenders = skip_copy.select { |_, text| turns_a_kind_on_or_off?(text) }.map(&:first)

    expect(offenders).to be_empty
  end

  it "recognises the wording it guards against, in any case, and lets the switch's own name through" do
    expect(turns_a_kind_on_or_off?("You turned Coding Challenge off in Exercise mix.")).to be(true)
    expect(turns_a_kind_on_or_off?("Swap it back, or turn it on again, to see it.")).to be(true)
    expect(turns_a_kind_on_or_off?("You switched it off in your exercise mix.")).to be(true)
    expect(turns_a_kind_on_or_off?("Re-enable it to see it again.")).to be(true)
    expect(turns_a_kind_on_or_off?("Turn Skip off for one of them first.")).to be(false)
  end

  it "reads every string under exercise_mix and daily_kinds, and any that names the page in lower case" do
    keys = skip_copy.map(&:first)

    expect(keys).to include("exercise_mix.exclude_body_strong", "daily_kinds.picker.consequences.excluded_incoming",
                            "progress.not_offered_note")
  end

  it "names the switch by the word on its label wherever the swap picker sends someone to turn Skip off" do
    label_word = locale.dig("exercise_mix", "exclude_label").split.first
    sentences = strings(locale).select { |key, _| key.start_with?("daily_kinds.") }.map(&:last).grep(/turn \w+ off/i)

    expect(sentences).not_to be_empty
    sentences.each { |text| expect(text).to match(/turn #{label_word} off/i) }
  end
end
