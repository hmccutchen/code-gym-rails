require "rails_helper"

RSpec.describe "Learn write-up past the hourly limit", type: :system, with_csrf: true do
  it "shows the limit message instead of claiming work is in progress" do
    user = create_fake_provider_user
    user.update!(language: "ruby_rails")
    visit_as(user)
    # A trial, the one account the limit used to reach, is offered no write-up since Learn became per user.
    allow_any_instance_of(LearnController).to receive(:own_key?).and_return(false)
    store = ActiveSupport::Cache::MemoryStore.new
    allow(store).to receive(:increment).and_return(LearnController::PREPARE_PER_HOUR + 1)
    allow(Rails).to receive(:cache).and_return(store)

    visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
    click_button I18n.t("learn.write_guide")

    expect(page).to have_css(".learn-status", text: I18n.t("learn.preparing_limited"))
    expect(page).to have_no_text(I18n.t("learn.write_guide_failed"))
    expect(page).to have_button(I18n.t("learn.write_guide"), disabled: false)
    expect(GenerateConceptReferenceJob).not_to have_been_enqueued
  end
end
