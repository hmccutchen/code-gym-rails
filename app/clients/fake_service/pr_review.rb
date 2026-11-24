module FakeService::PrReview
  CALLER_PATH = "app/services/booking_status.rb".freeze
  CALLER_LINES = {
    "acceptable" => "BookingAvailability.available?(slots) ? :available : :unavailable",
    "flawed" => "BookingAvailability.available?(slots) ? :unavailable : :available"
  }.freeze
  EXPECTED = ":unavailable".freeze

  GRADE = {
    "rating" => "solid",
    "ungradable" => false,
    "comprehension" => "You connected the availability check to the caller's return value.",
    "evidence" => "You discussed the condition in the requirement and the corresponding branch.",
    "disposition" => "You supported your disposition with the caller's behavior.",
    "assessment" => "sound"
  }.freeze

  def self.grade(prompt)
    key_json = prompt.rpartition("Private cross-check for this submitted section only:\n").last
    GRADE.merge("artifact_case" => JSON.parse(key_json).fetch("case"))
  end

  def self.judgment(prompt)
    line = CALLER_LINES.values.find { |candidate| prompt.match?(/^ *\d+ \| *#{Regexp.escape(candidate)}$/) }
    raise "FakeService could not find its PR Review caller in the blind judge prompt" unless line

    assessment(line).merge("status" => "keep")
  end

  def self.assessment(line)
    observed = line.split.last
    {
      "case" => observed == EXPECTED ? "acceptable" : "flawed",
      "reason" => "With no slots, the availability check is false and the caller returns #{observed}.",
      "behavior" => { "requirement" => 1, "expected" => EXPECTED, "observed" => observed },
      "evidence" => [ { "path" => CALLER_PATH, "quote" => line } ]
    }
  end

  def self.section(target)
    line = CALLER_LINES.fetch(target)
    {
      "question" => "Trace the outcome across both files and support your review disposition.",
      "scenario" => "The booking caller now returns a status based on the availability check.",
      "requirements" => [ "When there are no open slots, the caller must return :unavailable." ],
      "concept" => "service_objects",
      "file_1_path" => "app/services/booking_availability.rb",
      "file_1_code" => <<~RUBY.strip,
        class BookingAvailability
          def self.available?(slots)
            slots.any?
          end
        end
      RUBY
      "file_1_changed" => [],
      "file_2_path" => CALLER_PATH,
      "file_2_code" => <<~RUBY.strip,
        class BookingStatus
          def self.call(slots)
            #{line}
          end
        end
      RUBY
      "file_2_changed" => [ line ],
      "answer_key" => assessment(line)
    }
  end

  private_class_method :assessment
end
