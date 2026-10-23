require "rails_helper"

RSpec.describe "Forms that show a loading state", type: :system do
  let(:user) { create_fake_provider_user }

  def delete_button = find("#delete-account-form button")

  def answer_confirm_with(accepted)
    page.execute_script("window.confirm = () => #{accepted};")
  end

  # Records whether the controller let the submit through, then holds the page so its loading state can be read.
  def hold_submissions
    page.execute_script(<<~JS)
      window.submits = [];
      window.addEventListener("submit", (event) => {
        window.submits.push(event.defaultPrevented);
        event.preventDefault();
      });
    JS
  end

  def submit_button_state(form_selector)
    page.evaluate_script(<<~JS)
      (() => {
        const button = document.querySelector(#{"#{form_selector} button".to_json});
        return { disabled: button.disabled, loading: button.classList.contains("btn-loading"), label: button.textContent.trim() };
      })()
    JS
  end

  it "leaves the account in place and the button enabled when the confirmation is cancelled" do
    visit_as(user)
    visit account_path
    wait_for_js
    answer_confirm_with(false)

    delete_button.click

    sleep 0.5
    expect(page).to have_current_path(account_path)
    expect(delete_button).not_to be_disabled
    expect(delete_button[:class]).not_to include("btn-loading")
    expect(user.reload.anonymized_at).to be_nil
  end

  it "submits the delete once the confirmation is accepted" do
    visit_as(user)
    visit account_path
    wait_for_js
    answer_confirm_with(true)

    delete_button.click

    wait_for { user.reload.anonymized_at }
    expect(user.reload.anonymized_at).to be_present
  end

  it "shows the loading label on an accepted submit and restores the button when the page comes back from the cache" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      fill_in_answer("code_review", "An answer long enough to create today's draft response.")
      wait_for { user.daily_responses.reload.any? }
      visit root_path
      wait_for_js
      form = %(form[action="#{start_over_response_path(user.daily_responses.sole)}"])
      answer_confirm_with(true)
      hold_submissions

      find("#{form} button").click

      expect(page.evaluate_script("window.submits")).to eq([ false ])
      wait_for { submit_button_state(form)["disabled"] }
      expect(submit_button_state(form)).to eq("disabled" => true, "loading" => true, "label" => I18n.t("dashboard.exercise.starting_over"))

      page.execute_script(%(window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }))))

      expect(submit_button_state(form)).to eq("disabled" => false, "loading" => false, "label" => I18n.t("dashboard.exercise.start_over"))
    end
  end
end
