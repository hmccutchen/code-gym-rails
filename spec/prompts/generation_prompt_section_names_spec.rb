require "rails_helper"

# A pair of daily kinds reorders the sections, so a prompt that names one by position would point at the wrong one.
RSpec.describe "Generation prompt section names" do
  let(:ordinal) { /\b(first|second|third|fourth|last|1st|2nd|3rd|4th)[ -](section|slot)s?\b/i }

  def offenders_in(paths)
    paths.filter_map do |path|
      match = path.read[ordinal]
      "#{path.relative_path_from(Rails.root)}: #{match}" if match
    end
  end

  it "names every section by its kind, never by its position, in every snapshotted prompt" do
    snapshots = Rails.root.glob("spec/fixtures/prompt_snapshots/*.txt")

    expect(snapshots).not_to be_empty
    expect(offenders_in(snapshots)).to be_empty
  end

  it "names no section by its position anywhere in app or lib Ruby, so an unsnapshotted prompt is held too" do
    sources = Rails.root.glob("{app,lib}/**/*.rb")

    expect(sources).not_to be_empty
    expect(offenders_in(sources)).to be_empty
  end
end
