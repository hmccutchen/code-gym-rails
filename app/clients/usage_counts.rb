# Design notes: docs/code-notes/app/clients/usage_counts.md
class UsageCounts
  def initialize(provider)
    @provider = provider
    @problems = []
  end

  def object(parent, key, required: false)
    value = parent[key]
    return value if value.is_a?(Hash)

    note(key, value, "is not an object", required)
    {}
  end

  def count(parent, key, required: false)
    value = parent[key]
    return value if valid_count?(value)

    note(key, value, "is not a valid count", required)
    0
  end

  def uncached(total, *cached, field:)
    remainder = total - cached.sum
    return remainder unless remainder.negative?

    @problems << "#{field} is less than its cache counts"
    0
  end

  def sum(*counts, field:)
    total = counts.sum
    return total if total <= ApiUsage.max_token_count

    @problems << "#{field} adds up to more than a usage row holds"
    0
  end

  def mark(result)
    return result if @problems.empty?

    Rails.logger.warn("[usage] #{@provider} reply has unreadable token counts (#{@problems.join('; ')}); token counts marked unknown")
    result.merge(tokens_unknown: true)
  end

  private

  def valid_count?(value) = value.is_a?(Integer) && value.between?(0, ApiUsage.max_token_count)

  def note(key, value, malformed, required)
    if value.nil?
      @problems << "#{key} is missing" if required
    else
      @problems << "#{key} #{malformed}"
    end
  end
end
