require "rails_helper"

# The hint is gated on an attempt. A disclosure dimmed with CSS still opened
# from the keyboard, so this drives the keys a keyboard user would press.
RSpec.describe "Locked teaching hint", type: :system do
  let(:user) { create_fake_provider_user }

  def slot
    find('.hint-slot[data-hint-for="code_review"]')
  end

  # Focuses the last focusable element before the hint, so the next Tab lands
  # wherever the hint sits in the tab order.
  def focus_just_before_hint
    page.execute_script(<<~JS)
      const slot = document.querySelector('.hint-slot[data-hint-for="code_review"]');
      const focusable = [...slot.closest("details.section").querySelectorAll('a[href], button, input, textarea, select, summary, [tabindex="0"]')]
        .filter(el => el.checkVisibility() && (slot.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING));
      focusable.at(-1).focus();
    JS
  end

  def focus_inside_hint?
    page.evaluate_script(%(!!document.activeElement.closest(".hint-slot")))
  end

  it "cannot be tabbed to or opened with Enter or Space before the section is attempted" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(slot).to have_css(".hint-locked", text: "Available after you attempt this section")

      focus_just_before_hint
      page.send_keys(:tab)
      expect(focus_inside_hint?).to be(false)
      expect(page.evaluate_script("document.activeElement.dataset.field")).to eq("code_review")

      slot.find(".hint-locked").click
      page.send_keys(:enter)
      page.send_keys(:space)

      expect(slot).to have_no_css("details")
      expect(page).to have_no_text("Look at what happens to the database")
    end
  end

  it "becomes a disclosure that opens from the keyboard once the section is attempted" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      find('textarea[data-field="code_review"]').fill_in(with: "The loop runs one query per order.")

      expect(slot).to have_css(".hint-locked", visible: :hidden)
      summary = slot.find("details.hint > summary")
      summary.send_keys(:enter)

      expect(slot).to have_text("Look at what happens to the database")
    end
  end

  it "goes back to the locked line when the answer is cleared" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      textarea = find('textarea[data-field="code_review"]')
      textarea.fill_in(with: "The loop runs one query per order.")
      expect(slot).to have_css("details.hint")

      textarea.fill_in(with: "")

      expect(slot).to have_no_css("details")
      expect(slot).to have_css(".hint-locked", text: "Available after you attempt this section")
    end
  end
end
