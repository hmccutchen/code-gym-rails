require "rails_helper"

RSpec.describe "Learn lessons", type: :request do
  let(:user) { create_user_with_key.tap { |u| u.update!(language: "ruby_rails") } }
  let(:lesson) { "reading_unfamiliar_code" }

  before { login_as(user) }

  describe "GET /learn" do
    it "lists the lesson in the meta-skill group beside its siblings, linked to its page" do
      get learn_path

      page = Nokogiri::HTML(response.body)
      group = page.at_css("##{ApplicationController.helpers.learn_group_anchor('ruby_rails', 'meta_skill')}")
      links = group.css("li.learn-entry a").map { |link| link["href"] }

      expect(links).to include(learn_lesson_path(lesson: lesson))
      AiService::META_SKILL_CONCEPTS.each do |sibling|
        expect(links).to include(learn_concept_path(bucket: "ruby_rails", concept: sibling))
      end
    end

    it "lists it once per language bucket for a mixed user, as its siblings are" do
      user.update!(language: "mixed")
      get learn_path

      expect(response.body.scan(learn_lesson_path(lesson: lesson)).size).to eq(DailyExercise::LANGUAGES.size)
    end

    it "does not count it among the concepts the write-up button would generate" do
      get learn_path

      vocabulary_size = ConceptBucket.slice_for("ruby_rails").sum { |bucket| ConceptBucket.vocabulary_for(bucket).size }
      expect(CGI.unescapeHTML(response.body)).to include(I18n.t("learn.prepare_prompt", count: vocabulary_size))
    end
  end

  describe "GET /learn/lessons/:lesson" do
    it "renders every section, step and code block of the lesson" do
      get learn_lesson_path(lesson: lesson)

      expect(response).to have_http_status(:ok)
      body = CGI.unescapeHTML(response.body)
      LearnLessons.find(lesson)[:sections].each do |section|
        expect(body).to include(section[:heading])
        section[:blocks].each do |type, content|
          texts = type == :steps ? content.flatten : [ content ]
          texts.each { |text| expect(body).to include(text) }
        end
      end
    end

    it "links back to the Learn index" do
      get learn_lesson_path(lesson: lesson)

      expect(Nokogiri::HTML(response.body).at_css("a.learn-back")["href"]).to eq(learn_path)
    end

    it "is a 404 for a lesson that does not exist" do
      get learn_lesson_path(lesson: "n_plus_one")

      expect(response).to have_http_status(:not_found)
    end

    it "calls no provider and writes nothing" do
      expect(AiService).not_to receive(:for)

      expect { get learn_lesson_path(lesson: lesson) }
        .not_to change { [ ApiUsage.count, ConceptReference.count, ConceptMastery.count ] }
    end
  end

  describe "staying out of generation, mastery and drills" do
    it "is in no vocabulary, so no section, mastery row or retention check can carry it" do
      AiService::LANGUAGE_CONFIG.each_value do |config|
        expect(config[:concepts]).not_to include(lesson)
      end
    end

    it "has no concept page and cannot be drilled" do
      get learn_concept_path(bucket: "ruby_rails", concept: lesson)
      expect(response).to have_http_status(:not_found)

      post learn_concept_drill_path(bucket: "ruby_rails", concept: lesson)
      expect(response).to have_http_status(:not_found)
      expect(ConceptMastery.where(concept: lesson)).to be_empty
    end
  end
end
