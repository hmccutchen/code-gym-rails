# GET /progress — which rung each concept is currently held at, grouped
# exactly as the Learn tab groups the same concepts. Read-only: every
# standing comes from RungLedger over stored responses and from the user's
# current section preferences; nothing here writes.
class ProgressController < ApplicationController
  include LearnScope

  def index
    ledger      = RungLedger.for(current_user)
    hosts       = ConceptHosts.for(current_user)
    preferences = KindPreferences.for(current_user)

    @buckets = learn_buckets.map do |bucket|
      groups = ConceptGroup.grouped(ConceptBucket.vocabulary_for(bucket)).map do |group, concepts|
        standings = concepts.to_h { |concept| [ concept, standing_for(concept, bucket, ledger, hosts, preferences) ] }
        { key: group, standings: standings, counts: standings.values.tally }
      end
      { key: bucket, groups: groups }
    end
  end

  private

  # A rung, :not_yet, or :not_offered when every kind that could show the
  # concept is excluded — the user's own choice, never a gap.
  def standing_for(concept, bucket, ledger, hosts, preferences)
    held = ledger.held(concept, bucket)
    return held if held

    hosts.kinds_for(concept, bucket).any? { |kind| !preferences.excluded?(kind) } ? :not_yet : :not_offered
  end
end
