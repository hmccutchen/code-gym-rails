# Deterministic, zero-cost AiService provider for tests. Overrides only the
# two hooks every real provider implements (#call, #build_connection) —
# every other AiService method (DailyPlan, log_usage, normalize_concepts,
# log_retention, shuffle_parsons_blocks!, override_parsons_section_rating!)
# runs unmodified against this fake's output, so tests exercise the same
# control flow a real provider triggers. #call dispatches on the literal
# `system:` string each AiService caller passes; the review path further
# reads which section to grade out of `prompt:`, since #review_sections
# sends the same shared system context to every section's call.
class FakeService < AiService
  # All six ExerciseSection kinds populated at once. DailyExercise#third_key
  # resolves by precedence over whichever keys are present hashes
  # (ExerciseSection.thirds: architecture, security_review, challenge,
  # parsons_problem) — architecture wins here every time, regardless of
  # which third DailyPlan actually asked for, since normalize_concepts and
  # shuffle_parsons_blocks! only ever touch keys that exist.
  EXERCISE_PROBLEM_SET = {
    "code_review" => {
      "question" => "This method recalculates a customer's loyalty tier every time it's called, even inside a loop over the whole customer list. What's the issue and how would you fix it?",
      "snippet" => <<~RUBY.strip,
        def loyalty_tier(customer)
          total = customer.orders.sum(&:total_cents)
          case total
          when 0...10_000 then "bronze"
          when 10_000...50_000 then "silver"
          else "gold"
          end
        end

        customers.each { |c| puts loyalty_tier(c) }
      RUBY
      "teaching_note" => "Look at what happens to the database each time this method runs inside the loop.",
      "concept" => "n_plus_one",
      "scenario" => "a nightly loyalty-tier recalculation job"
    },
    "pattern" => {
      "title" => "Service Object",
      "why" => "Keeps a multi-step business operation out of the model and controller so it can be tested and reused on its own.",
      "question" => "When would you reach for a service object instead of adding another method to the model?",
      "scenario" => "checkout logic that charges a card, updates inventory, and sends a receipt email",
      "teaching_note" => "Count how many unrelated responsibilities the operation currently touches.",
      "concept" => "service_objects",
      "answer_scaffold" => [
        "Where this logic lives today:",
        "How you would call the service object:",
        "What you would test first:"
      ]
    },
    "challenge" => {
      "title" => "Cache the expensive lookup",
      "question" => "Implement a method that returns a customer's lifetime order count without recalculating it on every call within the same request.",
      "scenario" => "a customer profile page that renders the order count in three different places",
      "starter_code" => "",
      "teaching_note" => "Think about what should persist across calls within one request but not across requests.",
      "concept" => "memoization"
    },
    "architecture" => {
      "title" => "Synchronous or async receipt emails",
      "scenario" => "Checkout currently emails a receipt synchronously. Traffic has grown enough that email delivery now visibly slows down the checkout response.",
      "question" => "Would you move receipt delivery to a background job, and how would you justify that tradeoff?",
      "options" => [ "Keep it synchronous but add a timeout", "Move it to a background job via Solid Queue" ],
      "teaching_note" => "Weigh checkout latency against the complexity of a job retry/failure path.",
      "concept" => "service_boundaries",
      "answer_scaffold" => [
        "Which option, and why:",
        "What you would need to handle if delivery fails:"
      ],
      "reference" => {
        "tagline" => "Move slow, non-critical work off the request path.",
        "explanation" => "A background job absorbs email latency without blocking checkout, at the cost of needing to handle delivery failures asynchronously.",
        "tradeoffs" => [
          "Faster checkout response",
          "Harder to guarantee the receipt was sent before the page renders"
        ],
        "senior_lens" => "A senior engineer asks whether the user needs to see confirmation before the response returns, not just whether the code is slow.",
        "diagram" => ""
      }
    },
    "security_review" => {
      "title" => "Mass assignment on profile update",
      "question" => "What security vulnerability exists here, and how would you mitigate it?",
      "snippet" => <<~RUBY.strip,
        def update
          current_user.update(params[:user])
          redirect_to profile_path
        end
      RUBY
      "scenario" => "a self-service profile update endpoint",
      "teaching_note" => "Consider what happens if the submitted params hash includes a key nobody intended to expose.",
      "concept" => "mass_assignment_protection",
      "reference" => {
        "tagline" => "Never pass raw params straight into update.",
        "explanation" => "Without strong params, an attacker can submit unexpected attributes (like admin flags) alongside the form fields.",
        "code_example" => <<~RUBY.strip,
          def update
            current_user.update(user_params)
            redirect_to profile_path
          end

          private

          def user_params
            params.require(:user).permit(:name, :email)
          end
        RUBY
        "senior_lens" => "Permit an explicit allowlist, never an inferred one."
      }
    },
    "parsons_problem" => {
      "title" => "Build a safe divide",
      "scenario" => "a pricing calculator that divides a total by a quantity",
      "question" => "Arrange these blocks into the correct working solution",
      "blocks" => [
        "def safe_divide(total, quantity)",
        "  return 0 if quantity.zero?",
        "  total / quantity.to_f",
        "end"
      ],
      "teaching_note" => "Think about what should happen before any division is attempted.",
      "concept" => "idempotency"
    }
  }.freeze

  REVIEW_SECTION = {
    "rating" => "solid",
    "correct" => [ "Correctly identified the core issue." ],
    "missed" => [ "Didn't mention the specific fix." ],
    "better_questions" => [ "What would happen under concurrent access?" ],
    "next_step" => "Review the referenced concept material once more.",
    "improved_code" => ""
  }.freeze

  CONCEPT_REFERENCE = {
    "tagline" => "One clear rule, not a grab-bag of tips.",
    "explanation" => "This concept has one core idea worth internalizing, with a couple of situations where it matters most.",
    "code_example" => <<~RUBY.strip,
      # A short, annotated example demonstrating the concept.
      def example
        true
      end
    RUBY
    "senior_lens" => "A senior engineer reaches for this automatically, without having to reason it out each time."
  }.freeze

  EXPLAIN_DIFFERENTLY_TEXT =
    "Think of it like a relay race — each service object is one runner, and its only job is to hand off cleanly " \
    "to the next one. If a single method complains about doing too much, that's the same as one runner trying to " \
    "run the whole race alone."

  FOLLOW_UP_ANSWER_TEXT =
    "Focus on the boundary of the operation: what MUST happen before returning success, and what could safely " \
    "happen after. That's what separates a synchronous responsibility from something a background job can own."

  DUCK_RESPONSE_TEXT =
    "What would happen to that method if it ran a hundred times in one request — where would the slowdown show up?"

  private

  # Both raises are deliberately bare RuntimeErrors, not AiService::Error:
  # GenerateDailyExercisesJob rescues the AiService hierarchy and turns it into
  # a persisted, user-facing failure message, which would bury a broken fake as
  # "generation failed" instead of failing the spec that caused it.
  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil)
    text =
      case system
      when /generating personalized daily exercise sets/
        EXERCISE_PROBLEM_SET.to_json
      when /giving direct, specific feedback/
        section = prompt[/Grade ONLY the "(\w+)" section/, 1]
        raise "FakeService could not extract the section key from the review prompt" if section.blank?

        REVIEW_SECTION.to_json
      when /writing a concise, durable reference/
        CONCEPT_REFERENCE.to_json
      when /re-explaining one point/
        EXPLAIN_DIFFERENTLY_TEXT
      when /answering a follow-up question/
        FOLLOW_UP_ANSWER_TEXT
      when /Socratic thinking partner/
        DUCK_RESPONSE_TEXT
      else
        raise "FakeService received an unrecognized system prompt: #{system.inspect}"
      end

    { text: text, input_tokens: 0, output_tokens: 0 }
  end

  def build_connection
    nil
  end
end
