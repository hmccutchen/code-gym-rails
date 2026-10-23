# Design notes: docs/code-notes/app/models/section_digest.md
module SectionDigest
  def self.call(section)
    Digest::SHA256.hexdigest(JSON.generate(canonical(section.as_json)))
  end

  def self.canonical(value)
    case value
    when Hash  then value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end
  private_class_method :canonical
end
