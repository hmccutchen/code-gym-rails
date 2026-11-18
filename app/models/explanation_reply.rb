class ExplanationReply
  MAX_LENGTH = 200

  Reply = Data.define(:sound, :correction) do
    def to_h = { "sound" => sound, "correction" => correction }
  end

  def self.parse(raw)
    reply = from_stored(raw)
    raise ProviderError::InvalidResponseError, "Explanation reply was not one sound line and an optional correction" unless reply

    reply
  end

  def self.from_stored(raw)
    return unless raw.is_a?(Hash) && raw.key?("correction")

    sound = line(raw["sound"])
    correction = raw["correction"].nil? ? nil : line(raw["correction"])
    Reply.new(sound: sound, correction: correction) if sound && (raw["correction"].nil? || correction)
  end

  def self.line(value)
    text = value.is_a?(String) ? UserText.normalize(value).strip : ""
    text if text.present? && text.length <= MAX_LENGTH && !text.match?(/[\r\n]/)
  end
  private_class_method :line
end
