class LearnerItemsPrompt
  ANSWER_LIMIT = 2_000
  TURN_LIMIT = 1_000
  MAX_ITEMS_BLOCK_CHARS = 10_000

  SYSTEM = <<~PROMPT.chomp
    You are reading what an engineer wrote on one day of practice, to note what
    they may still need help with. They have already submitted the day's work.
    You are not grading it, and nothing you write is shown to them as a grade.

    Return at most #{LearnerItem::MAX_NEW_PER_DAY} new items, each tied to something the engineer
    typed that day, plus a repeat for each open item that came up again. An
    empty list of items is a valid reply.

    Which kind, from what the engineer wrote. Each kind has its own trigger:
    - "misconception": an explicit mistaken claim the engineer made.
    - "concept": a stated uncertainty, such as "I still don't understand when to
      use this", with no false belief asserted. It is a concept to practise, with
      the statement as its evidence. A stated uncertainty is never a
      "misconception", because it asserts no false belief.
    - "term": a question asked out of curiosity, such as what a word means.

    What not to infer:
    - A question asked out of curiosity is a "term", not a misunderstanding.
    - Strengths are not to be reported. There is no kind for them.
    - An explanation is not a sign of difficulty. The engineer is asked to
      explain a concept every day, whether or not they found it hard. A clear,
      correct explanation yields no item. Only an explicit mistaken claim in it
      yields a "misconception", and only a stated uncertainty in it yields a
      "concept".
    - Read the whole thread before inferring an open issue. Read the engineer's
      later messages first. A confusion the engineer resolved later in the same
      thread, or a mistaken belief they corrected themselves, yields no
      "misconception" item.
    - The duck's words are context, not evidence of belief. Anything the duck
      said, including a guess about what the engineer thinks or a misleading
      statement the engineer never took up, is never proof of what the engineer
      believes. Only the engineer's own words are.
    - A mistaken claim is not an incomplete explanation. A "misconception" needs
      an explicit mistaken claim the engineer made. An explanation that leaves
      something out, stops early or stays general is incomplete, not mistaken,
      and yields no "misconception" item, nor a "concept" item unless the
      engineer also says they are unsure.
    - When the evidence is ambiguous, return nothing. If it is unclear whether
      the engineer holds a mistaken belief, or what the belief is, write no item.

    Earlier items:
    - Report a repeat. When today shows the same thing as an open item again,
      return an item with that item's concept, bucket, kind and term. Its label
      is ignored, so it need not be reworded: the open item keeps the label the
      engineer has already read. The same goes for an earlier closed item that
      came up again: return it with its concept, bucket, kind and term, and a
      label in the usual form.
    - Refine only when there is something new. When today adds something an
      earlier label does not say, such as a different case, a narrower or
      different belief, or a later step, write it with a label that says what is
      new. With nothing new, return the repeat and do not restate the earlier
      label.

    Each item has these fields:
    - "concept" and "bucket": one concept from the list you are given, and the
      bucket it is listed under.
    - "kind": "misconception", "concept" or "term".
    - "term": for a "term" item only, the word or phrase asked about, at most
      #{LearnerItem::MAX_TERM_LENGTH} characters of letters, digits, spaces and _ + # . / -. Leave it
      out for the other kinds.
    - "label": one sentence of at most #{LearnerItem::MAX_LABEL_LENGTH} characters, on one line, saying in
      plain words what the engineer needs. Never quote the engineer.
    - "evidence": where it came up, as a list of at most #{LearnerItem::MAX_EVIDENCE} references:
      {"source": "duck", "section": "<section key>"} for the engineer's own
      messages in that section's duck thread,
      {"source": "answer", "section": "<section key>"} for their answer to that
      section, {"source": "note"} for the day's note, and
      {"source": "explanation"} for the day's explanation.

    Return a single JSON object and nothing else:
    {"items": [{"concept": "...", "bucket": "...", "kind": "...", "term": "...", "label": "...", "evidence": [{"source": "...", "section": "..."}]}]}

    #{PromptStandards::PLAIN_LANGUAGE_STANDARD}
  PROMPT

  def self.generate(concepts:, sections:, note:, explanation:, open_items:, earlier_items:)
    { system: "#{SYSTEM}\n\n#{UserText::PROMPT_RULE}", prompt: [
      concept_block(concepts), items_block(open_items, earlier_items),
      *sections.map { |section| section_block(section) }, note_block(note), explanation_block(explanation),
      "Return the JSON object your system instructions describe."
    ].join("\n\n") }
  end

  def self.items_block(open_items, earlier_items)
    [ open_block(open_items), earlier_block(earlier_items) ].join("\n\n")
  end

  def self.concept_block(concepts)
    lines = concepts.map { |bucket, names| "- #{bucket}: #{names.join(", ")}" }
    "The concepts you may choose from, by bucket:\n#{lines.join("\n")}"
  end

  def self.open_block(items)
    return "Open items: none." if items.empty?

    "Open items, each of which you may report as a repeat:\n#{items.map { |item| item_line(item) }.join("\n")}"
  end

  def self.earlier_block(items)
    return "Earlier closed items: none." if items.empty?

    lines = items.map { |item| item_line(item, "#{item[:status]} on #{item[:date]}") }
    "Earlier closed items, newest first:\n#{lines.join("\n")}"
  end

  def self.item_line(item, closed = nil)
    key = [ "concept: #{item[:concept]}", "bucket: #{item[:bucket]}", "kind: #{item[:kind]}",
            ("term: #{item[:term]}" if item[:term]), closed ].compact.join(", ")
    UserText.labelled("- #{key}. Label:", item[:label])
  end

  def self.section_block(section)
    [ %(The "#{section[:key]}" section:\n#{SectionContext.render(section[:data])}),
      UserText.labelled("Their answer:", section[:answer], blank: "(none)", limit: ANSWER_LIMIT),
      thread_block(section[:turns]) ].join("\n\n")
  end

  def self.thread_block(turns)
    return "Their duck thread: (none)" if turns.empty?

    lines = UserText.tag_history(turns, limit: TURN_LIMIT).map do |turn|
      turn[:role].to_s == "user" ? "Engineer:\n#{turn[:content]}" : "Duck:\n#{UserText.defanged(turn[:content], limit: TURN_LIMIT)}"
    end
    "Their duck thread, oldest first:\n#{lines.join("\n")}"
  end

  def self.note_block(note)
    return "The day's note: (none)" unless note

    "The day's note, answering \"#{note[:question]}\":\n#{UserText.tagged(note[:text], blank: "(none)")}"
  end

  def self.explanation_block(explanation)
    return "The day's explanation: (none)" unless explanation

    %(The day's explanation, of the concept "#{explanation[:concept]}" from the "#{explanation[:section]}" section, ) +
      %(answering "#{explanation[:question]}":\n#{UserText.tagged(explanation[:text], blank: "(none)")})
  end

  private_class_method :items_block, :concept_block, :open_block, :earlier_block, :item_line, :section_block,
                       :thread_block, :note_block, :explanation_block
end
