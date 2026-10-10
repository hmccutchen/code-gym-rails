class AiProvider
  def self.all
    [ ClaudeService, GeminiService, OpenaiService, FakeService ]
  end

  def self.keys
    all.map(&:provider_key)
  end

  def self.find(key)
    all.find { |provider| provider.provider_key == key }
  end

  # Unknown or invalid keys fall back to the "unknown" label, so the UI never shows "translation missing".
  def self.label(key)
    I18n.t("providers.#{key.presence || 'unknown'}", default: :"providers.unknown")
  end

  def self.detect(api_key)
    all.find { |provider| provider.key_pattern&.match?(api_key) }&.provider_key
  end
end
