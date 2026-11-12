module KeyHold
  KINDS = %w[bad_key out_of_credit].freeze
  AFTER = 2
  COVERED_COUNTS = (...AFTER)

  def self.counts?(kind) = KINDS.include?(kind.to_s)
end
