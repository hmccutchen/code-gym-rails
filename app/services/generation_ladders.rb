# Design notes: docs/code-notes/app/services/generation_ladders.md
class GenerationLadders
  def self.for(rungs, language, code_review_mode)
    requests = rungs.map do |kind, rung|
      { level: rung, bucket: ConceptBucket.for(kind.key, language),
        concepts: ConceptVocabulary.selectable_for_section(kind.key, language, mode: code_review_mode, rung: rung) }
    end
    pairs = requests.flat_map { |request| request[:concepts].map { |concept| [ request[:bucket], concept ] } }.uniq

    references = ConceptReference.where(language: pairs.map(&:first).uniq, concept: pairs.map(&:last).uniq)
                                 .select(&:ladder?)
                                 .index_by { |reference| [ reference.language, reference.concept ] }

    requests.each_with_object({}) do |request, ladders|
      field = ConceptReference::LADDER_FIELD_FOR.fetch(request[:level])
      rungs = request[:concepts].filter_map do |concept|
        reference = references[[ request[:bucket], concept ]]
        [ concept, reference.public_send(field).truncate(ConceptReference::MAX_LADDER_RUNG_LENGTH) ] if reference
      end.to_h
      (ladders[request[:level]] ||= {}).merge!(rungs)
    end
  end
end
