require "rails_helper"

# Background saves used to swallow every failure: the fetch promise was never
# consumed, so a rejected write left the control showing a state the server had
# refused. A request spec cannot see that — it exercises the endpoint, not the
# page's handling of the answer — so these drive a real browser and assert what
# the engineer is actually told.
RSpec.describe "Save status", type: :system do
  let(:user) { create_fake_provider_user }

  def break_the_network
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")
  end

  # Unreachable by clicking, which is the point: the last un-excluded kind in a
  # group has its checkbox disabled. Stripping that attribute reproduces a tab
  # whose DOM predates another tab's exclusions — the one case that can post a
  # slot-emptying set and earn a real 422.
  def exclude_every_fourth_kind
    ExerciseSection.fourths.each do |kind|
      page.execute_script("document.querySelector('#exclude-#{kind.key}').disabled = false")
      find("#exclude-#{kind.key}").click
    end
  end

  it "reports a dropped connection while answers are auto-saving" do
    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      break_the_network
      find(%(textarea[data-field="code_review"]))
        .fill_in(with: "An answer the server is never going to receive.")

      expect(page).to have_css("#save-status", text: /couldn't save/i, wait: 5)
      expect(user.daily_responses).to be_empty
    end
  end

  it "reports the server's own reason when a stale page is refused" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    exclude_every_fourth_kind

    expect(page).to have_css("#save-status", text: /at least one fourth section/i, wait: 5)
    expect(user.reload.excluded_section_kinds).not_to match_array(ExerciseSection.fourths.map(&:key))
  end

  it "clears the report once a later save succeeds" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    exclude_every_fourth_kind
    expect(page).to have_css("#save-status", wait: 5)

    # Un-excluding one leaves a kind in the group, so this payload is accepted.
    find("#exclude-#{ExerciseSection.fourths.first.key}").click

    expect(page).to have_no_css("#save-status", visible: true, wait: 5)
    expect(user.reload.excluded_section_kinds)
      .to match_array(ExerciseSection.fourths.drop(1).map(&:key))
  end
end
