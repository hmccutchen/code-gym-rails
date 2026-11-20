require "rails_helper"

RSpec.describe DuckAnswer do
  let(:user) { instance_double(User, id: 7) }
  let(:exercise) { instance_double(DailyExercise, problem_set: { "code_review" => { "snippet" => "invoices.sum(:total)" } }, language: "ruby_rails") }
  let(:service) { instance_double(AiService) }
  let(:store) do
    instance_double(DuckThread, turns_for: [ { role: "assistant", content: "Plain?" } ],
                                turns_for_duck: [ { role: "assistant", content: "Plain?\nPoint: the sum" } ],
                                narrowing_due?: true, last_point: "the sum")
  end

  before do
    allow(AiService).to receive(:for).with(user).and_return(service)
    allow(Rails.logger).to receive(:info)
  end

  def ask(narrowing:) = described_class.ask(user, exercise, section: "code_review", message: "hmm", store: store, narrowing: narrowing)

  it "is entered only through .ask" do
    expect(described_class).not_to respond_to(:new)
    expect(described_class.public_instance_methods(false)).to contain_exactly(:text, :point, :log_stored)
  end

  it "reads the switch itself when none is passed" do
    allow(DuckNarrowing).to receive(:enabled?).and_return(false)
    allow(service).to receive(:duck_response).and_return("What runs first?")

    described_class.ask(user, exercise, section: "code_review", message: "hmm", store: store)

    expect(DuckNarrowing).to have_received(:enabled?)
  end

  it "with the switch off sends the plain history, reads no gate and logs nothing" do
    allow(service).to receive(:duck_response).and_return("What runs first?")

    answer = ask(narrowing: false)
    answer.log_stored

    expect(service).to have_received(:duck_response).with(user, exercise, section: "code_review", message: "hmm",
                                                                          thread: [ { role: "assistant", content: "Plain?" } ])
    expect(store).not_to have_received(:narrowing_due?)
    expect([ answer.text, answer.point ]).to eq([ "What runs first?", nil ])
    expect(Rails.logger).not_to have_received(:info)
  end

  it "with the switch on sends the labelled history and the gate, and logs only when asked" do
    reply = DuckReply.new(text: "Look at `invoices.sum`. What runs?", point: "the sum")
    allow(service).to receive(:labelled_duck_response).and_return(reply)

    answer = ask(narrowing: true)

    expect(service).to have_received(:labelled_duck_response).with(user, exercise, section: "code_review", message: "hmm",
                                                                                   thread: store.turns_for_duck("code_review"), narrow: true)
    expect([ answer.text, answer.point ]).to eq([ reply.text, "the sum" ])
    expect(Rails.logger).not_to have_received(:info)

    answer.log_stored

    expect(Rails.logger).to have_received(:info).with("[duck_point] user=7 section=code_review question=true labelled=true matched=true")
    expect(Rails.logger).to have_received(:info).with("[duck_narrowing] user=7 section=code_review quote=found")
  end

  describe "concept example permission" do
    let(:pattern) { { "question" => "How should a new registration work?", "concept" => "strategy_pattern" } }
    let(:problem_set) { { "pattern" => pattern } }
    let(:plan_notes) { {} }
    let(:exercise) { DailyExercise.new(problem_set: problem_set, plan_notes: plan_notes) }

    def ask_for_examples(section, narrowing:)
      described_class.ask(user, exercise, section: section, message: "Could you show a small example?", store: store, narrowing: narrowing)
    end

    before do
      stub_env("DUCK_CONCEPT_EXAMPLES" => "1")
      allow(service).to receive(:duck_response).and_return("An independent example.")
      allow(service).to receive(:labelled_duck_response).and_return(DuckReply.new(text: "An independent example.", point: nil))
    end

    { duck_response: false, labelled_duck_response: true }.each do |route, narrowing|
      context "through #{route}" do
        def expect_duck_call(route, section, narrowing:, **permission)
          history = narrowing ? { thread: store.turns_for_duck(section), narrow: true } : { thread: store.turns_for(section) }
          expect(service).to have_received(route).with(user, exercise, section: section, message: "Could you show a small example?",
                                                                       **history, **permission).once
        end

        it "allows an active Pattern with a visible concept" do
          expect(ask_for_examples("pattern", narrowing: narrowing).text).to eq("An independent example.")
          expect_duck_call(route, "pattern", narrowing: narrowing, concept_examples: true)
        end

        it "allows the existing untagged Pattern context" do
          pattern.delete("concept")

          ask_for_examples("pattern", narrowing: narrowing)

          expect_duck_call(route, "pattern", narrowing: narrowing, concept_examples: true)
        end

        it "keeps the original request when the switch is off" do
          stub_env("DUCK_CONCEPT_EXAMPLES" => nil)

          ask_for_examples("pattern", narrowing: narrowing)

          expect_duck_call(route, "pattern", narrowing: narrowing)
        end

        context "when an active section withholds the same concept" do
          let(:problem_set) do
            { "pattern" => pattern, "code_review" => { "concept" => pattern.fetch("concept"), "purpose" => "Find the gotcha." } }
          end

          it "keeps the original Pattern request" do
            expect(exercise.concepts_withheld_before_submission).to include(pattern.fetch("concept"))

            ask_for_examples("pattern", narrowing: narrowing)

            expect_duck_call(route, "pattern", narrowing: narrowing)
          end
        end

        it "honors the selected kind's visibility decision" do
          allow(ExerciseSection::Pattern).to receive(:concept_shown_before_submission?).with(pattern).and_return(false)

          ask_for_examples("pattern", narrowing: narrowing)

          expect_duck_call(route, "pattern", narrowing: narrowing)
        end

        context "when a stored Pattern is not active" do
          let(:problem_set) do
            {
              "pattern" => pattern, "code_review" => {}, "design_comparison" => {},
              "architecture" => {}, "challenge" => {}
            }
          end
          let(:plan_notes) { { "daily_kinds" => %w[code_review design_comparison architecture challenge] } }

          it "keeps the original request" do
            expect(exercise.active_section_keys).not_to include("pattern")

            ask_for_examples("pattern", narrowing: narrowing)

            expect_duck_call(route, "pattern", narrowing: narrowing)
          end
        end

        (ExerciseSection.keys - [ "pattern" ] + [ "future_kind" ]).each do |kind|
          context "for #{kind}" do
            let(:problem_set) { { kind => pattern } }

            it "keeps the original request" do
              ask_for_examples(kind, narrowing: narrowing)

              expect_duck_call(route, kind, narrowing: narrowing)
            end
          end
        end

        [ nil, "Malformed section", [], {}, { "question" => [ "Not prose" ] },
          { "question" => "What is the strategy?", "concept" => [ "Not a tag" ] } ].each do |invalid_pattern|
          context "with stored Pattern data #{invalid_pattern.inspect}" do
            let(:pattern) { invalid_pattern }

            it "keeps the original request" do
              ask_for_examples("pattern", narrowing: narrowing)

              expect_duck_call(route, "pattern", narrowing: narrowing)
            end
          end
        end
      end
    end
  end
end
