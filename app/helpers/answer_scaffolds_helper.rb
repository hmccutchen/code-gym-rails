module AnswerScaffoldsHelper
  # `.presence` offers the scaffold again to a deliberately blanked answer (see DailyResponse.normalize_answers).
  def answer_starting_value(response, section)
    response.answers[section.to_s].presence ||
      ExerciseSection.find(section)&.scaffold_template(response.section_data(section))
  end

  # Lets the inline script strip the same labels as ExerciseSection.substantive_answer without its own copy.
  def answer_scaffold_labels_attr(response, section)
    labels = ExerciseSection.find(section)&.scaffold_labels(response.section_data(section))
    return {} if labels.blank?

    { "data-scaffold-labels" => labels.to_json }
  end
end
