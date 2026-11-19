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
end
