# Design notes: docs/code-notes/app/services/duck_answer.md
class DuckAnswer
  attr_reader :text

  def self.ask(user, exercise, section:, message:, store:, narrowing:)
    service = AiService.for(user)
    answer = new(user: user, exercise: exercise, section: section)
    return answer.plain(service.duck_response(user, exercise, section: section, message: message, thread: store.turns_for(section))) unless narrowing

    narrow = store.narrowing_due?(section)
    reply = service.labelled_duck_response(user, exercise, section: section, message: message,
                                                           thread: store.turns_for_duck(section), narrow: narrow)
    answer.labelled(reply, narrow: narrow, previous_point: store.last_point(section))
  end

  def initialize(user:, exercise:, section:)
    @user     = user
    @exercise = exercise
    @section  = section
  end

  def plain(text)
    @text = text
    self
  end

  def labelled(reply, narrow:, previous_point:)
    @text           = reply.text
    @reply          = reply
    @narrow         = narrow
    @previous_point = previous_point
    self
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
    return "narrowing=skipped" unless @reply.question?

    within = SectionContext.render(@exercise.problem_set[@section])
    "quote=#{DuckReply.quote_outcome(@reply.text, within: within, language: @exercise.language)}"
  end
end
