require "rails_helper"

# No page action detaches the answer form today; these specs force the Stimulus lifecycle to pin the pre-#510 behavior.
RSpec.describe "Answer form reconnecting on the same controller", type: :system do
  let(:user) { create_fake_provider_user }
  let(:answer) { "An answer sent before the form reconnected." }
  let(:controller_js) { %(window.Stimulus.getControllerForElementAndIdentifier(document.querySelector("[data-controller~='answer-form']"), "answer-form")) }

  def stored_draft
    page.evaluate_script(stored_draft_js)
  end

  def hold_every_save
    page.execute_script(<<~JS)
      const originalFetch = window.fetch
      window.heldSaves = []
      window.releaseEverySave = () => {
        window.fetch = originalFetch
        window.heldSaves.forEach((save) => save.release())
      }
      window.fetch = (url, options) => {
        if (new URL(url, location.href).pathname !== "/responses") return originalFetch(url, options)
        return new Promise((resolve, reject) => window.heldSaves.push({
          release: () => resolve(originalFetch(url, options)),
          lose: () => reject(new TypeError("Failed to fetch"))
        }))
      }
    JS
  end

  def send_a_held_save
    hold_every_save
    fill_in_answer("code_review", answer)
    wait_for_js_condition("window.heldSaves.length === 1")
  end

  def force_reconnect
    page.execute_script(<<~JS)
      window.formBeforeReconnect = #{controller_js}
      const element = window.formBeforeReconnect.element
      window.reconnectSpot = { parent: element.parentNode, next: element.nextSibling, element: element }
      element.remove()
    JS
    wait_for_js_condition("!window.formBeforeReconnect.element.isConnected && #{controller_js} === null")
    page.execute_script("const spot = window.reconnectSpot; spot.parent.insertBefore(spot.element, spot.next)")
    wait_for_js_condition("#{controller_js} === window.formBeforeReconnect")
  end

  it "clears the confirmed copy when a save sent before the reconnect succeeds" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      send_a_held_save

      force_reconnect
      wait_for_js_condition("window.CodeGymSaveStatus.queued('answers')")
      page.execute_script("window.heldSaves[0].release()")
      wait_for_js_condition("window.heldSaves.length === 2")

      expect(stored_draft).to be_nil
      page.execute_script("window.releaseEverySave()")
      wait_for_answers_settled
    end
  end

  it "still says the answers are kept when an inert form's earlier save gets no reply" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      send_a_held_save
      page.execute_script("#{controller_js}.formTarget.inert = true")

      force_reconnect
      page.execute_script("window.heldSaves[0].lose()")

      expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.saving_offline"))
    end
  end

  it "rebinds the rendered token and scope and drops proofs and the restored copy, keeping the last send" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      wait_for_answers_settled
      page.execute_script(<<~JS)
        const draft = #{controller_js}.draft
        window.draftBeforeReconnect = draft
        Object.assign(draft, { token: "token-from-a-reply", scope: "other-scope", unconfirmedSaves: ["stale proof"],
                               restored: { sent: ["stale proof"] }, lastSent: "last canonical send", kept: true })
      JS

      force_reconnect

      draft = page.evaluate_script(<<~JS)
        (() => {
          const form = #{controller_js}
          const draft = form.draft
          return { same: draft === window.draftBeforeReconnect, tokenRendered: draft.token === form.draftTokenValue,
                   scopeRendered: draft.scope === form.draftScopeValue, unconfirmedSaves: draft.unconfirmedSaves,
                   restored: draft.restored, lastSent: draft.lastSent, kept: draft.kept }
        })()
      JS
      expect(draft).to eq("same" => true, "tokenRendered" => true, "scopeRendered" => true, "unconfirmedSaves" => [],
                          "restored" => nil, "lastSent" => "last canonical send", "kept" => true)
    end
  end
end
