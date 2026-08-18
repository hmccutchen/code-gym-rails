class WeightedRoll
  # Cumulative weights are rounded before comparison: summing floats can land
  # an ulp off the intended boundary (0.5 + 0.3 == 0.7999999999999999), handing
  # back the wrong key at exactly that value.
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
