class SectionJudgePrompt
  PRINCIPLE_GUIDANCE = {
    "scope_mismatch" => "answering correctly does not require the tagged concept, or the question asks for something the concept does not cover.",
    "unstated_prerequisite" => "solving depends on important knowledge that is neither the tagged concept nor supplied by the problem, and a brief clarifying phrase could not reasonably supply it.",
    "underdetermined" => "information needed for a defensible answer is missing and is not present or implied anywhere in the draft.",
    "reasoning_failure" => "measured against the kind's task, the wording structurally gives away the defect's location or the solution, or otherwise makes the task impossible as designed. Structural only: a removable leaking sentence is an edit."
  }.freeze

  PRINCIPLE_LINES = JudgeVerdict::PRINCIPLES
    .map { |principle| "- #{principle}: #{PRINCIPLE_GUIDANCE.fetch(principle)}" }
    .join("\n").freeze

  SYSTEM = <<~PROMPT.freeze
    You are checking one section of a generated coding exercise before an engineer sees it. You judge the section as written; you are not told what its author intended.

    A question may be difficult, unfamiliar, or conceptually demanding. Its difficulty must come from the intended reasoning task, not from unclear wording, missing information, or accidental prerequisites. Reject when the problem itself is broken. Edit when the problem is sound but poorly expressed. Never reject a problem for being hard.

    Work through these checks internally, in this order, and stop at the first rejection. Reply with only the JSON verdict, with no text before or after it.
    1. Answerable. Can a knowledgeable developer at the stated level reach a defensible answer without guessing which scenario the author meant? Normal technical inference is allowed. The section is unanswerable only when materially different readings are possible and the answer depends on picking the author's. If prose can close the gap, that is an edit, on one condition: a clarification may only surface what the draft already shows or implies, such as behaviour visible in the code that the prose never states. If the missing information is not in the draft at all, you have no source for it: reject as underdetermined. Never invent facts.
    2. Valid. Check the remaining rejection principles.
    3. Improvable. If the section is sound, rewrite its prose fields where one of the listed issues applies, or return keep.

    Rejection principles, the only #{JudgeVerdict::PRINCIPLES.size}:
    #{PRINCIPLE_LINES}

    Never reject because a section is straightforward, familiar, hard, unfamiliar, or names its concept. The tagged concept may be new to the engineer; a reference explains it beside the section, so unfamiliarity with it is never grounds for rejection. Judge against the stated level, not any notion of a typical engineer: a section at principal level is supposed to be difficult. You never change difficulty: the draft already pitched this section, and you preserve that pitch and the task exactly.

    Leakage means revealing where the defect is or what the answer is. It does not mean naming the domain or the tagged concept. "What vulnerability exists in this endpoint?" is the intended framing for a security review, not leakage.

    Edits rewrite prose fields only. The teaching note is a hint the engineer can reveal after attempting, so it gets the same prose rules and must not alter the task. Issues, the only #{JudgeVerdict::ISSUE_TYPES.size}: #{JudgeVerdict::ISSUE_TYPES.join(", ")}.

    When you edit: never modify code or schema content, the tagged concept, the kind, or any field that carries the planted defect. Never change the task or the difficulty; never make a subtle flaw more obvious or an obvious one more obscure. Never add a technical claim the draft does not make or imply. Never add information only to make the answer easier to find, and never solve the exercise. Never remove or genericize the scenario setting; trim filler inside a statement, never the setting. Return exactly the fields you were asked to rewrite, nothing else.

    For any prose you rewrite:
    #{PromptStandards::PLAIN_LANGUAGE_STANDARD}

    Return only JSON, one of:
    {"status":"keep"}
    {"status":"edit","issues":[{"type":"...","evidence":"<quoted text>"}],"fields":{"<prose field>":"<rewritten>"}}
    {"status":"reject","principle":"...","evidence":"<quoted text>","reason":"<one or two sentences>"}
  PROMPT

  def self.visible(kind, section)
    section.except(*ExerciseSection.all_answer_key_fields, *ProblemSetIngest::SERVER_STAMPS, *kind.judge_hidden_fields)
  end

  def self.generate(kind:, section:, rung:, locked:)
    shown = visible(kind, section)

    { response_schema: JudgeVerdict.schema_for(kind), system: SYSTEM, prompt: <<~PROMPT }
      Section kind: #{kind.key}
      The learner's task for this kind: #{kind.judge_task}
      #{kind.discovery? ? "This is a discovery task: wording that names where the issue is defeats it." : "Naming the concept is expected for this kind."}
      Tagged concept: #{shown["concept"]}
      Pitched at: #{rung}#{locked ? " (locked: this level was asked for unconditionally)" : ""}
      Level meaning: #{KindDifficulty::LEVEL_DEFINITIONS.fetch(rung)}
      Prose fields you may rewrite: #{kind.prose_fields.join(', ')}
      Every other field is the artifact and must not change.
      #{guidance_block(kind)}
      The section as delivered:
      #{JSON.pretty_generate(shown)}#{attachment_block(kind, section)}
    PROMPT
  end

  def self.guidance_block(kind)
    kind.judge_guidance ? "\n#{kind.judge_guidance}\n" : ""
  end

  def self.attachment_block(kind, section)
    attachment = kind.judge_attachment(section)
    attachment ? "\n\n#{attachment}" : ""
  end

  private_class_method :guidance_block, :attachment_block
end
