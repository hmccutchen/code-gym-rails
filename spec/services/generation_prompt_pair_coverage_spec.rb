require "rails_helper"

# Each pair renders index-wise rotations, not every combination, and every kind's retry; mentions are checked against the schema.
RSpec.describe "Generation prompt over every reachable daily pair" do
  # ConceptGuidance's idiom line names a kind's answer shape, not a sibling section; kept on purpose (kind-named-prompt-sections.md).
  KIND_IDIOM_PHRASES = [ "The challenge section is the exception" ].freeze

  let(:user) { User.new(email: "pairs@example.com", name: "Pairs", skill_level: "junior", focus_areas: []) }

  def reachable_pairs
    ExerciseSection.all.combination(DailyKinds::COUNT).select { |pair| DailyKinds.problems_with(pair.map(&:key)).empty? }
  end

  def index_wise_rotations(pair)
    slots = ExerciseSection.optional_slots(daily: pair)
    widest = slots.values.map(&:size).max

    filled = (0...widest).map { |index| slots.transform_values { |kinds| kinds[index % kinds.size].key.to_sym } }
    filled + [ slots.transform_values { nil } ]
  end

  def render(pair, rotation, language, only: nil)
    render_generation_prompt(
      user, language, only: only,
      daily_kinds: pair, rotation: rotation, code_review_mode: :application_code,
      reinforcement: [], due_checks: [], established: [], history: [],
      fourth_reinforcement: [ { concept: "scope_creep", bucket: "plan_review", tier: "standard" } ],
      fourth_due_checks: [], fourth_established: []
    )
  end

  def schema_keys(prompt)
    prompt[/Return JSON matching this schema exactly:\n(.*)\z/m, 1].scan(/^  "(\w+)": \{$/).flatten
  end

  def instructions(prompt)
    text = prompt.split("Return JSON matching this schema exactly:").first
    KIND_IDIOM_PHRASES.reduce(text) { |stripped, phrase| stripped.gsub(phrase, "") }
  end

  def named_sections(prompt)
    instructions(prompt).scan(/"(\w+)"/).flatten.uniq & ExerciseSection.keys
  end

  def absent_mentions(prompt)
    text = instructions(prompt)
    (ExerciseSection.keys - schema_keys(prompt)).flat_map do |key|
      [ key, key.tr("_", " ") ].uniq.filter_map { |name| text[/\b#{Regexp.escape(name)}('s| section)\b/i] }
    end
  end

  def each_render
    DailyExercise::LANGUAGES.each do |language|
      reachable_pairs.each do |pair|
        index_wise_rotations(pair).each do |rotation|
          yield render(pair, rotation, language), "#{language} #{pair.map(&:key)} #{rotation.compact}"
          ExerciseSection.for_plan(daily: pair, rotation: rotation).each do |kind|
            yield render(pair, rotation, language, only: kind), "#{language} #{pair.map(&:key)} retry #{kind.key}"
          end
        end
      end
    end
  end

  def offenders_for
    offenders = []
    each_render do |prompt, label|
      found = yield(prompt)
      offenders << "#{label}: #{found.join(', ')}" if found.any?
    end
    offenders
  end

  it "names only sections that are in the prompt's own schema" do
    offenders = offenders_for { |prompt| named_sections(prompt) - schema_keys(prompt) }

    expect(offenders).to be_empty, offenders.first(5).join("\n")
  end

  it "compares with a section only when it is in the prompt's own schema" do
    offenders = offenders_for { |prompt| absent_mentions(prompt) }

    expect(offenders).to be_empty, offenders.first(5).join("\n")
  end

  it "keeps the comparisons on a day that has code_review" do
    pair = [ ExerciseSection::CodeReview, ExerciseSection::DesignComparison ]
    prompt = render(pair, { pattern: :pattern, third: :security_review, fourth: nil }, "ruby_rails")

    expect(prompt).to include("the same as the code review's", "never one from code_review/pattern's broader vocabulary",
                              "the same bar as code_review's snippet")
  end

  it "leaves the code-review overlap out of a design_comparison retry, which requests no code_review alongside it" do
    prompt = render(DailyKinds::DEFAULT, { pattern: :pattern, third: :challenge, fourth: nil }, "ruby_rails",
                    only: ExerciseSection::DesignComparison)

    expect(prompt).not_to include("the same as the code review's")
  end

  it "reports a comparison with a section the prompt does not hold" do
    prompt = "- Match the challenge's difficulty.\nReturn JSON matching this schema exactly:\n{\n  \"pattern\": {\n"

    expect(absent_mentions(prompt)).to eq([ "challenge's" ])
  end

  it "covers at least the pairs the registry offered when this spec was written, in both languages" do
    expect(reachable_pairs.size).to be >= 42
  end
end
