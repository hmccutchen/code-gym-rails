# Demo content for a Railway PR app, whose database starts empty.
#
# railway.toml's preDeployCommand is shared with production, so this runs there
# too. Three rules make that safe: no variable means no action; rows are created
# only when absent and never updated or deleted; and nothing outside the single
# named account is touched.
#
# preDeployCommand fires on every deploy, so a preview app open across a date
# boundary accumulates rows as the seeded dates roll forward — harmless in a
# throwaway environment, and the price of never touching a row we already own.
# Writes use the bang finders so a malformed fixture aborts the deploy loudly
# rather than seeding nothing while reporting success.
class PreviewSeed
  EMAIL_VAR     = "PREVIEW_SEED_EMAIL"
  DUMMY_API_KEY = "sk-ant-preview-not-a-real-key"

  def self.run! = new.run!

  def run!
    return nil if target_email.blank?

    user = find_or_create_user
    Time.use_zone(user.effective_time_zone) { seed_days(user) }
    seed_concept_reference
    user
  end

  private

  def target_email
    @target_email ||= ENV[EMAIL_VAR].to_s.strip.downcase
  end

  # create_with applies the demo defaults on the create path only. An existing
  # account — a real user, or a previously-seeded one — is returned untouched,
  # so seeding never modifies a row it did not create, including a real user who
  # signed up but has not added an API key yet (api_key / provider still nil).
  def find_or_create_user
    User.create_with(
      name:        "Preview Reviewer",
      skill_level: "solid",
      language:    "ruby_rails",
      provider:    "anthropic",
      api_key:     DUMMY_API_KEY
    ).find_or_create_by!(email: target_email)
  end

  # find_or_create_by!'s block runs only on create, which is what keeps rule 2
  # ("never overwrite") true for every row below.
  def seed_days(user)
    seed_day(user, Date.current, architecture_set) do |response|
      response.answers = { "code_review" => "Looks like an N+1 — each iteration hits the database again." }
    end

    seed_day(user, Date.current - 1, challenge_set) do |response|
      response.answers        = submitted_answers
      response.submitted_at   = Time.current
      response.section_ratings = { "code_review" => "right_level", "pattern" => "right_level", "challenge" => "right_level" }
      response.ai_review      = sample_review
    end

    seed_day(user, Date.current - 3, challenge_set) do |response|
      response.answers        = submitted_answers
      response.submitted_at   = Time.current
      response.section_ratings = { "code_review" => "too_hard", "pattern" => "too_hard", "challenge" => "too_hard" }
    end
  end

  def seed_day(user, date, problem_set)
    exercise = DailyExercise.find_or_create_by!(user: user, date: date) do |e|
      e.problem_set  = problem_set
      e.language     = "ruby_rails"
      e.generated_at = Time.current
    end

    # Only attach a demo response to an exercise this seeder created. If a real
    # user already has an exercise on this date (the misconfiguration case), never
    # fabricate a response against their real problem set.
    return unless exercise.previously_new_record?

    DailyResponse.find_or_create_by!(user: user, daily_exercise: exercise, date: date) do |response|
      response.concept_tags = problem_set.transform_values { |section| section["concept"] }.compact
      yield response
    end
  end

  def seed_concept_reference
    ConceptReference.find_or_create_by!(concept: "n_plus_one", language: "ruby_rails") do |reference|
      reference.tagline      = "Load the association once, not once per row."
      reference.explanation  = "A query inside a loop issues one statement per record. Eager loading fetches them in a single additional query."
      reference.code_example = "orders = Order.includes(:customer)\norders.each { |order| puts order.customer.name }"
      reference.senior_lens  = "Ask what the query count is as a function of rows, not whether the code reads cleanly."
    end
  end

  def submitted_answers
    {
      "code_review" => "The loop calls order.customer inside each iteration, so it issues one query per order. Use Order.includes(:customer).",
      "pattern"     => "When an operation spans several models or has side effects beyond one record, a service object keeps the orchestration out of both the controller and the model.",
      "challenge"   => "def total_for(orders)\n  orders.sum(&:amount)\nend"
    }
  end

  def architecture_set
    {
      "code_review" => {
        "scenario"      => "Order history page for a storefront",
        "question"      => "This action loads every order and its customer. What is wrong, and how would you fix it?",
        "snippet"       => "def index\n  @orders = Order.all\n  @orders.each do |order|\n    puts order.customer.name\n  end\nend",
        "concept"       => "n_plus_one",
        "teaching_note" => "Count the queries issued per iteration."
      },
      "pattern" => {
        "title"         => "Service Objects",
        "why"           => "Controllers stop becoming dumping grounds for business logic.",
        "question"      => "When would you reach for a service object over a model method?",
        "concept"       => "service_objects",
        "teaching_note" => "Think about who owns the orchestration.",
        "reference"     => {
          "tagline"      => "One public call, one job.",
          "explanation"  => "A service object wraps a single business operation behind #call.",
          "code_example" => "class PlaceOrder\n  def call(cart)\n    # ...\n  end\nend",
          "senior_lens"  => "Ask what the unit of reuse actually is."
        }
      },
      "architecture" => {
        "title"         => "Dashboard read path",
        "scenario"      => "Your analytics dashboard runs a four-way join over 200K rows and takes 2.5 seconds to load. Product needs it under 300ms, and the numbers can be up to a minute stale.",
        "question"      => "Which approach would you take, and why?",
        "options"       => [ "Materialized view refreshed every minute", "Read replica running the same query", "Application-level cache keyed on the filter set" ],
        "concept"       => "caching_strategy",
        "teaching_note" => "Staleness tolerance is the lever here.",
        "reference"     => {
          "tagline"      => "Cache what is expensive and tolerant of staleness.",
          "explanation"  => "A minute of allowed staleness buys you a precomputed read path.",
          "tradeoffs"    => [ "Materialized views add refresh cost", "Replicas do not reduce query cost", "Caches need an invalidation rule" ],
          "senior_lens"  => "Name the freshness budget before choosing the mechanism."
        }
      }
    }
  end

  def challenge_set
    {
      "code_review" => {
        "scenario"      => "Nightly invoice roll-up",
        "question"      => "This method reloads the same record on every pass. What would you change?",
        "snippet"       => "def total_for(ids)\n  ids.sum { |id| Invoice.find(id).amount }\nend",
        "concept"       => "n_plus_one",
        "teaching_note" => "How many round trips does this make for 500 ids?"
      },
      "pattern" => {
        "title"         => "Memoization",
        "why"           => "Repeated work inside one request is wasted work.",
        "question"      => "Where does memoization stop being safe?",
        "concept"       => "memoization",
        "teaching_note" => "Consider what happens when the underlying data changes mid-request.",
        "reference"     => {
          "tagline"      => "Compute once per instance, not once per call.",
          "explanation"  => "||= caches the result on the instance, so the second call is free.",
          "code_example" => "def total\n  @total ||= line_items.sum(&:amount)\nend",
          "senior_lens"  => "Ask what the lifetime of the cached value should be."
        }
      },
      "challenge" => {
        "title"         => "Sum an order's line items",
        "scenario"      => "Billing service",
        "question"      => "Implement a method returning the total amount for a collection of orders.",
        "starter_code"  => "def total_for(orders)\n  # your implementation\nend",
        "concept"       => "service_objects",
        "teaching_note" => "Start from the smallest thing that passes."
      }
    }
  end

  def sample_review
    {
      "code_review" => {
        "rating" => "solid", "correct" => "You named the N+1 and the fix in one breath.",
        "missed" => "Worth saying what includes does to the query count.",
        "better_questions" => "Where else does this loop pattern appear?",
        "next_step" => "Read the Rails guide on eager loading.",
        "improved_code" => "@orders = Order.includes(:customer)"
      },
      "pattern" => {
        "rating" => "strong", "correct" => "Good instinct on who owns the orchestration.",
        "missed" => "", "better_questions" => "", "next_step" => "", "improved_code" => ""
      },
      "challenge" => {
        "rating" => "developing", "correct" => "The happy path is right.",
        "missed" => "An empty collection is not handled.",
        "better_questions" => "What should this return for no orders?",
        "next_step" => "Add a guard clause and a test for the empty case.",
        "improved_code" => ""
      }
    }
  end
end
