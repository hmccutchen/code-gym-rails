module LoadingFormHelper
  ACTIONS = "submit->loading-form#submit pageshow@window->loading-form#restore".freeze

  def loading_form_data(label: nil, confirm_message: nil)
    { controller: "loading-form", action: ACTIONS,
      loading_form_label_value: label, loading_form_confirm_message_value: confirm_message }.compact
  end
end
