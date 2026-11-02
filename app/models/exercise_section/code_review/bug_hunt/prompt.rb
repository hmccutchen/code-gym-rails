# Design notes: docs/code-notes/app/models/exercise_section/code_review/bug_hunt/prompt.md
module ExerciseSection::CodeReview::BugHunt::Prompt
  HIDDEN_KEY_LINE = PlantedKey.hidden_key_line(fields: %w[question purpose teaching_note], before: "reads the snippet",
                                                quoted: "the code").freeze

  CORE_LANGUAGE = {
    "ruby_rails" => "- Write core Ruby only: no Rails, no gems, no `require`, and nothing that reads files, the network, the clock, " \
                    "the time zone or random numbers.",
    "javascript" => "- Write core JavaScript as an ES module: strict mode, no `require` or `module.exports` (`export` is allowed), " \
                    "no TypeScript, no frameworks, no DOM or Node APIs, and nothing that reads files, the network, the clock or " \
                    "random numbers. Async code uses promises only, never timers."
  }.freeze

  RUNG_LINES = {
    "junior"    => "- Pitch it so the input the purpose suggests first already gives a visibly wrong result.",
    "mid_level" => "- Pitch it so the input the purpose suggests first gives the right result by accident, and another input it covers fails.",
    "senior"    => "- Pitch it so the failure shows only on an edge the purpose covers, such as empty, repeated or boundary values, " \
                   "or so the obvious fix carries a second trap of its own."
  }.freeze

  RUNG_FOR = { "principal_engineer" => "senior" }.freeze

  LOOKS_RIGHT_RUNGS = %w[mid_level senior].freeze

  WITNESS_LINE = "- In the answer_key, \"witness\" is code: \"call\" is one expression that calls the snippet's code on an input the " \
                 "purpose covers, \"expected\" is a literal of what the purpose calls for, and \"returns\" is a literal of what the " \
                 "code gives instead, or \"raises <ErrorClass>\". For an async trap, the call returns a snapshot of the state at the " \
                 "moment the call returns, never a live reference: the function returns a primitive or a fresh copy " \
                 "(`return [...log]`), or the call is synchronous and the witness copies its result (`[...run(items)]`). A copy " \
                 "made in a `.then` doesn't count, since it is made after pending callbacks may have run. \"fixed_snippet\" is the " \
                 "whole snippet with the fix applied, which the same call works on."

  LOOKS_RIGHT_LINE = "- \"looks_right_on\" is a call on another input the purpose covers where the snippet gives the right result " \
                     "by accident, with the \"expected\" literal it gives."

  JUDGE_TASK = "Find the one planted language trap: an input the purpose covers that the code gets wrong, and the fix."

  JUDGE_GUIDANCE = <<~GUIDANCE.squish
    This section is a bug hunt: a short puzzle with one trap planted in the core language, a one-line "purpose" saying what
    the code is meant to do, and no program output. Solve it before judging: find an input the purpose covers that the code
    gets wrong. Reject it as reasoning_failure when the code is correct as written for every input the purpose covers, when it
    holds a second planted trap, when the snippet, purpose, question or teaching_note shows program output, or when the purpose
    names or hints at the trap. Reject it as unstated_prerequisite when it uses Rails, TypeScript, a framework or anything else
    outside the core language, and as underdetermined when the code calls something it doesn't define apart from the
    language's built-ins. A bug hunt pitches principal_engineer exactly as senior, one trap that shows only on an edge the
    purpose covers, so judge it against that and never against a decision at system scale. The purpose and the snippet are
    the artifact: never change them.
  GUIDANCE

  def self.rung_line(rung) = RUNG_LINES.fetch(RUNG_FOR.fetch(rung, rung), RUNG_LINES.fetch("junior"))

  def self.guidance(gotcha:, rung:, vocabulary:)
    raise ArgumentError, "a bug_hunt day needs its picked gotcha" if gotcha.nil?

    [
      "- The code_review section is a bug hunt today: a short puzzle with one planted language trap, not realistic application code.",
      "- Plant exactly this trap: #{gotcha.rule}",
      CORE_LANGUAGE.fetch(gotcha.language),
      "- \"purpose\" is one sentence saying what the code is meant to do, precise enough to decide which inputs it covers. " \
        "It never names or hints at the trap.",
      "- \"snippet\" is 5 to #{ExerciseSection::CodeReview::BugHunt::MAX_LINES} lines that define everything they call apart " \
        "from the language's built-ins. Keep each line under 45 characters where you can and never past 60, since it is read on a phone.",
      "- Show no program output anywhere: no result comments such as `# => 3`, no `puts` or `console.log` of a result, and no " \
        "output in the question, the purpose or the teaching_note.",
      rung_line(rung),
      "- For this section, the #{ExerciseSection::CodeReview::BugHunt::MAX_LINES}-line limit and the purpose come before what " \
        "the difficulty guidance says about realistic constraints or decisions at system scale.",
      "- Choose the code_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}",
      HIDDEN_KEY_LINE,
      WITNESS_LINE,
      (LOOKS_RIGHT_LINE if LOOKS_RIGHT_RUNGS.include?(RUNG_FOR.fetch(rung, rung)))
    ].compact.join("\n")
  end

  def self.schema_fragment
    <<~SCHEMA.chomp
      "code_review": {
          "question": "string — ask what is wrong, why, and how to fix it",
          "purpose":  "string — one sentence: what the code is meant to do",
          "snippet":  "string — 5-#{ExerciseSection::CodeReview::BugHunt::MAX_LINES} lines, matching the bug hunt instruction above",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer, naming no input or output",
          "concept": "string — exactly one concept from the provided vocabulary",
          "answer_key": {
            "issue":          "string — a few sentences: what is wrong and where, quoting the code in backticks",
            "why_it_matters": "string — a few sentences: what goes wrong because of it, for an input the purpose covers",
            "fix":            "string — a few sentences: a fix that works as written",
            "witness":        { "call": "string — one expression", "expected": "string — a literal", "returns": "string — a literal, or raises <ErrorClass>" },
            "looks_right_on": { "call": "string — one expression", "expected": "string — a literal" },
            "fixed_snippet":  "string — the whole snippet with the fix applied"
          }
        }
    SCHEMA
  end
end
