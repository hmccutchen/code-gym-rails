class WeightedRoll
  # Rounds cumulative weights because float sums land an ulp off a boundary (0.5 + 0.3 == 0.7999999999999999).
  def self.pick(weights)
    total      = weights.values.sum.to_f
    target     = rand
    cumulative = 0.0

    weights.each do |key, weight|
      cumulative += weight / total
      return key if target < cumulative.round(10)
    end

    weights.keys.last
  end
end
