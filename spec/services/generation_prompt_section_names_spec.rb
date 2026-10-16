require "rails_helper"

# A pair of daily kinds reorders the sections, so a prompt that names one by position would point at the wrong one.
RSpec.describe "Generation prompt section names" do
  it "names every section by its kind, never by its position, in every snapshotted prompt" do
    ordinal = /\b(first|second|third|fourth|1st|2nd|3rd|4th)[ -]section\b/i
    snapshots = Rails.root.glob("spec/fixtures/prompt_snapshots/*.txt")

    offenders = snapshots.filter_map do |path|
      match = path.read[ordinal]
      "#{path.basename}: #{match}" if match
    end

    expect(snapshots).not_to be_empty
    expect(offenders).to be_empty, "positional section names: #{offenders.first(5).join('; ')}"
  end
end
