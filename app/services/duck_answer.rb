# Design notes: docs/code-notes/app/services/duck_answer.md
class DuckAnswer
  attr_reader :text

  def self.ask(user, exercise, section:, message:, store:, narrowing: DuckNarrowing.enabled?)
    service = AiService.for(user)
    unless narrowing
      return new(user, exercise, section, text: service.duck_response(user, exercise, section: section, message: message,
                                                                                         thread: store.turns_for(section)))
    end

    narrow = store.narrowing_due?(section)
    reply = service.labelled_duck_response(user, exercise, section: section, message: message,
                                                           thread: store.turns_for_duck(section), narrow: narrow)
    new(user, exercise, section, text: reply.text, reply: reply, narrow: narrow, previous_point: store.last_point(section))
  end
  private_class_method :new

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
