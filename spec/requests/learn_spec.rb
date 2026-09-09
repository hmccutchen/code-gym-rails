require "rails_helper"

RSpec.describe "Learn", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  describe "GET /learn" do
    it "lists every concept in the user's language bucket" do
      user.update!(language: "ruby_rails")
      get learn_path

      expect(response).to have_http_status(:ok)
      AiService::RAILS_CONCEPTS.each { |concept| expect(response.body).to include(concept) }
    end

    it "lists every language-independent bucket's concepts" do
      user.update!(language: "ruby_rails")
      get learn_path

      (AiService::ARCHITECTURE_CONCEPTS + AiService::PLAN_REVIEW_CONCEPTS +
       AiService::AMBIGUITY_HUNT_CONCEPTS + AiService::PSEUDOCODE_TO_CODE_CONCEPTS).each do |concept|
        expect(response.body).to include(concept)
      end
    end

    it "excludes the language the user is not assigned" do
      user.update!(language: "ruby_rails")
      get learn_path

      expect(response.body).not_to include("prototype_chain")
    end

    it "shows both languages to a mixed user" do
      user.update!(language: "mixed")
      get learn_path

      expect(response.body).to include("n_plus_one")
      expect(response.body).to include("prototype_chain")
    end

    it "renders concepts that have no reference row at all" do
      user.update!(language: "ruby_rails")
      expect(ConceptReference.count).to eq(0)

      get learn_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("n_plus_one")
    end

    it "marks a concept the user has been assigned and submitted" do
      user.update!(language: "ruby_rails")
      exercise = user.daily_exercises.create!(
        date: Date.current - 1, language: "ruby_rails", generated_at: Time.current,
        problem_set: { "code_review" => { "concept" => "n_plus_one" } }
      )
      user.daily_responses.create!(
        daily_exercise: exercise, date: Date.current - 1, submitted_at: Time.current,
        answers: { "code_review" => "an answer" }, concept_tags: { "code_review" => "n_plus_one" }
      )

      get learn_path

      expect(response.body).to include(I18n.t("learn.encountered"))
    end

    it "does not mark a concept the user has never been assigned" do
      user.update!(language: "ruby_rails")
      get learn_path

      expect(response.body).not_to include(I18n.t("learn.encountered"))
    end

    # The exposure index counts submitted responses only. An unsubmitted draft
    # must not mark a concept seen, or the marker starts describing today's
    # in-progress set rather than what the user has actually worked through.
    it "does not mark a concept from an unsubmitted response" do
      user.update!(language: "ruby_rails")
      exercise = user.daily_exercises.create!(
        date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: { "code_review" => { "concept" => "n_plus_one" } }
      )
      user.daily_responses.create!(
        daily_exercise: exercise, date: Date.current, submitted_at: nil,
        answers: { "code_review" => "a draft" }, concept_tags: { "code_review" => "n_plus_one" }
      )

      get learn_path

      expect(response.body).not_to include(I18n.t("learn.encountered"))
    end

    it "requires login" do
      delete logout_path
      get learn_path

      expect(response).to redirect_to(login_path)
    end
  end

  # The views resolve headings by key, so a bucket or group added without its
  # string raises in the template rather than at the point of the change. This
  # turns that into a failing spec instead.
  describe "heading coverage" do
    it "has a locale string for every bucket a user can browse" do
      (AiService::LANGUAGE_CONFIG.keys).each do |bucket|
        expect { I18n.t("learn.buckets.#{bucket}", raise: true) }.not_to raise_error
      end
    end

    it "has a locale string for every display group" do
      ConceptGroup::ORDER.each do |group|
        expect { I18n.t("learn.groups.#{group}", raise: true) }.not_to raise_error
      end
    end
  end
end
