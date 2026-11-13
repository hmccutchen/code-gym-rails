require "rails_helper"

RSpec.describe "Learn ladder generation", type: :system, with_csrf: true do
  let(:user) { create_fake_provider_user.tap { |u| u.update!(language: "ruby_rails", section_kind_levels: { "challenge" => "senior" }) } }
  let(:prose) do
    (ConceptReference::REFERENCE_FIELDS + ConceptReference::GUIDE_FIELDS).index_with { |field| "Existing #{field.humanize.downcase}." }
  end
  let!(:reference) { ConceptReference.create!(prose.merge(user: user, concept: "n_plus_one", language: "ruby_rails")) }

  def press_ladder
    visit_as(user)
    visit learn_concept_path(bucket: reference.language, concept: reference.concept)

    perform_enqueued_jobs(only: GenerateConceptReferenceJob) do
      click_button I18n.t("learn.write_ladder")
      yield
    end
  end

  it "writes the ladder and keeps the text the person already read" do
    press_ladder do
      expect(page).to have_no_button(I18n.t("learn.write_ladder"))
      expect(page).to have_content("Existing explanation.")
    end

    expect(reference.reload).to be_ladder
    expect(reference.attributes.slice(*prose.keys)).to eq(prose)
  end

  it "offers another attempt when the ladder comes back incomplete, and leaves the text alone" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow_any_instance_of(FakeService).to receive(:generate_concept_ladder)
      .and_raise(ProviderError::InvalidResponseError, "Concept ladder missing usable rung(s): ladder_senior")

    press_ladder do
      expect(page).to have_button(I18n.t("learn.write_ladder"), disabled: false)
      expect(page).to have_css(".learn-status", text: /\S/)
      expect(page).to have_no_css(".learn-status", text: I18n.t("learn.writing_guide"))
    end

    expect(reference.reload.attributes.slice(*prose.keys, "generation_version")).to eq(prose.merge("generation_version" => 0))
  end
end
