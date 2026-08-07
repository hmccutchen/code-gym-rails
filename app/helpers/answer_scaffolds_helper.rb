# Answer-scaffold concerns shared by the dashboard form and the third-section
# partials, so the pre-fill rule and the label list the client-side "answered"
# check needs are stated once rather than at each textarea.
module AnswerScaffoldsHelper
  # A fresh, never-answered section starts pre-filled with the scaffold the
  # generator wrote for this specific problem. `.presence` is what makes this
  # safe on historical rows: a section answered before scaffolds existed keeps
  # its own text, and one deliberately blanked (see
  # DailyResponse.normalize_answers) is offered the scaffold again.
  def answer_starting_value(response, section)
    response.answers[section.to_s].presence ||
      ExerciseSection.find(section)&.scaffold_template(response.section_data(section))
  end

  # Rendered onto the textarea so the inline progress/hint script can apply the
  # same label-stripping rule as ExerciseSection.substantive_answer without
  # carrying its own copy of the labels. Absent for unscaffolded kinds, which
  # the script reads as "nothing to strip".
  def answer_scaffold_labels_attr(response, section)
    labels = ExerciseSection.find(section)&.scaffold_labels(response.section_data(section))
    return {} if labels.blank?

    { "data-scaffold-labels" => labels.to_json }
  end
end
