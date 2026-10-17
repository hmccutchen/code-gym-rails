require "rails_helper"

RSpec.describe "Daily kinds come from the pair, never a global slot list" do
  let(:retired_calls) do
    {
      "ExerciseSection.slots" => /ExerciseSection\.slots\b/,
      "ExerciseSection.fixed" => /ExerciseSection\.fixed\b(?![?_])/,
      ".fixed?" => /\.fixed\?/
    }
  end

  def sources
    Dir[Rails.root.join("{app,lib,script,spec}/**/*.{rb,erb}")].sort - [ __FILE__ ]
  end

  it "reads the day's kinds through ExerciseSection.layout and DailyKinds" do
    offenders = sources.flat_map do |path|
      File.readlines(path).each_with_index.flat_map do |line, index|
        retired_calls.select { |_name, pattern| line.match?(pattern) }
          .map { |name, _pattern| "#{Pathname(path).relative_path_from(Rails.root)}:#{index + 1} (#{name})" }
      end
    end

    expect(offenders).to be_empty, "retired layout call: #{offenders.join(', ')}"
  end
end
