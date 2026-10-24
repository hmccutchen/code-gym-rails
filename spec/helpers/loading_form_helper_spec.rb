require "rails_helper"

RSpec.describe LoadingFormHelper, type: :helper do
  it "wires a form to both of the controller's actions" do
    expect(helper.loading_form_data).to eq(controller: "loading-form",
                                           action: "submit->loading-form#submit pageshow@window->loading-form#restore")
  end

  it "adds the label and confirm message only when given" do
    expect(helper.loading_form_data(label: "Working", confirm_message: "Sure?"))
      .to include(loading_form_label_value: "Working", loading_form_confirm_message_value: "Sure?")
    expect(helper.loading_form_data(label: "Working")).not_to have_key(:loading_form_confirm_message_value)
  end
end
