# Design notes: docs/code-notes/app/models/level_suggestion_event.md
class LevelSuggestionEvent < ApplicationRecord
  belongs_to :user

  ACTIONS = %w[applied dismissed removed].freeze
  SOURCES = %w[suggestion setup_edit skill_level_edit].freeze
  APPLIED = "applied".freeze

  validates :action, inclusion: { in: ACTIONS }
  validates :kind, inclusion: { in: ->(_) { ExerciseSection.keys } }
  validates :source, inclusion: { in: SOURCES }, allow_nil: true
  validates :source, presence: true, if: :applied?
  validates :source, absence: true, unless: :applied?

  def applied? = action == APPLIED

  # shown maps a kind to the rung the card or Setup showed it moving to, already checked against this save.
  def self.applied_rows(user, before:, after:, shown:, cutoffs:, cleared: [])
    before_rungs = rungs(before)
    moved = rungs(after).reject { |kind, rung| before_rungs[kind] == rung }
    return [] if moved.empty?

    results = LevelSuggestion::Evidence.for(user).results
    moved.map do |kind, rung|
      { kind: kind, action: APPLIED, source: source_for(kind, rung, before, after, shown, cleared),
        from_level: before_rungs[kind], to_level: rung, **evidence(kind, before_rungs[kind], results, cutoffs) }
    end
  end

  # A tab opened before cards posted their steps sends none, so its rows fall back to the proposal recomputed now.
  def self.dismissal_rows(user, kinds:, action:, results:, shown: {})
    levels = user.kind_rungs
    offered = kinds.all? { |kind| shown.key?(kind) } ? {} :
      offered_moves(levels, user.locked_section_kinds, results, user.level_suggestion_cutoffs)
    kinds.map do |kind|
      { kind: kind, action: action, from_level: levels[kind], to_level: shown.fetch(kind) { offered[kind] },
        **evidence(kind, levels[kind], results, user.level_suggestion_cutoffs) }
    end
  end

  def self.rungs(state)
    KindDifficulty.new(levels: state[:levels] || {}, locked: []).rungs(skill_level: state[:skill_level])
  end

  # A target TrackChange cleared moved because the track did, so it counts like the skill level moving it.
  def self.source_for(kind, rung, before, after, shown, cleared)
    return "skill_level_edit" if cleared.include?(kind) || before[:levels].to_h[kind].presence == after[:levels].to_h[kind].presence

    shown[kind] == rung ? "suggestion" : "setup_edit"
  end

  def self.offered_moves(levels, locked, results, cutoffs)
    proposal = LevelSuggestion.proposal(levels: levels || {}, locked: locked || [], results: results, cutoffs: cutoffs)
    (proposal&.steps || []).to_h { |step| [ step.kind, step.to ] }
  end

  def self.evidence(kind, level, results, cutoffs)
    return {} if KindDifficulty::LEVELS.exclude?(level)

    LevelSuggestion.summary(kind: kind, level: level, results: results, cutoffs: cutoffs).to_h
  end

  private_class_method :rungs, :source_for, :offered_moves, :evidence
end
