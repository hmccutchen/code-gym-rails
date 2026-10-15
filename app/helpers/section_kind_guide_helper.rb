module SectionKindGuideHelper
  # Memoized for the request: every section on the answer form asks the same question.
  def kind_about_on_form?(key)
    @answered_kinds ||= DailyResponse.answered_kinds_for(current_user)
    @answered_kinds.exclude?(key.to_s)
  end
end
