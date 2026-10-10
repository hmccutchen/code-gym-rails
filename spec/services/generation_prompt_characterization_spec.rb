require "rails_helper"

# Rebaseline with UPDATE_PROMPT_SNAPSHOTS=1 only when a prompt change is the intended deliverable.
RSpec.describe "generation prompt characterization" do
  SNAPSHOT_DIR = Rails.root.join("spec/fixtures/prompt_snapshots").freeze

  let(:service) do
    Class.new(AiService) do
      private def build_connection = nil
    end.new("snapshot-key")
  end

  # Unpersisted and explicit, so nothing here reads the database or the clock.
  let(:user) do
    User.new(
      email:       "snapshot@example.com",
      name:        "Snapshot",
      skill_level: "junior",
      focus_areas: []
    )
  end

  def render(language, third, fourth, mode)
    service.send(
      :build_exercise_prompt, user, language,
      third: third, fourth: fourth, code_review_mode: mode,
      reinforcement: [], due_checks: [], established: [], history: [],
      fourth_reinforcement: [], fourth_due_checks: [], fourth_established: []
    )
  end

  def snapshot_path(language, third, fourth, mode)
    SNAPSHOT_DIR.join("#{language}__#{third}__#{fourth}__#{mode}.txt")
  end

  DailyExercise::LANGUAGES.each do |language|
    ExerciseSection.thirds.map { |kind| kind.key.to_sym }.each do |third|
      ExerciseSection.fourths.map { |kind| kind.key.to_sym }.each do |fourth|
        DailyPlan::CODE_REVIEW_MODE_WEIGHTS.each_key do |mode|
          context "#{language} / #{third} / #{fourth} / #{mode}" do
            let(:prompt) { render(language, third, fourth, mode) }
            let(:path)   { snapshot_path(language, third, fourth, mode) }

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
  end

  it "has no snapshot left behind for a combination that no longer exists" do
    expected = DailyExercise::LANGUAGES.flat_map { |language|
      ExerciseSection.thirds.map { |kind| kind.key.to_sym }.flat_map { |third|
        ExerciseSection.fourths.map { |kind| kind.key.to_sym }.flat_map { |fourth|
          DailyPlan::CODE_REVIEW_MODE_WEIGHTS.each_key.map { |mode| snapshot_path(language, third, fourth, mode).basename.to_s }
        }
      }
    }

    expect(Dir.children(SNAPSHOT_DIR).sort).to eq(expected.sort)
  end
end
