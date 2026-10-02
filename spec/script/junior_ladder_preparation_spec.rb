require "rails_helper"
require Rails.root.join("script/junior_ladder_preparation")

RSpec.describe JuniorLadderPreparation do
  include ActiveJob::TestHelper
  include AuthHelpers

  let(:out) { StringIO.new }
  let(:operator) { create_fake_provider_user }
  let(:preparation) { described_class.new(operator_id: operator.id, out: out) }

  before do
    expect(AiService).not_to receive(:for)
  end

  it "reports every kind without writing accounts, references, usage or jobs" do
    before = operator.attributes

    expect { preparation.report }
      .not_to change { [ User.count, ConceptReference.count, ApiUsage.count, enqueued_jobs.size ] }

    expect(operator.reload.attributes).to eq(before)
    expect(out.string).to include(*ExerciseSection.keys)
    expect(out.string).to match(/\d+ pairs without a ladder/)
  end

  it "derives coverage from an unsaved mixed user, independent of operator preferences" do
    operator.update!(language: "ruby_rails", section_kind_levels: { "code_review" => "senior" })
    expect(LadderCoverage).to receive(:for).with(
      an_object_having_attributes(language: "mixed", new_record?: true, section_kind_levels: {})
    ).and_call_original

    expect(preparation.gaps.map(&:last)).to include("ruby_rails", "javascript")
  end

  it "reports billing and shared whole-reference rewrites before a run" do
    preparation.report

    expect(out.string).to include("billed to user #{operator.id}", "--run")
    expect(out.string).to include("reference and guide wording", "every user")
    expect(out.string).not_to include(operator.api_key)
  end

  it "queues each missing or incomplete ladder once, excluding grounded pairs" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
      ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "p")
    ConceptReference.create!(concept: "caching", language: "ruby_rails", ladder_junior: "j")
    gaps = preparation.gaps

    expect(gaps).to include([ "caching", "ruby_rails" ])
    expect(gaps).not_to include([ "n_plus_one", "ruby_rails" ])
    expect(gaps).to eq(gaps.uniq)
    expect { preparation.run! }
      .to have_enqueued_job(GenerateConceptReferenceJob).exactly(gaps.size).times
    gaps.each do |concept, bucket|
      expect(GenerateConceptReferenceJob).to have_been_enqueued.with(
        concept: concept, language: bucket, user_id: operator.id, refresh: true
      ).exactly(:once)
    end
    expect(out.string).to include("Queued #{gaps.size} jobs, billed to user #{operator.id}")
  end

  it "does not enqueue or alter records when every pair is grounded" do
    preparation.gaps.each do |concept, bucket|
      ConceptReference.create!(concept: concept, language: bucket,
        ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "p")
    end
    fresh = described_class.new(operator_id: operator.id, out: out)

    expect { fresh.run! }.not_to have_enqueued_job
    expect(out.string).to include("Queued 0 jobs")
  end

  it "refuses an operator without an API key before enqueueing" do
    operator.update!(api_keys: nil)

    expect { preparation.run! }.to raise_error(ArgumentError, /no API key/)
    expect(enqueued_jobs).to be_empty
  end

  it "rechecks that the operator is active when running" do
    preparation.report
    operator.update!(anonymized_at: Time.current)

    expect { preparation.run! }.to raise_error(ActiveRecord::RecordNotFound)
    expect(enqueued_jobs).to be_empty
  end

  it "refuses a missing operator before enqueueing" do
    missing = described_class.new(operator_id: 0, out: out)

    expect { missing.run! }.to raise_error(ActiveRecord::RecordNotFound)
    expect(enqueued_jobs).to be_empty
  end

  describe "runner CLI" do
    def run_cli(*args)
      stub_const("ARGV", args)
      load Rails.root.join("script/prepare_junior_ladders.rb")
    end

    it "defaults to a coverage-only dry run" do
      id = operator.id.to_s

      expect { run_cli(id) }.to output(/pairs without a ladder/).to_stdout
      expect(enqueued_jobs).to be_empty
    end

    it "enqueues only with the explicit --run option" do
      id = operator.id.to_s
      count = preparation.gaps.size

      expect { run_cli(id, "--run") }.to output(/Queued #{count} jobs/).to_stdout
      expect(enqueued_jobs.size).to eq(count)
    end

    [ [], [ "abc" ], [ "1.5" ], [ "0" ], [ "-1" ], [ "0x10" ],
      [ "1", "--dry-run" ], [ "1", "--rnu" ], [ "1", "extra" ],
      [ "1", "--run", "--run" ], [ "1", "--run", "extra" ],
      [ "--run", "1" ] ].each do |args|
      it "rejects malformed arguments #{args.inspect} before reporting or enqueueing" do
        expect(described_class).not_to receive(:new)

        expect {
          expect { run_cli(*args) }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        }.to output(/Usage:.*<operator_user_id> \[--run\]/).to_stderr
        expect(enqueued_jobs).to be_empty
      end
    end
  end
end
