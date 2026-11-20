# Design notes: docs/code-notes/app/services/duck_answer.md
class DuckAnswer
  attr_reader :text

  def self.ask(user, exercise, section:, message:, store:, narrowing: DuckNarrowing.enabled?)
    service = AiService.for(user)
    examples = concept_examples_allowed?(exercise, section) ? { concept_examples: true } : {}
    unless narrowing
      return new(user, exercise, section, text: service.duck_response(user, exercise, section: section, message: message,
                                                                                         thread: store.turns_for(section), **examples))
    end

    narrow = store.narrowing_due?(section)
    reply = service.labelled_duck_response(user, exercise, section: section, message: message,
                                                           thread: store.turns_for_duck(section), narrow: narrow, **examples)
    new(user, exercise, section, text: reply.text, reply: reply, narrow: narrow, previous_point: store.last_point(section))
  end
  private_class_method :new

  def self.concept_examples_allowed?(exercise, section)
    return false unless DuckConceptExamples.enabled?

    kind = ExerciseSection.find(section)
    return false unless kind&.duck_concept_examples?
    return false unless exercise.problem_set.is_a?(Hash) && exercise.plan_notes.is_a?(Hash)

    key = section.to_s
    data = exercise.problem_set[key]
    return false unless data.is_a?(Hash) && exercise.active_section_keys.include?(key)

    question = data["question"]
    return false unless question.is_a?(String) && question.present?

    concept = data["concept"]
    return false unless concept.nil? || concept.is_a?(String)

    return false unless kind.concept_shown_before_submission?(data) && exercise.concepts_withheld_before_submission.exclude?(concept)

    SectionContext.render(data) == SectionContext.render(data.slice(*kind.prose_fields))
  end
  private_class_method :concept_examples_allowed?

  def initialize(user, exercise, section, text:, reply: nil, narrow: false, previous_point: nil)
    @user           = user
    @exercise       = exercise
    @section        = section
    @text           = text
    @reply          = reply
    @narrow         = narrow
    @previous_point = previous_point
  end

  def point = @reply&.point

  def log_stored
    return unless @reply

    Rails.logger.info("[duck_point] #{tag} question=#{@reply.question?} labelled=#{point.present?} " \
                      "matched=#{point.present? && point == @previous_point}")
    Rails.logger.info("[duck_narrowing] #{tag} #{narrowing_result}") if @narrow
  end

  private

  def tag = "user=#{@user.id} section=#{@section}"

  def narrowing_result
    return "narrowing=cut" if @reply.cut
    return "narrowing=skipped" unless @reply.question?

    within = SectionContext.render(@exercise.problem_set[@section])
    "quote=#{DuckReply.quote_outcome(@reply.text, within: within, language: @exercise.language)}"
  end
end
