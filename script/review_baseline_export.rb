# Design notes: docs/code-notes/script/review_baseline_export.md
class ReviewBaselineExport
  FORMAT = 1
  MAX_SECTIONS = 50

  Entry = Data.define(:date, :section, :rung, :stored_rating, :review_provider, :exercise, :response)

  def self.read_only
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
      yield
    end
  end

  # Unsaved records, so grading reads the export exactly as it reads a stored day.
  def self.entries(payload)
    raise ArgumentError, "Export format #{payload['format'].inspect} is not #{FORMAT}" unless payload.is_a?(Hash) && payload["format"] == FORMAT

    user = User.new(skill_level: "junior")
    payload.fetch("days").flat_map do |day|
      exercise = DailyExercise.new(user: user, date: day.fetch("date"), generated_at: Time.current, language: day.fetch("language"),
                                   problem_set: day.fetch("problem_set"), plan_notes: day.fetch("plan_notes"))
      response = DailyResponse.new(user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                                   answers: day.fetch("answers"), section_ratings: day.fetch("section_ratings"),
                                   pseudocode_rounds: day.fetch("pseudocode_rounds"))
      day.fetch("sections").map do |stored|
        Entry.new(date: exercise.date, section: stored.fetch("kind"), rung: stored.fetch("pitched_at"),
                  stored_rating: stored.fetch("rating"), review_provider: day["review_provider"], exercise: exercise, response: response)
      end
    end
  end

  def self.summary(payload)
    sections = payload.fetch("days").flat_map { |day| day.fetch("sections") }
    by_kind  = sections.group_by { |stored| stored.fetch("kind") }.sort.map { |kind, rows| "#{kind} #{rows.size}" }
    providers = payload.fetch("days").map { |day| day["review_provider"].presence || "unrecorded" }.tally.sort.map { |name, count| "#{name} #{count}" }

    "exported #{sections.size} sections from #{payload.fetch('days').size} days · #{by_kind.join(', ')} · " \
      "reviewed by: #{providers.join(', ')}"
  end

  def initialize(user_id:, limit: MAX_SECTIONS)
    @user_id = user_id
    @limit   = limit
  end

  def call
    self.class.read_only do
      { "format" => FORMAT, "rubric" => ReviewedSectionResults::RUBRIC_VERSION, "exported_at" => Time.current.iso8601,
        "days" => days }
    end
  end

  private

  def days
    taken = 0
    responses.each_with_object([]) do |response, days|
      break days if taken >= @limit

      sections = gradable_sections(response).first(@limit - taken)
      next if sections.empty?

      days << day(response, sections)
      taken += sections.size
    end
  end

  def responses
    DailyResponse.where(user_id: @user_id).where.not(submitted_at: nil).where.not(ai_review: nil)
                 .includes(:daily_exercise).order(date: :desc)
  end

  # The evidence rule's own filter, minus any kind whose rating Ruby fixes rather than the grader.
  def gradable_sections(response)
    ReviewedSectionResults.for(response, require_rubric: true, include_eased: true).map(&:kind).reject do |section|
      ExerciseSection.for(section).fixed_rating(section: response.daily_exercise.problem_set[section], answer: response.answer_for(section))
    end
  end

  def day(response, sections)
    exercise = response.daily_exercise
    { "date" => response.date.iso8601, "language" => exercise.language, "review_provider" => response.review_provider,
      "problem_set" => exercise.problem_set, "plan_notes" => exercise.plan_notes, "answers" => response.answers,
      "section_ratings" => response.section_ratings, "pseudocode_rounds" => response.pseudocode_rounds,
      "sections" => sections.map { |section| stored_section(response, section) } }
  end

  def stored_section(response, section)
    review = response.ai_review[section]
    graded = review.merge(review.fetch(ReviewProseVerdict::ORIGINAL_KEY, {}))
    { "kind" => section, "pitched_at" => response.daily_exercise.problem_set.dig(section, "pitched_at"),
      "answer" => response.answer_for(section), "rating" => review["rating"],
      "missed" => graded["missed"], "essential_gaps" => graded["essential_gaps"] }
  end
end
