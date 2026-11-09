class ConceptMastery::PracticePolicy
  MODES = %w[support simplified normal_retry].freeze

  def self.apply(state:, operation:)
    new(state.deep_dup, operation).apply
  end

  def initialize(state, operation)
    @state = state
    @operation = operation
  end

  def apply
    requests = @state.fetch("practice_requests", {}).deep_dup
    @operation.fetch("sections").each { |kind, evidence| update_request(requests, kind, evidence) }
    @state["practice_requests"] = requests
    return @state if @state.fetch("tier") == "paused"
    return ConceptMastery::Transition.apply(@state, @operation) unless eased_comfort?

    grade = @operation.fetch("sections").values.map { |entry| entry.fetch("rating") }
      .min_by { |rating| ConceptMastery::AI_RATING_RANK.fetch(rating) }
    @state.merge("tier" => "standard", "streak" => 0, "cooldown_remaining" => 0, "last_rating" => grade)
  end

  private

  def eased_comfort?
    @operation.fetch("sections").values.all? do |entry|
      entry.fetch("eased") && favourable?(entry) && comfortable?(entry)
    end
  end

  def favourable?(entry) = DailyResponse::AI_RATING_FAVORABLE.include?(entry.fetch("rating"))
  def comfortable?(entry) = DailyResponse::SELF_RATING_FAVORABLE.include?(entry["self_rating"])

  def update_request(requests, kind, entry)
    if favourable?(entry) && comfortable?(entry) && !entry.fetch("eased")
      requests.delete(kind)
      return
    end
    mode = requested_mode(entry, requests.dig(kind, "mode"))
    return unless mode

    requests[kind] = { "mode" => mode, "source_response_id" => @operation.fetch("response_id"),
      "requested_at" => @operation.fetch("occurred_at") }
  end

  def requested_mode(entry, previous)
    return favourable?(entry) ? "support" : "simplified" if entry["self_rating"] == "too_hard"
    return "normal_retry" if favourable?(entry) && comfortable?(entry) && entry.fetch("eased")
    return "support" if !favourable?(entry) && previous == "normal_retry"

    nil
  end
end
