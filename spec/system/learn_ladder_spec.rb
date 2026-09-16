require "rails_helper"

RSpec.describe "Learn ladder generation", type: :system, with_csrf: true do
  it "offers another attempt when generation finishes with unchanged prose and an incomplete ladder" do
    user = create_fake_provider_user
    user.update!(language: "ruby_rails", section_kind_levels: { "challenge" => "senior" })
    prose = (AiService::CONCEPT_REFERENCE_FIELDS + AiService::CONCEPT_GUIDE_FIELDS)
              .index_with { |field| "Existing #{field.humanize.downcase}." }
    reference = ConceptReference.create!(prose.merge(concept: "n_plus_one", language: "ruby_rails"))
    allow_any_instance_of(FakeService).to receive(:generate_concept_reference)
      .with(user, reference.concept, reference.language).and_return(prose)

    visit_as(user)
    visit learn_concept_path(bucket: reference.language, concept: reference.concept)

    perform_enqueued_jobs(only: GenerateConceptReferenceJob) do
      click_button I18n.t("learn.write_ladder")

      expect(page).to have_css(".learn-ladder-missing", text: I18n.t("learn.ladder_missing"))
      expect(page).to have_button(I18n.t("learn.write_ladder"), disabled: false)
    end
  end
end
