module AnswerScaffoldsHelper
  # `.presence` offers the scaffold again to a deliberately blanked answer (see DailyResponse.normalize_answers).
  def answer_starting_value(response, section)
    response.answers[section.to_s].presence ||
      ExerciseSection.find(section)&.scaffold_template(response.section_data(section))
  end
end
