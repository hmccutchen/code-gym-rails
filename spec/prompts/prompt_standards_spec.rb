require "rails_helper"

RSpec.describe PromptStandards do
  let(:standard) { described_class::PLAIN_LANGUAGE_STANDARD }

  it "matches CLAUDE.md's Writing style section except for the second-person item" do
    section = Rails.root.join("CLAUDE.md").read[/^\*\*Writing style\.\*\*.*?(?=^\*\*Modular)/m]
    doc_bullets = section.scan(/^- (.+?)(?=\n\n|\n- )/m).map { |(bullet)| bullet.squish }
    standard_lines = standard.lines.map(&:strip)

    expect(doc_bullets).to eq(standard_lines.grep(/\A- /).map { |line| line.delete_prefix("- ") } - [ "Second person, direct address." ])
    standard_lines.grep(/\A(Avoid|Aim for|Calibration)/).each do |line|
      expect(section.squish).to include(line)
    end
  end

  it "differs between the two only by the subject it names" do
    concept = PromptStandards.explain_differently_standard("concept")
    point   = PromptStandards.explain_differently_standard("point")

    expect(concept.sub("SAME concept", "SAME point")).to eq(point)
  end
end
