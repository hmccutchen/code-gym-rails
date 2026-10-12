module AnswerFormHelpers
  def answer_form(document)
    document.at_css("[data-controller~='answer-form']")
  end
end

RSpec.configure do |config|
  config.include AnswerFormHelpers, type: :request
end
