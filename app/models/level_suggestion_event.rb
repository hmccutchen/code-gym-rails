# Design notes: docs/code-notes/app/models/level_suggestion_event.md
class LevelSuggestionEvent < ApplicationRecord
  belongs_to :user

  ACTIONS = %w[applied dismissed removed].freeze
  SOURCES = %w[suggestion setup_edit].freeze
  APPLIED = "applied".freeze

  validates :action, inclusion: { in: ACTIONS }
  validates :kind, inclusion: { in: ->(_) { ExerciseSection.keys } }
  validates :source, inclusion: { in: SOURCES }, allow_nil: true
  validates :source, presence: true, if: :applied?
  validates :source, absence: true, unless: :applied?

  def applied? = action == APPLIED

  # Reads the database copies, since the proposal on screen was computed from the levels before this save.
  def self.applied_rows(user, before:, after:)
    changes = after.select { |kind, level| level.present? && before[kind] != level }
    return [] if changes.empty?

    results = TrackGraduation::Evidence.for(user).results
    cutoffs = user.track_evidence_cutoffs_in_database || {}
    offered = user.track_suggestions_in_database ? offered_moves(user, before, results, cutoffs) : {}
    changes.map do |kind, level|
      { kind: kind, action: APPLIED, source: offered[kind] == level ? "suggestion" : "setup_edit",
        from_level: before[kind], to_level: level, **evidence(kind, before[kind], results, cutoffs) }
    end
  end

  def self.dismissal_rows(user, kinds:, action:, results:)
    levels = user.section_kind_levels
    offered = offered_moves(user, levels, results, user.track_evidence_cutoffs)
    kinds.map do |kind|
      { kind: kind, action: action, from_level: levels[kind], to_level: offered[kind],
        **evidence(kind, levels[kind], results, user.track_evidence_cutoffs) }
    end
  end

  def self.offered_moves(user, levels, results, cutoffs)
    locked = user.locked_section_kinds_in_database || []
    proposal = TrackGraduation.proposal(levels: levels || {}, locked: locked, results: results, cutoffs: cutoffs)
    (proposal&.steps || []).to_h { |step| [ step.kind, step.to ] }
  end

  def self.evidence(kind, level, results, cutoffs)
    return {} if KindDifficulty::LEVELS.exclude?(level)

    TrackGraduation.summary(kind: kind, level: level, results: results, cutoffs: cutoffs).to_h
  end

  private_class_method :offered_moves, :evidence
end
