# Only transport is faked; #call dispatches on the literal system: string, and reviews read the section from prompt:.
class FakeService < AiService
  def self.provider_key = "fake"
  def self.available? = Rails.env.local?

  def self.judges_review_prose? = true

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
      "scenario" => "a nightly loyalty-tier recalculation job",
      "diagram" => "flowchart TD\n  A[\"Nightly job\"] --> B[\"loyalty_tier\"]\n  B --> C[(\"orders\")]"
    },
    "design_comparison" => {
      "title" => "Where shipping rates come from",
      "scenario" => "A checkout service quotes shipping for each order. The team adds a new carrier about once a month, and each carrier has its own rate rule.",
      "question" => "Which piece fits this system better, and which stated fact decides it?",
      "better_piece" => <<~RUBY.strip,
        class ShippingQuote
          RATES = {
            "ups"   => UpsRate,
            "fedex" => FedexRate
          }.freeze

          def initialize(carrier)
            @rate = RATES.fetch(carrier).new
          end

          def cost_cents(order)
            @rate.cost_cents(order)
          end
        end
      RUBY
      "other_piece" => <<~RUBY.strip,
        class ShippingQuote
          def initialize(carrier)
            @carrier = carrier
          end

          def cost_cents(order)
            case @carrier
            when "ups"   then UpsRate.new.cost_cents(order)
            when "fedex" then FedexRate.new.cost_cents(order)
            else raise KeyError, @carrier
            end
          end
        end
      RUBY
      "answer_key" => {
        "deciding_fact" => "A new carrier is added about once a month.",
        "principle" => "Open for extension, closed for modification: a new carrier should be a new class, not an edit to existing code.",
        "why_other_fails" => "Every new carrier means editing the case statement in cost_cents, so each monthly change touches code that already works."
      },
      "concept" => "open_closed"
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
    },
    "plan_review" => {
      "title" => "Add response caching to the profile endpoint",
      "scenario" => "a profile page that's slow under load",
      "plan_excerpt" => <<~PLAN.strip,
        1. Cache the profile response in Rails.cache for exactly 300 seconds — a magic number chosen because it felt about right.
        2. While we're in here, also add an admin-only endpoint to manually clear any user's cache, since that might be handy someday.
        3. Skip cache invalidation on profile update — the 300-second expiry will eventually catch it, so stale data for up to 5 minutes after a save is fine.
      PLAN
      "question" => "What's wrong with this plan, and what would you push back on before approving it?",
      "teaching_note" => "Look at where a number appears with no stated reason, where the scope grew past the original ask, and where a user-visible behavior quietly changed.",
      "concept" => "unjustified_constant",
      "answer_scaffold" => [
        "What's wrong:",
        "What you'd push back on before approving:"
      ]
    },
    "ambiguity_hunt" => {
      "title" => "Add a leaderboard to the dashboard",
      "scenario" => "a request dropped into the team's backlog with no further detail",
      "request" => "Can we add a leaderboard showing our top performers? Should be easy to slot into the dashboard.",
      "planted_ambiguities" => [
        "Which metric ranks performers (streak length? sections answered? review ratings?) is never stated",
        "Whether the leaderboard is team-wide or scoped to some subset of users is never stated",
        "How ties are broken is never addressed",
        "Whether a user can opt out of appearing on the leaderboard is never addressed"
      ],
      "question" => "What would you need clarified before writing a spec for this?",
      "teaching_note" => "Read the request as if you had to start writing code from it right now — where would you have to just guess?",
      "concept" => "missing_success_criteria"
    },
    "pseudocode_to_code" => {
      "title" => "Merge overlapping ranges",
      "scenario" => "collapsing overlapping maintenance windows before they go on a status page",
      "problem_statement" => "Given a list of [start, end] ranges in no particular order, return the smallest list of ranges covering exactly the same span, merging any that overlap or touch. The list may be empty.",
      "question" => "Write pseudocode for this, then translate it.",
      "teaching_note" => "Think about what has to be true about the order of the ranges before any merging step can work.",
      "concept" => "unhandled_empty_input"
    }
  }.freeze

  REVIEW_SECTION = {
    "rating" => "solid",
    "correct" => [ "Correctly identified the core issue." ],
    "missed" => [ "Didn't mention the specific fix." ],
    "better_questions" => [ "What would happen under concurrent access?" ],
    "next_step" => "Review the referenced concept material once more.",
    "improved_code" => "",
    "essential_gaps" => []
  }.freeze

  DIFFICULTY_REASON = "Rated from the problem text alone, with no sight of anyone's answer."

  CONCEPT_REFERENCE = {
    "tagline" => "One clear rule, not a grab-bag of tips.",
    "explanation" => "This concept has one core idea worth internalizing, with a couple of situations where it matters most.",
    "code_example" => <<~RUBY.strip,
      # A short, annotated example demonstrating the concept.
      def example
        true
      end
    RUBY
    "senior_lens" => "A senior engineer reaches for this automatically, without having to reason it out each time.",
    "guide_plain_language" =>
      "Stated without the jargon: there is one thing this concept asks you to notice, and once you have noticed it the " \
      "rest follows. Everything else written about it is commentary on that one thing.",
    "guide_worked_example" => <<~EXAMPLE.strip,
      orders.each { |order| render_total(order.customer.name) }

      orders.includes(:customer).each { |order| render_total(order.customer.name) }

      The slow page is what happens when the association is never loaded:
      touching it per row is what issues a query per row. Load it up front and
      the extra queries stop, because they were only ever that omission.
    EXAMPLE
    "guide_pitfalls" =>
      "The appealing wrong idea is that this only matters at scale, so it can wait. It matters as soon as the code is " \
      "read by someone who did not write it, which is usually sooner.",
    "ladder_junior" => "One obvious instance in a short method, where the fix is a single change.",
    "ladder_senior" => "The instance hides behind a helper or a callback, so finding it means tracing a call path.",
    "ladder_principal_engineer" => "The fix has a real cost elsewhere, and the answer weighs that cost against leaving it.",
    "lesson" => {
      "definition" => "One rule that decides how the code behaves.",
      "comparison" => "Like a recipe step you skip once and pay for in every dish after.",
      "comparison_limit" => "A recipe fails where you can taste it; code can fail where nobody looks.",
      "misunderstanding" => "People think it only matters later. It matters as soon as someone else reads the code.",
      "situations" => [ "A page that slows down as data grows.", "A loop that touches a related record." ],
      "habits" => [ { "habit" => "Count what the code does per row.", "catch" => "A count can look fine on small test data." } ],
      "carry_question" => "What does this do once per row?",
      "quick_test" => "Run it with ten rows, then a thousand, and compare."
    }
  }.freeze

  RECOGNITION_GUIDE = {
    "questions" => "Ask what the code is trying to guarantee, then whether anything on the page actually enforces it.",
    "contrast" => "Two methods of the same shape: in one a check stands between the input and the write, and in the other " \
                  "nothing does. The question that told them apart was where the guarantee is enforced.",
    "misfires" => "This way of looking flags guarantees that a caller already enforces, and it misses ones enforced nowhere at all."
  }.freeze

  # Differs from EXPLAIN_DIFFERENTLY_TEXT so a spec that confuses the two surfaces fails.
  CONCEPT_ALTERNATE_TEXT =
    "Picture a library where every book you request is fetched by a separate courier trip. One trip for one book is " \
    "fine; a hundred trips for a hundred books is the whole afternoon gone. The fix is always the same shape — ask " \
    "for everything you know you need in one trip."

  EXPLAIN_DIFFERENTLY_TEXT =
    "Think of it like a relay race — each service object is one runner, and its only job is to hand off cleanly " \
    "to the next one. If a single method complains about doing too much, that's the same as one runner trying to " \
    "run the whole race alone."

  FOLLOW_UP_ANSWER_TEXT =
    "Focus on the boundary of the operation: what MUST happen before returning success, and what could safely " \
    "happen after. That's what separates a synchronous responsibility from something a background job can own."

  PSEUDOCODE_CRITIQUE = {
    "gaps_found" => true,
    "gaps" => [ "Your plan never says what happens when the input list is empty — the first step reads a first element that will not be there." ]
  }.freeze

  # Keeps the canned plan's missing empty-list check; adding a guard would let the faithfulness specs test nothing.
  PSEUDOCODE_TRANSLATION = <<~RUBY.strip
    def merge_ranges(ranges)
      sorted = ranges.sort_by(&:first)
      merged = [ sorted.first ]
      sorted.drop(1).each do |range|
        last = merged.last
        if range.first <= last.last
          merged[-1] = [ last.first, [ last.last, range.last ].max ]
        else
          merged << range
        end
      end
      merged
    end
  RUBY

  DUCK_RESPONSE_TEXT =
    "What would happen to that method if it ran a hundred times in one request — where would the slowdown show up?"

  private

  # Raises bare RuntimeErrors because the job turns AiService::Error into a user-facing message that hides the bug.
  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil, response_schema: nil, single_attempt: false)
    text =
      case system
      when /editing the prose of one section's code review/
        { "status" => "keep" }.to_json
      when /generating personalized daily exercise sets/
        EXERCISE_PROBLEM_SET.to_json
      when /giving direct, specific feedback/
        section = prompt[/Grade ONLY the "(\w+)" section/, 1]
        raise "FakeService could not extract the section key from the review prompt" if section.blank?

        REVIEW_SECTION.to_json
      when /rating how hard/
        difficulty_assessment(prompt).to_json
      when /writing a concise, durable reference/
        CONCEPT_REFERENCE.to_json
      when /how to recognize one category of problem/
        RECOGNITION_GUIDE.to_json
      when /re-teaching one concept/
        CONCEPT_ALTERNATE_TEXT
      when /re-explaining one point/
        EXPLAIN_DIFFERENTLY_TEXT
      when /answering a follow-up question/
        FOLLOW_UP_ANSWER_TEXT
      when /Socratic thinking partner/
        DUCK_RESPONSE_TEXT
      when /reviewing an engineer's PSEUDOCODE plan/
        PSEUDOCODE_CRITIQUE.to_json
      when /TRANSCRIBER, not a reviewer/
        PSEUDOCODE_TRANSLATION
      when /checking one section of a generated coding exercise/
        judge_verdict(prompt).to_json
      else
        raise "FakeService received an unrecognized system prompt: #{system.inspect}"
      end

    { text: text, input_tokens: 0, output_tokens: 0, model: "fake", cache_read_tokens: 0, cache_write_tokens: 0 }
  end

  def judge_verdict(prompt)
    kind = ExerciseSection.find(prompt[/^Section kind: (\w+)$/, 1])
    solve = kind&.judge_solve_options&.last
    { "status" => "keep", "better" => solve }.compact
  end

  def difficulty_assessment(prompt)
    # Intersected with the registry so a snippet's own "## Heading" line can't shift the levels.
    sections = prompt.scan(/^## (\w+)$/).flatten & ExerciseSection.keys
    raise "FakeService could not extract any section key from the difficulty prompt" if sections.empty?

    levels = DailyResponse::DIFFICULTY_LEVELS
    sections.each_with_index.to_h do |section, index|
      [ section, { "level" => levels[index % levels.size], "reason" => DIFFICULTY_REASON } ]
    end
  end

  def build_connection
    nil
  end
end
