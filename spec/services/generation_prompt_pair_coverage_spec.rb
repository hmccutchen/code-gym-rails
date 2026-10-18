require "rails_helper"

# A swapped pair can leave any kind out of a day, so a prompt line naming another section must only render beside it.
RSpec.describe "Generation prompt over every reachable daily pair" do
  let(:user) { User.new(email: "pairs@example.com", name: "Pairs", skill_level: "junior", focus_areas: []) }
  let(:section_keys) { ExerciseSection.keys }

  def reachable_pairs
    ExerciseSection.all.combination(2).reject { |pair| pair.count(&:fourth?) > 1 }
  end

  def rotations_for(pair)
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
    prompt.split("Return JSON matching this schema exactly:").first
  end

  def named_sections(prompt)
    instructions(prompt).scan(/"(\w+)"/).flatten.uniq & section_keys
  end

  def absent_mentions(prompt, present)
    text = instructions(prompt)
    mentions = []
    mentions << "the code review" if present.exclude?("code_review") && text.match?(/code review's|code_review's|from the code review/)
    mentions << "pattern's vocabulary" if present.exclude?("pattern") && text.include?("pattern's broader vocabulary")
    mentions
  end

  def each_render
    DailyExercise::LANGUAGES.each do |language|
      reachable_pairs.each do |pair|
        rotations_for(pair).each do |rotation|
          kinds = ExerciseSection.for_plan(daily: pair, rotation: rotation)
          yield render(pair, rotation, language), "#{language} #{pair.map(&:key)} #{rotation.compact}"
          kinds.each do |kind|
            yield render(pair, rotation, language, only: kind), "#{language} #{pair.map(&:key)} retry #{kind.key}"
          end
        end
      end
    end
  end

  it "names only sections that are in the prompt's own schema" do
    offenders = []
    each_render do |prompt, label|
      missing = named_sections(prompt) - schema_keys(prompt)
      offenders << "#{label}: #{missing.join(', ')}" if missing.any?
    end

    expect(offenders).to be_empty, offenders.first(5).join("\n")
  end

  it "compares against code_review or pattern only on a day that has them" do
    offenders = []
    each_render do |prompt, label|
      mentions = absent_mentions(prompt, schema_keys(prompt))
      offenders << "#{label}: #{mentions.join(', ')}" if mentions.any?
    end

    expect(offenders).to be_empty, offenders.first(5).join("\n")
  end

  it "keeps the comparisons on a day that has code_review" do
    pair = [ ExerciseSection::CodeReview, ExerciseSection::DesignComparison ]
    prompt = render(pair, { pattern: :pattern, third: :security_review, fourth: nil }, "ruby_rails")

    expect(prompt).to include("the same as the code review's", "never one from code_review/pattern's broader vocabulary",
                              "the same bar as code_review's snippet")
  end

  it "covers every reachable pair in both languages" do
    count = 0
    each_render { count += 1 }

    expect(reachable_pairs.size).to eq(42)
    expect(count).to be > 42 * DailyExercise::LANGUAGES.size * 2
  end
end
