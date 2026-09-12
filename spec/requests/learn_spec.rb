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

    # A row that exists but lacks a guide is a different fact from no row at
    # all — the bulk button's count is row-existence based, so the "not written
    # yet" marker must mean exactly that, and a guide-less row needs its own
    # marker or the two disagree once the button's count reaches zero while
    # guide-less rows remain.
    it "marks a concept with no row at all as not written yet, distinct from one with a reference but no guide" do
      user.update!(language: "ruby_rails")
      ConceptReference.create!(
        concept: "memoization", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s"
      )

      get learn_path

      expect(response.body).to include(I18n.t("learn.not_generated"))
      expect(response.body).to include(I18n.t("learn.reference_only"))
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

  describe "GET /learn/:bucket/:concept" do
    before { user.update!(language: "ruby_rails") }

    def full_reference
      ConceptReference.create!(
        concept: "n_plus_one", language: "ruby_rails",
        tagline: "TAGLINE", explanation: "EXPLANATION",
        code_example: "User.includes(:posts)", senior_lens: "SENIOR LENS",
        guide_plain_language: "PLAIN LANGUAGE", guide_worked_example: "WORKED EXAMPLE",
        guide_pitfalls: "PITFALLS"
      )
    end

    it "renders the reference and the guide together" do
      full_reference
      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("TAGLINE", "EXPLANATION", "SENIOR LENS")
      expect(response.body).to include("PLAIN LANGUAGE", "WORKED EXAMPLE", "PITFALLS")
    end

    it "lists a cited concept's book sources" do
      full_reference
      get learn_concept_path(bucket: "ruby_rails", concept: "shotgun_surgery")

      expect(response.body).to include(I18n.t("learn.sources"))
      ConceptBookSources.for("shotgun_surgery").each do |source|
        expect(response.body).to include(source[:title], source[:author])
      end
    end

    # A citation is static, so it does not wait on a reference the team has
    # never generated.
    it "lists the sources even with no reference row at all" do
      get learn_concept_path(bucket: "ruby_rails", concept: "shotgun_surgery")

      expect(response.body).to include(I18n.t("learn.sources"))
    end

    it "renders no sources heading for an uncited concept" do
      full_reference
      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.body).not_to include(I18n.t("learn.sources"))
    end

    it "renders a legacy row's reference with a control to write the guide" do
      ConceptReference.create!(
        concept: "n_plus_one", language: "ruby_rails",
        tagline: "TAGLINE", explanation: "EXPLANATION",
        code_example: "code", senior_lens: "SENIOR LENS"
      )
      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.body).to include("TAGLINE")
      expect(response.body).to include("code")
      expect(response.body).to include("SENIOR LENS")
      expect(response.body).to include(I18n.t("learn.write_guide"))
    end

    it "renders a concept with no row at all as an offer to generate it" do
      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("learn.write_guide"))
    end

    it "404s on a concept that is not in that bucket's vocabulary" do
      get learn_concept_path(bucket: "ruby_rails", concept: "prototype_chain")

      expect(response).to have_http_status(:not_found)
    end

    it "404s on an invented concept" do
      get learn_concept_path(bucket: "ruby_rails", concept: "not_a_concept")

      expect(response).to have_http_status(:not_found)
    end

    it "404s on a bucket outside the user's slice" do
      get learn_concept_path(bucket: "javascript", concept: "prototype_chain")

      expect(response).to have_http_status(:not_found)
    end

    it "serves the other language to a mixed user" do
      user.update!(language: "mixed")
      get learn_concept_path(bucket: "javascript", concept: "prototype_chain")

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /learn/:bucket/:concept/status" do
    before { user.update!(language: "ruby_rails") }

    it "is not ready when no row exists" do
      get learn_concept_status_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.parsed_body["ready"]).to be(false)
    end

    it "is not ready for a row that has no guide" do
      ConceptReference.create!(
        concept: "n_plus_one", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s"
      )
      get learn_concept_status_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.parsed_body["ready"]).to be(false)
    end

    it "is ready once the guide is written" do
      ConceptReference.create!(
        concept: "n_plus_one", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s",
        guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x"
      )
      get learn_concept_status_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.parsed_body["ready"]).to be(true)
    end
  end

  describe "POST /learn/:bucket/:concept/prepare" do
    before { user.update!(language: "ruby_rails") }

    it "enqueues a refreshing generation for that concept" do
      expect {
        post prepare_learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
      }.to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh_guide: true)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("queued")
    end

    it "404s on an off-vocabulary pair" do
      post prepare_learn_concept_path(bucket: "ruby_rails", concept: "prototype_chain")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /learn/prepare" do
    before { user.update!(language: "ruby_rails") }

    # Derived from the same authority the controller reads, not a hand-added
    # sum: a vocabulary that grows must not need this number edited.
    it "enqueues one job per concept with no row at all" do
      expected = (%w[ruby_rails] + ConceptBucket::LANGUAGE_INDEPENDENT)
                   .sum { |bucket| ConceptBucket.vocabulary_for(bucket).size }

      expect {
        post prepare_learn_path
      }.to have_enqueued_job(GenerateConceptReferenceJob).exactly(expected).times

      expect(response).to redirect_to(learn_path)
    end

    it "skips a concept that already has a row" do
      ConceptReference.create!(
        concept: "n_plus_one", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s"
      )

      expect {
        post prepare_learn_path
      }.not_to have_enqueued_job(GenerateConceptReferenceJob)
        .with(hash_including(concept: "n_plus_one"))
    end

    # The backfill must never rewrite a legacy row in bulk — that would change
    # inline reference text for concepts nobody asked about. Only the
    # per-concept path, on a concept someone opened, may do that.
    it "does not ask to refresh a guide-less row" do
      ConceptReference.create!(
        concept: "memoization", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s"
      )

      expect {
        post prepare_learn_path
      }.not_to have_enqueued_job(GenerateConceptReferenceJob)
        .with(hash_including(refresh_guide: true))
    end

    it "enqueues nothing once every concept has a row" do
      (%w[ruby_rails] + ConceptBucket::LANGUAGE_INDEPENDENT).each do |bucket|
        ConceptBucket.vocabulary_for(bucket).each do |concept|
          ConceptReference.create!(
            concept: concept, language: bucket,
            tagline: "t", explanation: "e", code_example: "c", senior_lens: "s"
          )
        end
      end

      expect { post prepare_learn_path }.not_to have_enqueued_job(GenerateConceptReferenceJob)
    end
  end
end
