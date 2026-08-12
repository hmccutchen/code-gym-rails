require "rails_helper"

# Pins the exact bytes of the generation prompt, for every combination of
# generation language, third section, and fourth section the app can roll.
#
# This exists to guard a refactor that moves each section kind's schema
# fragment and generation guidance out of AiService's case statements and onto
# the ExerciseSection subclasses. That move is required to change nothing about
# what the provider is asked for, and "nothing" includes whitespace: the
# fragments are squiggly heredocs interpolated into another squiggly heredoc,
# so their indentation in the assembled prompt is partly incidental and would
# be easy to normalize by accident.
#
# The combinations are enumerated from DailyPlan's own weight tables rather
# than hardcoded, so adding a section kind to either rotation fails here until
# a snapshot for it exists — a kind that silently drops out of assembly is the
# specific failure this is meant to catch.
#
# NOT covered, deliberately: retention/reinforcement/established blocks are
# rendered from empty lists. Those need persisted ConceptMastery rows, and the
# text they produce lives in build_exercise_prompt, which is not moving. The
# one exception worth knowing about is #annotate_retention_concept, which does
# branch on the third — it stays in AiService and keeps its own specs.
#
# Rebaselining: UPDATE_PROMPT_SNAPSHOTS=1 bundle exec rspec <this file>. Do
# that only when a prompt change is the intended deliverable. Rebaselining
# while moving the fragments would pin the new behavior and defeat the point.
RSpec.describe "generation prompt characterization" do
  SNAPSHOT_DIR = Rails.root.join("spec/fixtures/prompt_snapshots").freeze

  # Concrete subclass so the prompt builders can run without a provider
  # connection — this renders text and makes no HTTP call.
  let(:service) do
    Class.new(AiService) do
      private def build_connection = nil
    end.new("snapshot-key")
  end

  # Unpersisted and fully explicit: every list the prompt interpolates is
  # passed in, so nothing here reads the database or the clock.
  let(:user) do
    User.new(
      email:       "snapshot@example.com",
      name:        "Snapshot",
      skill_level: "developing",
      focus_areas: []
    )
  end

  def render(language, third, fourth)
    service.send(
      :build_exercise_prompt, user, language,
      third: third, fourth: fourth,
      reinforcement: [], due_checks: [], established: [], history: [],
      fourth_reinforcement: [], fourth_due_checks: [], fourth_established: []
    )
  end

  def snapshot_path(language, third, fourth)
    SNAPSHOT_DIR.join("#{language}__#{third}__#{fourth}.txt")
  end

  DailyExercise::LANGUAGES.each do |language|
    DailyPlan::THIRD_SECTION_WEIGHTS.each_key do |third|
      DailyPlan::FOURTH_SECTION_WEIGHTS.each_key do |fourth|
        context "#{language} / #{third} / #{fourth}" do
          let(:prompt) { render(language, third, fourth) }
          let(:path)   { snapshot_path(language, third, fourth) }

          it "renders every section this combination presents" do
            expect(prompt).to include(*%W[code_review pattern #{third} #{fourth}])
          end

          it "matches its recorded snapshot byte for byte" do
            if ENV["UPDATE_PROMPT_SNAPSHOTS"]
              FileUtils.mkdir_p(SNAPSHOT_DIR)
              File.write(path, prompt)
            end

            expect(path).to exist,
              "No snapshot at #{path.relative_path_from(Rails.root)}. " \
              "Record it against unmodified code with UPDATE_PROMPT_SNAPSHOTS=1."

            expect(prompt).to eq(File.read(path))
          end
        end
      end
    end
  end

  it "has no snapshot left behind for a combination that no longer exists" do
    expected = DailyExercise::LANGUAGES.flat_map { |language|
      DailyPlan::THIRD_SECTION_WEIGHTS.each_key.flat_map { |third|
        DailyPlan::FOURTH_SECTION_WEIGHTS.each_key.map { |fourth| snapshot_path(language, third, fourth).basename.to_s }
      }
    }

    expect(Dir.children(SNAPSHOT_DIR).sort).to eq(expected.sort)
  end
end
