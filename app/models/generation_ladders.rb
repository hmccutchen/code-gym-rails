# Design notes: docs/code-notes/app/models/generation_ladders.md
class GenerationLadders
  def self.for(user, rungs, language, code_review_mode, gotcha: nil, featured_concept: nil)
    requests = rungs.map do |kind, rung|
      { kind: kind, level: kind.difficulty_definition(rung: rung, mode: code_review_mode).rung,
        bucket: ConceptBucket.for(kind.key, language),
        concepts: ConceptVocabulary.selectable_for_section(kind.key, language, mode: code_review_mode, rung: rung,
                                                           gotcha: gotcha, featured_concept: featured_concept) }
    end
    pairs = requests.flat_map { |request| request[:concepts].map { |concept| [ request[:bucket], concept ] } }.uniq

    references = ConceptReference.indexed_for(user, language: pairs.map(&:first).uniq, concept: pairs.map(&:last).uniq)
                                 .select { |_key, reference| reference.ladder? }

    requests.each_with_object({}) do |request, ladders|
      field = ConceptReference::LADDER_FIELD_FOR.fetch(request[:level])
      rungs = request[:concepts].filter_map do |concept|
        reference = references[[ concept, request[:bucket] ]]
        [ concept, reference.public_send(field).truncate(ConceptReference::MAX_LADDER_RUNG_LENGTH) ] if reference
      end.to_h
      ladders[request[:kind]] = rungs
    end
  end
end
