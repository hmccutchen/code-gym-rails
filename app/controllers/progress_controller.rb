# GET /progress — read-only: standings come from RungLedger and the user's current section preferences.
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

  # :not_offered when every host kind is excluded, which is the user's choice rather than a gap.
  def standing_for(concept, bucket, ledger, hosts, preferences)
    toward = ledger.developing_toward(concept, bucket)
    return :"#{ProgressHelper::DEVELOPING}#{toward}" if toward

    held = ledger.held(concept, bucket)
    return held if held

    hosts.kinds_for(concept, bucket).any? { |kind| !preferences.excluded?(kind) } ? :not_yet : :not_offered
  end
end
