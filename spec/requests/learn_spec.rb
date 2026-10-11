require "rails_helper"

RSpec.describe "Learn", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  describe "GET /learn" do
    it "lists every concept in the user's language bucket" do
      user.update!(language: "ruby_rails")
      get learn_path

      expect(response).to have_http_status(:ok)
      ConceptVocabulary::RAILS_CONCEPTS.each { |concept| expect(response.body).to include(concept) }
    end

    it "lists every language-independent bucket's concepts" do
      user.update!(language: "ruby_rails")
      get learn_path

      (ConceptVocabulary::ARCHITECTURE_CONCEPTS + ConceptVocabulary::PLAN_REVIEW_CONCEPTS +
       ConceptVocabulary::AMBIGUITY_HUNT_CONCEPTS + ConceptVocabulary::PSEUDOCODE_TO_CODE_CONCEPTS).each do |concept|
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

    # The bulk button counts rows, so "not written yet" must mean no row, distinct from a guide-less row.
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

  # Views resolve headings by key, so a bucket or group missing its string would raise only in the template.
  describe "recognition guides on GET /learn" do
    before { user.update!(language: "ruby_rails") }

    def create_guide(group_key)
      RecognitionGuide.create!(group_key: group_key, questions: "Ask #{group_key} questions.",
                               contrast: "#{group_key} contrast.", misfires: "#{group_key} misfires.")
    end

    def group_block(bucket, group)
      Nokogiri::HTML(response.body).at_css("##{ApplicationController.helpers.learn_group_anchor(bucket, group)}")
    end

    it "renders a named group's guide at the top of its block, above the concept list" do
      create_guide("code_smell")
      get learn_path

      block = group_block("ruby_rails", "code_smell")
      guide = block.at_css(".learn-recognition")
      expect(guide.text).to include("Ask code_smell questions.", "code_smell contrast.", "code_smell misfires.")
      expect(block.css("details.learn-recognition, ul.learn-list").map(&:name)).to eq(%w[details ul])
    end

    it "renders a language-independent bucket's guide above its flat list" do
      create_guide("architecture")
      get learn_path

      expect(group_block("architecture", ConceptGroup::CORE).at_css(".learn-recognition").text)
        .to include("Ask architecture questions.")
    end

    # The guide sits under an h2 or an h3 depending on placement, so a heading inside it would skip a level.
    it "adds no headings, so neither placement skips a heading level" do
      create_guide("architecture")
      create_guide("code_smell")
      get learn_path

      Nokogiri::HTML(response.body).css(".learn-recognition").each do |guide|
        expect(guide.css("h1, h2, h3, h4, h5, h6")).to be_empty
      end
    end

    it "renders no guide in a language bucket's core group" do
      RecognitionGuide::GROUP_KEYS.each { |key| create_guide(key) }
      get learn_path

      expect(group_block("ruby_rails", ConceptGroup::CORE).at_css(".learn-recognition")).to be_nil
    end

    it "offers the backfill when only guides are missing" do
      (%w[ruby_rails] + ConceptBucket::LANGUAGE_INDEPENDENT).each do |bucket|
        ConceptBucket.vocabulary_for(bucket).each do |concept|
          ConceptReference.create!(concept: concept, language: bucket,
                                   tagline: "t", explanation: "e", code_example: "c", senior_lens: "s")
        end
      end
      get learn_path

      expect(response.body).to include(ERB::Util.h(I18n.t("learn.prepare_guides_prompt", count: RecognitionGuide::GROUP_KEYS.size)))
      expect(response.body).not_to include(ERB::Util.h(I18n.t("learn.prepare_prompt", count: 2).delete_prefix("2 ")))
    end

    it "offers no backfill once every concept and guide is written" do
      (%w[ruby_rails] + ConceptBucket::LANGUAGE_INDEPENDENT).each do |bucket|
        ConceptBucket.vocabulary_for(bucket).each do |concept|
          ConceptReference.create!(concept: concept, language: bucket,
                                   tagline: "t", explanation: "e", code_example: "c", senior_lens: "s")
        end
      end
      RecognitionGuide::GROUP_KEYS.each { |key| create_guide(key) }
      get learn_path

      expect(response.body).not_to include(I18n.t("learn.prepare_button"))
    end
  end

  describe "heading coverage" do
    it "has a locale string for every bucket a user can browse" do
      ConceptVocabulary.languages.each do |bucket|
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
        # Without this, deleting the pointer from the view leaves every Learn spec green.
        expect(response.body).to include(source[:pointer]) if source[:pointer]
      end
    end

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

    describe "a row with a lesson" do
      let(:lesson) do
        { "definition" => "LESSON DEFINITION", "situations" => [ "SITUATION ONE" ],
          "habits" => [ { "habit" => "HABIT ONE", "catch" => "CATCH ONE" } ] }
      end

      before do
        full_reference.update!(ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "q", lesson: lesson)
        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
      end

      it "shows the lesson in place of the explanation and the guide's prose" do
        expect(response.body).to include("TAGLINE", "LESSON DEFINITION", "SITUATION ONE", "HABIT ONE", "CATCH ONE")
        expect(response.body).not_to include("EXPLANATION", "PLAIN LANGUAGE", "PITFALLS")
        expect(response.body).not_to include(I18n.t("learn.lesson.comparison"))
      end

      it "folds the code examples and the senior lens closed" do
        page = Nokogiri::HTML(response.body)
        code = page.at_css("details.learn-code-examples")
        senior = page.at_css("details.learn-senior-lens")

        expect(code["open"]).to be_nil
        expect(code.text).to include("User.includes(:posts)", "WORKED EXAMPLE")
        expect(senior["open"]).to be_nil
        expect(senior.text).to include("SENIOR LENS")
      end

      it "offers no write-up control" do
        expect(response.body).not_to include(I18n.t("learn.write_lesson"), I18n.t("learn.write_guide"))
      end
    end

    describe "the lesson control" do
      let!(:written) do
        full_reference.tap { |row| row.update!(ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "q") }
      end

      it "offers the lesson on a guided row without one, polling for the version it saw" do
        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

        expect(response.body).to include(I18n.t("learn.write_lesson"))
        status_url = Nokogiri::HTML(response.body).at_css("#learn-guide")["data-status-url"]
        expect(Rack::Utils.parse_query(URI.parse(status_url).query))
          .to include("awaiting" => "lesson", "generation_version" => written.generation_version.to_s)
        expect(response.body).to include("PLAIN LANGUAGE", "PITFALLS")
      end

      it "says the lesson did not come back after a rewrite without one" do
        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one", lesson: "missing")

        expect(response.body).to include(ERB::Util.h(I18n.t("learn.lesson_missing")))
      end

      it "offers the ladder instead when a target still needs one, since that rewrite writes the lesson too" do
        written.update!(ladder_junior: nil)
        user.update!(section_kind_levels: { "challenge" => "senior" })
        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

        expect(response.body).to include(I18n.t("learn.write_ladder"))
        expect(response.body).not_to include(I18n.t("learn.write_lesson"))
      end
    end

    describe "the ladder control" do
      before { user.update!(language: "ruby_rails") }

      let!(:guided) do
        ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                                 tagline: "t", explanation: "e", code_example: "c", senior_lens: "s",
                                 guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x")
      end

      it "is not offered to a user with no targets" do
        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

        expect(response.body).not_to include(I18n.t("learn.write_ladder"))
      end

      it "is offered, naming the target, when the concept grounds one" do
        user.update!(section_kind_levels: { "challenge" => "senior" })

        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

        expect(response.body).to include(I18n.t("learn.write_ladder"))
        expect(response.body).to include(I18n.t("sections.challenge.name"))
        status_url = Nokogiri::HTML(response.body).at_css("#learn-guide")["data-status-url"]
        expect(Rack::Utils.parse_query(URI.parse(status_url).query))
          .to include("generation_version" => guided.generation_version.to_s)
      end

      it "is not offered when the concept grounds no target" do
        user.update!(section_kind_levels: { "architecture" => "senior" })

        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

        expect(response.body).not_to include(I18n.t("learn.write_ladder"))
      end

      it "explains a rewrite that landed without its ladder, and ignores other values" do
        user.update!(section_kind_levels: { "challenge" => "senior" })

        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one", ladder: "missing")
        expect(response.body).to include(ERB::Util.html_escape(I18n.t("learn.ladder_missing")))

        get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one", ladder: "anything")
        expect(response.body).not_to include(ERB::Util.html_escape(I18n.t("learn.ladder_missing")))
      end

      it "never enqueues a job on a plain visit" do
        user.update!(section_kind_levels: { "challenge" => "senior" })

        expect {
          get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
        }.not_to have_enqueued_job(GenerateConceptReferenceJob)
      end
    end
  end

  describe "GET /learn/:bucket/:concept/status" do
    before { user.update!(language: "ruby_rails") }

    def reference(**attrs)
      ConceptReference.create!({ concept: "n_plus_one", language: "ruby_rails",
                                 tagline: "t", explanation: "e", code_example: "c", senior_lens: "s" }.merge(attrs))
    end

    let(:guide)  { { guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x" } }
    let(:ladder) { { ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "q" } }

    def status(**params)
      get learn_concept_status_path(bucket: "ruby_rails", concept: "n_plus_one", **params)
    end

    it "is not ready when no row exists" do
      status(awaiting: "guide")
      expect(response.parsed_body["ready"]).to be(false)
    end

    it "reads a missing awaiting as guide, the only value pages sent before" do
      reference(**guide)
      status

      expect(response.parsed_body["ready"]).to be(true)
    end

    it "is ready for guide once the guide lands, even when the ladder flubbed" do
      reference(**guide)
      status(awaiting: "guide")

      expect(response.parsed_body["ready"]).to be(true)
    end

    it "waits on the lesson and reports a rewrite that landed without one" do
      row = reference(**guide, **ladder)
      status(awaiting: "lesson", generation_version: row.generation_version)
      expect(response.parsed_body).to include("ready" => false, "rewritten" => false)

      row.update!(generation_version: row.generation_version + 1)
      status(awaiting: "lesson", generation_version: row.generation_version - 1)
      expect(response.parsed_body).to include("ready" => false, "rewritten" => true)

      row.update!(lesson: { "definition" => "d" })
      status(awaiting: "lesson", generation_version: row.generation_version - 1)
      expect(response.parsed_body["ready"]).to be(true)
    end

    it "refuses a lesson poll without the version the page saw" do
      reference(**guide)
      status(awaiting: "lesson")

      expect(response).to have_http_status(:bad_request)
    end

    it "is not ready for ladder until the row is complete" do
      row = reference(**guide)
      status(awaiting: "ladder", generation_version: row.generation_version)
      expect(response.parsed_body).to eq("ready" => false, "rewritten" => false)

      row.update!(**ladder)
      status(awaiting: "ladder", generation_version: row.generation_version)
      expect(response.parsed_body["ready"]).to be(true)
    end

    it "reports a rewrite that landed without a ladder" do
      row = reference(**guide)
      version = row.generation_version
      row.update!(explanation: "rewritten", generation_version: version + 1)

      status(awaiting: "ladder", generation_version: version)

      expect(response.parsed_body).to eq("ready" => false, "rewritten" => true)
    end

    [ {}, { ladder_junior: "j", ladder_senior: "s" } ].each do |partial_ladder|
      it "reports a completed rewrite with unchanged prose and #{partial_ladder.size} ladder rungs" do
        row = reference(**guide)
        version = row.generation_version
        fields = AiService::CONCEPT_REFERENCE_FIELDS + AiService::CONCEPT_GUIDE_FIELDS
        generated = row.attributes.slice(*fields).merge(partial_ladder.stringify_keys)
        service = ClaudeService.new(user.api_key)
        allow(AiService).to receive(:for).with(user).and_return(service)
        allow(service).to receive(:call).and_return(text: generated.to_json, input_tokens: 10, output_tokens: 20)

        GenerateConceptReferenceJob.perform_now(
          concept: row.concept, language: row.language, user_id: user.id, refresh: true
        )
        status(awaiting: "ladder", generation_version: version)

        expect(row.reload.attributes.slice(*fields)).to eq(generated.slice(*fields))
        expect(response.parsed_body).to eq("ready" => false, "rewritten" => true)
      end
    end

    it "does not report a completed generation for a feature stamp or other unrelated update" do
      row = reference(**guide)
      row.update!(featured_on: Date.current)

      status(awaiting: "ladder", generation_version: row.generation_version)

      expect(response.parsed_body).to eq("ready" => false, "rewritten" => false)
    end

    it "400s on an unknown awaiting value" do
      status(awaiting: "everything")
      expect(response).to have_http_status(:bad_request)
    end

    [ nil, "", "-1", "1.5", "1x", [] ].each do |version|
      it "400s on an invalid generation version of #{version.inspect}" do
        status(awaiting: "ladder", generation_version: version)
        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  describe "POST /learn/:bucket/:concept/prepare" do
    before { user.update!(language: "ruby_rails") }

    it "enqueues a refreshing generation for that concept" do
      expect {
        post prepare_learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
      }.to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)

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

    # Derived from the controller's authority so a growing vocabulary needs no edit here.
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

    it "does not ask to refresh a guide-less row, since only a concept someone opens may be refreshed" do
      ConceptReference.create!(
        concept: "memoization", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s"
      )

      expect {
        post prepare_learn_path
      }.not_to have_enqueued_job(GenerateConceptReferenceJob)
        .with(hash_including(refresh: true))
    end

    it "enqueues one job per recognition group with no guide" do
      RecognitionGuide.create!(group_key: "code_smell", questions: "q", contrast: "c", misfires: "m")

      expect {
        post prepare_learn_path
      }.to have_enqueued_job(GenerateRecognitionGuideJob).exactly(RecognitionGuide::GROUP_KEYS.size - 1).times

      expect(GenerateRecognitionGuideJob).not_to have_been_enqueued.with(group_key: "code_smell", user_id: user.id)
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

  describe "POST /learn/prepare_ladders" do
    before { user.update!(language: "ruby_rails") }

    it "enqueues nothing for a user with no targets" do
      expect { post prepare_learn_ladders_path }.not_to have_enqueued_job(GenerateConceptReferenceJob)
      expect(response).to redirect_to(setup_path(anchor: "exercise-mix"))
    end

    it "enqueues one refreshing job per gap across targeted kinds, deduplicated" do
      user.update!(section_kind_levels: { "code_review" => "senior", "challenge" => "junior" })
      expected = LadderCoverage.for(user).gaps_for([ ExerciseSection::CodeReview, ExerciseSection::Challenge ])

      expect {
        post prepare_learn_ladders_path
      }.to have_enqueued_job(GenerateConceptReferenceJob).exactly(expected.size).times

      expect(GenerateConceptReferenceJob).to have_been_enqueued
        .with(concept: expected.first.first, language: expected.first.last, user_id: user.id, refresh: true)
    end

    it "enqueues only what remains after a partial run" do
      user.update!(section_kind_levels: { "security_review" => "senior" })
      vocabulary = ConceptVocabulary.selectable_for_section("security_review", "ruby_rails")
      ConceptReference.create!(concept: vocabulary.first, language: "ruby_rails",
                               ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "p")

      expect {
        post prepare_learn_ladders_path
      }.to have_enqueued_job(GenerateConceptReferenceJob).exactly(vocabulary.size - 1).times
    end
  end
end
