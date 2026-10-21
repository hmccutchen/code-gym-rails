# The files the isolation specs scan: everything that orchestrates, talks to a provider or builds a prompt, plus the pure decisions.
module IsolationScope
  DECISION_FILES = %w[competency_gate competency_gate/evidence coverage_exception coverage_exception/history daily_plan day_hosts day_size
                      featured_concept_pick generation_deadline generation_ladders level_suggestion level_suggestion/evidence
                      reviewed_section_results section_count section_rotation shared_concept size_forecast weighted_roll
                      problem_set_ingest push_nudge_plan].map { |name| "app/models/#{name}.rb" }.freeze

  def isolation_scope
    Rails.root.glob("app/{services,jobs,prompts,clients}/**/*.rb").map { |file| file.relative_path_from(Rails.root).to_s } +
      DECISION_FILES
  end
end

RSpec.configure { |config| config.include IsolationScope }
