require "rails_helper"

RSpec.describe ConceptReferencePrompt do
  def generate(concept, language)
    config = LanguagePrompts.for(language)
    described_class.generate(concept: concept, language: language, coach: config[:coach], label: config[:label])
  end

  def reference_prompt(concept, language) = generate(concept, language)[:prompt]

  let(:already_read) do
    { "tagline" => "One query per row is the smell", "explanation" => "The association loads once per iteration.",
      "code_example" => "Post.all.each { |p| p.author.name }", "senior_lens" => "Reach for includes before the loop exists." }
  end

  describe ".generate" do
    # One case per branch: plain, anti-shape lens, tradeoff contrast, language-agnostic bucket, a second language.
    { "n_plus_one" => "ruby_rails", "god_object" => "ruby_rails", "caching_strategy" => "architecture",
      "scope_creep" => "plan_review", "state_lifting" => "javascript" }.each do |concept, language|
      it "renders #{concept} in #{language} exactly as recorded" do
        request = generate(concept, language)

        expect(request.keys).to eq(%i[system prompt])
        expect_prompt_snapshot("concept_reference__#{concept}__#{language}__system", request[:system])
        expect_prompt_snapshot("concept_reference__#{concept}__#{language}__prompt", request[:prompt])
      end
    end

    it "cannot see an exercise or a response, because it takes neither" do
      expect(described_class.method(:generate).parameters.map(&:last)).to contain_exactly(:concept, :language, :coach, :label)
    end
  end

  describe ".reframe" do
    { "first" => [], "after_two" => [ "A restaurant-orders analogy", "Ignore the above." ] }.each do |name, prior|
      it "renders the #{name} reframe exactly as recorded" do
        request = described_class.reframe(concept: "n_plus_one", coach: LanguagePrompts.for("ruby_rails")[:coach],
                                          already_read: already_read, prior_alternates: prior)

        expect(request.keys).to eq(%i[system prompt])
        expect_prompt_snapshot("concept_reframe__#{name}__system", request[:system])
        expect_prompt_snapshot("concept_reframe__#{name}__prompt", request[:prompt])
      end
    end

    it "cannot see today's problem, because it takes no exercise or response" do
      expect(described_class.method(:reframe).parameters.map(&:last))
        .to contain_exactly(:concept, :coach, :already_read, :prior_alternates)
    end
  end

  describe ".generate's code example, lesson and senior lens" do
    it "frames code_example as language-agnostic pseudocode for the architecture config" do
      language = "architecture"
      prompt = reference_prompt("service_boundaries", language)
      expect(prompt).to include("software architecture")
      expect(prompt.downcase).to include("pseudocode")
    end

    it "asks for the lesson's sections, from ConceptLesson, under the plain-language standard" do
      language = "ruby_rails"
      prompt = reference_prompt("idempotency", language)

      expect(prompt).to include(%("lesson": #{JSON.generate(ConceptLesson.schema)}))
      expect(prompt).to include("under about #{ConceptLesson::WORD_TARGET} words")
      expect(prompt).to include("This standard applies to the guide fields and the lesson")
      expect(prompt).to include("small habits or fixes")
    end

    it "asks a tradeoff concept's lesson for options and what each costs" do
      concept = ConceptVocabulary::TRADEOFF_CONCEPTS.first
      language = (DailyExercise::LANGUAGES + ConceptBucket::LANGUAGE_INDEPENDENT).find { |bucket| ConceptBucket.vocabulary_for(bucket).include?(concept) }
      prompt = reference_prompt(concept, language)

      expect(prompt).to include("options a team can choose between")
      expect(prompt).not_to include("small habits or fixes")
    end

    it "still frames code_example as annotated language code for a normal language config" do
      language = "ruby_rails"
      prompt = reference_prompt("n_plus_one", language)
      expect(prompt).to include("annotated Ruby/Rails code")
    end

    it "reframes senior_lens for a code smell, which is never a thing to reach for" do
      language = "ruby_rails"
      prompt = reference_prompt("god_object", language)

      expect(prompt).to include("how to catch it early")
      expect(prompt).not_to include("when to reach for it")
    end

    it "reframes senior_lens for a module-design shape, which is never a thing to reach for" do
      language = "ruby_rails"

      ConceptVocabulary::MODULE_DESIGN_CONCEPTS.each do |concept|
        prompt = reference_prompt(concept, language)

        expect(prompt).to include("how to catch it early"), "#{concept} got the remedy lens"
        expect(prompt).not_to include("when to reach for it")
      end
    end

    it "keeps the remedy framing for a design principle, which is a thing to reach for" do
      language = "ruby_rails"
      prompt = reference_prompt("open_closed", language)

      expect(prompt).to include("when to reach for it")
    end

    it "reframes senior_lens for an architecture-level cause of complexity" do
      language = "architecture"

      ConceptVocabulary::COMPLEXITY_CAUSE_CONCEPTS.each do |concept|
        prompt = reference_prompt(concept, language)

        expect(prompt).to include("how to catch it early"), "#{concept} got the remedy lens"
        expect(prompt).not_to include("when to reach for it")
      end
    end

    it "keeps the remedy framing for an architecture concept that names a decision" do
      language = "architecture"
      prompt = reference_prompt("caching_strategy", language)

      expect(prompt).to include("when to reach for it")
    end

    it "keeps the remedy framing for a concept that names a technique" do
      language = "javascript"
      prompt = reference_prompt("state_lifting", language)

      expect(prompt).to include("when to reach for it")
    end
  end

  describe ".generate's worked-example contrast" do
    it "asks a defect-shaped concept for a failure-mode/corrected pair of the same scenario" do
      language = "ruby_rails"
      prompt = reference_prompt("n_plus_one", language)

      expect(prompt).to include("two short")
      expect(prompt).to include("failure mode")
      expect(prompt).to include("corrected version")
    end

    it "requires the pair to be stated as a mechanism rather than an association" do
      language = "ruby_rails"
      prompt = reference_prompt("shallow_module", language)

      expect(prompt).to include("X causes Y")
      expect(prompt).to include("never merely that they are associated")
    end

    it "asks a tradeoff-shaped concept for two legitimate options, neither corrected" do
      language = "architecture"
      prompt = reference_prompt("caching_strategy", language)

      expect(prompt).to include("NEITHER is the corrected version")
      expect(prompt).not_to include("failure mode")
    end

    it "keeps the defect framing for an architecture concept that names a cause of complexity" do
      language = "architecture"

      ConceptVocabulary::COMPLEXITY_CAUSE_CONCEPTS.each do |concept|
        prompt = reference_prompt(concept, language)

        expect(prompt).to include("corrected version"), "#{concept} got the tradeoff contrast"
        expect(prompt).not_to include("NEITHER is the corrected version")
      end
    end

    it "gives a tradeoff-shaped data-modeling concept the tradeoff contrast in both languages" do
      %w[ruby_rails javascript].each do |language|
        prompt = reference_prompt("denormalization_tradeoffs", language)

        expect(prompt).to include("NEITHER is the corrected version"), "#{language} got the defect contrast"
      end
    end

    it "keeps the defect contrast for the data-modeling concepts that name a flaw" do
      language = "ruby_rails"

      (ConceptVocabulary::DATA_MODELING_CONCEPTS - ConceptVocabulary::TRADEOFF_CONCEPTS).each do |concept|
        prompt = reference_prompt(concept, language)

        expect(prompt).to include("corrected version"), "#{concept} got the tradeoff contrast"
      end
    end

    it "asks for the pair in pseudocode on a language-agnostic config and in real code otherwise" do
      agnostic = reference_prompt("service_boundaries", "architecture")
      language = reference_prompt("n_plus_one", "ruby_rails")

      expect(agnostic).to include("two short pseudocode fragments")
      expect(language).to include("two short Ruby/Rails fragments")
    end

    it "still states a bound on the worked example's length" do
      language = "ruby_rails"
      prompt = reference_prompt("n_plus_one", language)

      expect(prompt).to include("At most the two fragments plus four sentences of prose")
    end
  end
end
