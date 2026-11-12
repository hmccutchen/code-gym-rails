# Design notes: docs/code-notes/app/clients/usage_counts.md
class UsageCounts
  def self.valid?(count) = count.is_a?(Integer) && count.between?(0, ApiUsage.max_token_count)

  def initialize(provider)
    @provider = provider
    @problems = []
  end

  def object(parent, key)
    value = parent[key]
    return value if value.is_a?(Hash)

    @problems << "#{key} is not an object" unless value.nil?
    {}
  end

  def count(parent, key)
    value = parent[key]
    return value if self.class.valid?(value)

    @problems << "#{key} is not a valid count" unless value.nil?
    0
  end

  def uncached(total, *cached, field:)
    remainder = total - cached.sum
    return remainder unless remainder.negative?

    @problems << "#{field} is less than its cache counts"
    0
  end

  def mark(result)
    return result if @problems.empty?

    Rails.logger.warn("[usage] #{@provider} reply has unreadable token counts (#{@problems.join('; ')}); token counts marked unknown")
    result.merge(tokens_unknown: true)
  end
end
