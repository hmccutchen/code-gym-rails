require "rails_helper"

# Folding is native <details>, so only a real browser shows that a folded
# section keeps gating submit, that its status line follows the live form,
# and that editing a rated, folded section reopens it.
RSpec.describe "Section folding", type: :system do
  it "folds on a tap, keeps the submit gate, and reopens a rated section on edit" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      first_field = rating_row_fields.first
      section = find(%(details.section[data-section-fold="#{first_field}"]))
      textarea = section.find(%(textarea[data-field="#{first_field}"]), visible: :all)

      textarea.fill_in(with: "A substantive answer that clears the length floor for this section.")
      expect(section).to have_selector(%(.section-status[data-status-for="#{first_field}"]), exact_text: "in progress")

      section.find(":scope > summary").click
      expect(section).not_to have_selector(%(textarea[data-field="#{first_field}"]))
      expect(section).to have_selector(%(textarea[data-field="#{first_field}"]), visible: :hidden)
      expect(page).to have_button("Submit answers →", disabled: true)
      expect(page).to have_content("Rate each section you answered to finish up.")

      section.find(":scope > summary").click
      rate_section(first_field)
      expect(section).to have_selector(%(.section-status[data-status-for="#{first_field}"]), exact_text: "✓ just right")

      section.find(":scope > summary").click
      expect(section).to have_selector(%(textarea[data-field="#{first_field}"]), visible: :hidden)

      page.execute_script(<<~JS, first_field)
        const t = document.querySelector(`textarea[data-field="${arguments[0]}"]`);
        t.value += " and a little more";
        t.dispatchEvent(new Event("input", { bubbles: true }));
      JS
      expect(section).to have_selector(%(textarea[data-field="#{first_field}"]), visible: :visible)
    end
  end

  # A titled section's summary carries glossary terms, and a term is only
  # reachable by tap on a phone; that tap must open the definition, not fold
  # the section around it.
  it "opens a glossary term in the summary without folding the section" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      section = find(%(details.section[data-section-fold="pattern"]))
      term = section.find(":scope > summary .gloss-term", match: :first)
      term.click

      expect(term[:class]).to include("gloss-open")
      expect(section[:open]).to be_truthy
      expect(section).to have_selector(%(textarea[data-field="pattern"]), visible: :visible)
    end
  end

  def rating_row_fields
    all(".rating-row[data-rating-for]", visible: :all).map { |row| row["data-rating-for"] }.uniq
  end

  def rate_section(field, value: "right_level")
    find(%(button[data-rating-for="#{field}"][data-rating="#{value}"])).click
  end
end
