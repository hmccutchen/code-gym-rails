class SectionContext
  def self.render(data)
    data ||= {}

    [
      ("Title: #{data["title"]}" if data["title"].present?),
      ("Scenario: #{data["scenario"]}" if data["scenario"].present?),
      ("Why it exists: #{data["why"]}" if data["why"].present?),
      ("Question: #{data["question"]}" if data["question"].present?),
      ("Options: #{Array(data["options"]).join(" / ")}" if data["options"].present?),
      ("Code snippet:\n#{data["snippet"]}" if data["snippet"].present?),
      ExerciseSection::CodeReview.files_context(data),
      ("Current schema, as the table stands today:\n#{data["current_schema"]}" if data["current_schema"].present?),
      ("Starter code:\n#{data["starter_code"]}" if data["starter_code"].present?),
      ("Plan excerpt:\n#{data["plan_excerpt"]}" if data["plan_excerpt"].present?),
      ("The problem to plan:\n#{data["problem_statement"]}" if data["problem_statement"].present?),
      ("Feature request:\n#{data["request"]}" if data["request"].present?),
      ("Piece A:\n#{data["piece_a"]}" if data["piece_a"].present?),
      ("Piece B:\n#{data["piece_b"]}" if data["piece_b"].present?),
      parsons_blocks(data)
    ].compact.join("\n")
  end

  def self.parsons_blocks(data)
    blocks = data["blocks"]
    return unless blocks.is_a?(Array) && blocks.any?

    order = scrambled_display_order(data["display_order"], blocks.size)
    return "Blocks (order withheld):\n#{blocks.map(&:to_s).sort.map { |b| "- #{b}" }.join("\n")}" unless order

    lines = order.map.with_index { |block_index, position| "#{position + 1}. #{blocks[block_index]}" }
    "Blocks, in the learner's current on-screen order (NOT the correct order):\n#{lines.join("\n")}"
  end

  def self.scrambled_display_order(display_order, block_count)
    order = ExerciseSection::ParsonsProblem.normalize_order(Array(display_order), block_count)
    return if order.empty? || order == (0...block_count).to_a

    order
  end

  private_class_method :parsons_blocks, :scrambled_display_order
end
