require "rails_helper"

# Pins what every section kind renders, in all three places a section appears:
# the dashboard answer form, the dashboard's submitted (read-only) state, and a
# history entry.
#
# This guards the refactor that replaces the two elsif chains in
# dashboard/_exercise and responses/_answered_sections with one loop over
# DailyExercise#active_section_keys, rendering each kind through a shared
# wrapper. There is no byte-level equivalent of the prompt snapshots for views,
# so this stands in for one: every field each kind puts on the page is asserted
# by a marker string distinctive enough that the assertion can only pass if that
# exact field reached that exact render.
#
# All eight kinds are covered across all three renders, enumerated from
# DailyPlan's weight tables rather than sampled — a kind quietly dropping out of
# one of the three renders is the specific failure this exists to catch.
#
# Recorded against unmodified views. Anything asserted here is current
# behaviour, not desired behaviour: the numbering in SLOT_LABELS is hardcoded
# per kind today, and the refactor deliberately changes it to derive from the
# loop index (see the commit that does so).
RSpec.describe "section rendering", type: :request do
  let(:user) { create_user_with_key }

  # One distinctive marker per field. "SECRET" markers must never appear.
  PAYLOADS = {
    "code_review" => {
      "question" => "CR-QUESTION", "snippet" => "CR-SNIPPET", "scenario" => "CR-SCENARIO",
      "teaching_note" => "CR-HINT", "concept" => "n_plus_one"
    },
    "pattern" => {
      "title" => "PAT-TITLE", "why" => "PAT-WHY", "question" => "PAT-QUESTION",
      "scenario" => "PAT-SCENARIO", "teaching_note" => "PAT-HINT", "concept" => "service_objects"
    },
    "challenge" => {
      "title" => "CH-TITLE", "question" => "CH-QUESTION", "starter_code" => "CH-STARTER",
      "scenario" => "CH-SCENARIO", "teaching_note" => "CH-HINT", "concept" => "idempotency"
    },
    "architecture" => {
      "title" => "ARCH-TITLE", "question" => "ARCH-QUESTION", "scenario" => "ARCH-SCENARIO",
      "options" => [ "ARCH-OPTION-ONE", "ARCH-OPTION-TWO" ],
      "reference" => {
        "tagline" => "ARCH-TAGLINE", "explanation" => "ARCH-EXPLANATION",
        "tradeoffs" => [ "ARCH-TRADEOFF" ], "senior_lens" => "ARCH-LENS", "diagram" => ""
      },
      "teaching_note" => "ARCH-HINT", "concept" => "service_boundaries"
    },
    "security_review" => {
      "title" => "SEC-TITLE", "question" => "SEC-QUESTION", "snippet" => "SEC-SNIPPET",
      "scenario" => "SEC-SCENARIO", "teaching_note" => "SEC-HINT", "concept" => "sql_injection_prevention"
    },
    "parsons_problem" => {
      "title" => "PB-TITLE", "question" => "PB-QUESTION", "scenario" => "PB-SCENARIO",
      "blocks" => [ "PB-BLOCK-ONE", "PB-BLOCK-TWO", "PB-BLOCK-THREE" ],
      "display_order" => [ 2, 0, 1 ],
      "teaching_note" => "PB-HINT", "concept" => "memoization"
    },
    "plan_review" => {
      "title" => "PR-TITLE", "question" => "PR-QUESTION", "scenario" => "PR-SCENARIO",
      "plan_excerpt" => "PR-EXCERPT", "teaching_note" => "PR-HINT", "concept" => "scope_creep"
    },
    "ambiguity_hunt" => {
      "title" => "AH-TITLE", "question" => "AH-QUESTION", "scenario" => "AH-SCENARIO",
      "request" => "AH-REQUEST",
      "planted_ambiguities" => [ "AH-SECRET-ONE", "AH-SECRET-TWO" ],
      "teaching_note" => "AH-HINT", "concept" => "unspecified_edge_cases"
    }
  }.freeze

  # The label each kind renders today, slot number included. The numbers are
  # hardcoded per kind at the time of recording.
  SLOT_LABELS = {
    "code_review"     => "1 — Code Review",
    "pattern"         => "2 — Pattern of the Month: PAT-TITLE",
    "challenge"       => "3 — Coding Challenge",
    "architecture"    => "3 — Architecture Decision: ARCH-TITLE",
    "security_review" => "3 — Security Review: SEC-TITLE",
    "parsons_problem" => "3 — Parsons Problem: PB-TITLE",
    "plan_review"     => "4 — Plan Review: PR-TITLE",
    "ambiguity_hunt"  => "4 — Ambiguity Hunt: AH-TITLE"
  }.freeze

  # Body content unique to each kind — the part no shared wrapper can render.
  BODY_MARKERS = {
    "code_review"     => [ "CR-SNIPPET" ],
    "pattern"         => [ "PAT-WHY" ],
    "challenge"       => [ "CH-STARTER" ],
    "architecture"    => [ "ARCH-OPTION-ONE", "ARCH-OPTION-TWO", "ARCH-TAGLINE", "ARCH-TRADEOFF", "ARCH-LENS" ],
    "security_review" => [ "SEC-SNIPPET" ],
    "parsons_problem" => [ "PB-BLOCK-ONE", "PB-BLOCK-TWO", "PB-BLOCK-THREE" ],
    "plan_review"     => [ "PR-EXCERPT" ],
    "ambiguity_hunt"  => [ "AH-REQUEST" ]
  }.freeze

  ANSWER_KEY_MARKERS = %w[AH-SECRET-ONE AH-SECRET-TWO].freeze

  # parsons_problem stores a positional order, not prose, and its read-only
  # render replays the blocks in that order rather than echoing the answer —
  # so it is the one kind whose submitted state cannot be asserted by looking
  # for the stored string. "order:0,2,1" against three blocks puts the first
  # block right and the other two wrong, exercising both rendered states.
  PARSONS_ANSWER = "order:0,2,1".freeze

  def answer_for(key)
    key == "parsons_problem" ? PARSONS_ANSWER : "ANSWER-#{key.upcase}"
  end

  # What proves the stored answer reached a read-only render, per kind.
  def submitted_answer_markers(key)
    return [ "parsons-correct", "parsons-misplaced" ] if key == "parsons_problem"

    [ answer_for(key) ]
  end

  def exercise_for(third, fourth)
    keys = [ "code_review", "pattern", third.to_s, fourth.to_s ]
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: keys.index_with { |key| PAYLOADS.fetch(key) }
    )
  end

  def submit!(exercise)
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      submitted_at: Time.current,
      answers: exercise.active_section_keys.index_with { |key| answer_for(key) }
    )
  end

  before { login_as(user) }

  DailyPlan::THIRD_SECTION_WEIGHTS.each_key do |third|
    DailyPlan::FOURTH_SECTION_WEIGHTS.each_key do |fourth|
      context "#{third} + #{fourth}" do
        let(:exercise) { exercise_for(third, fourth) }
        let(:keys)     { exercise.active_section_keys }

        it "presents exactly the four rolled sections" do
          expect(keys).to eq([ "code_review", "pattern", third.to_s, fourth.to_s ])
        end

        describe "the dashboard answer form" do
          before { exercise and get root_path }

          it "renders each section's label, scenario, question, and body" do
            keys.each do |key|
              expect(response.body).to include(SLOT_LABELS.fetch(key))
              expect(response.body).to include(PAYLOADS.fetch(key)["question"])
              expect(response.body).to include(PAYLOADS.fetch(key)["scenario"])
              BODY_MARKERS.fetch(key).each { |marker| expect(response.body).to include(marker) }
            end
          end

          it "renders each section's answer input, rating row, hint, and duck thread" do
            keys.each do |key|
              expect(response.body).to include(%(name="response[answers][#{key}]"))
              expect(response.body).to include(%(data-rating-for="#{key}"))
              expect(response.body).to include(%(data-hint-for="#{key}"))
              expect(response.body).to include(%(data-section="#{key}"))
              expect(response.body).to include(PAYLOADS.fetch(key)["teaching_note"])
            end
          end

          it "counts the day's sections in the progress label" do
            expect(response.body).to include("0 of #{keys.size} answered")
          end
        end

        describe "the dashboard's submitted state" do
          before { submit!(exercise) and get root_path }

          it "renders each section's label, question, body, and stored answer" do
            keys.each do |key|
              expect(response.body).to include(SLOT_LABELS.fetch(key))
              expect(response.body).to include(PAYLOADS.fetch(key)["question"])
              BODY_MARKERS.fetch(key).each { |marker| expect(response.body).to include(marker) }
              submitted_answer_markers(key).each { |marker| expect(response.body).to include(marker) }
            end
          end

          it "offers no answer input, rating row, or duck thread" do
            keys.each do |key|
              expect(response.body).not_to include(%(name="response[answers][#{key}]"))
              expect(response.body).not_to include(%(data-rating-for="#{key}"))
              expect(response.body).not_to include(%(data-section="#{key}"))
            end
          end
        end

        describe "a history entry" do
          before { submit!(exercise) and get history_path }

          it "renders each section's label, question, body, and stored answer" do
            keys.each do |key|
              expect(response.body).to include(SLOT_LABELS.fetch(key))
              expect(response.body).to include(PAYLOADS.fetch(key)["question"])
              BODY_MARKERS.fetch(key).each { |marker| expect(response.body).to include(marker) }
              submitted_answer_markers(key).each { |marker| expect(response.body).to include(marker) }
            end
          end
        end

        # The ambiguity hunt's planted list is grading data. It must not reach
        # any rendered page, in any state — see AiService::ANSWER_KEY_FIELD.
        it "never renders the answer key, in any of the three renders" do
          [ -> { exercise and get root_path },
            -> { submit!(exercise) and get root_path },
            -> { get history_path } ].each do |render|
            render.call
            ANSWER_KEY_MARKERS.each { |secret| expect(response.body).not_to include(secret) }
          end
        end
      end
    end
  end
end
