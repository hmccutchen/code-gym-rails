# generate_exercise and retry_section share AiService#build_system_prompt, so the first match, generate_exercise, wins.
module FakeReplies
  SYSTEM_PROMPT_MARKERS = {
    "generate_exercise"           => "generating personalized daily exercise sets",
    "retry_section"               => "generating personalized daily exercise sets",
    "review_response"             => "giving direct, specific feedback",
    "assess_difficulty"           => "rating how hard",
    "generate_concept_reference"  => "writing a concise, durable reference",
    "generate_recognition_guide"  => "how to recognize one category of problem",
    "explain_concept_differently" => "re-teaching one concept",
    "explain_differently"         => "re-explaining one point",
    "review_follow_up"            => "answering a follow-up question",
    "duck_thread"                 => "Socratic thinking partner",
    "pseudocode_critique"         => "reviewing an engineer's PSEUDOCODE plan",
    "pseudocode_translate"        => "TRANSCRIBER, not a reviewer",
    "judge_section"               => "checking one section of a generated coding exercise",
    "judge_review"                => "editing the prose of one section's code review"
  }.freeze

  def purpose_for(system)
    purpose, _marker = SYSTEM_PROMPT_MARKERS.find { |_, marker| system.to_s.include?(marker) }
    purpose || raise("FakeReplies has no marker matching the system prompt: #{system.inspect}")
  end
end

RSpec.configure { |config| config.include FakeReplies }
