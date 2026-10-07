# Hand-written Learn lessons, for concepts that belong on the Learn tab but in
# no vocabulary. A concept in a vocabulary can be tagged on a generated
# section, drilled, and given mastery and retention state; these cannot,
# because a short snippet cannot test them. reading_unfamiliar_code is about
# moving through a change and its callers across files, which no single
# section can host.
#
# Static and hand-curated, like Glossary, and never sent to a provider. Each
# lesson names the ConceptGroup it is listed under on the Learn index, so it
# sits beside its siblings without joining their vocabulary.
#
# A section is a heading and an ordered list of blocks: [:paragraph, text],
# [:steps, [[label, text], ...]] or [:code, text]. Code blocks are not prose,
# so .learn_text leaves them out of the plain-language checks.
module LearnLessons
  READING_UNFAMILIAR_CODE = {
    group: "meta_skill",
    summary: "How to find your way through code you didn't write, in a few quick passes.",
    sections: [
      {
        heading: "Why code reads differently",
        blocks: [
          [ :paragraph, "You read a story from the first page to the last, because its author chose that order. " \
                        "Code runs in the order the computer follows, and that order jumps around: one line calls a " \
                        "method in another file, which calls three more." ],
          [ :paragraph, "Most of the time you aren't reading a finished program either. You're reading a change, a " \
                        "handful of added and removed lines inside a much larger system. Any line in that change can " \
                        "depend on code anywhere in the system, and code anywhere can depend on it." ]
        ]
      },
      {
        heading: "Read in passes",
        blocks: [
          [ :paragraph, "Read in several quick passes, each with one question. A single slow read from top to " \
                        "bottom fills your head with details before you know which ones matter." ],
          [ :steps, [
            [ "Structure", "Which files and classes does the change touch, and what is each one for? Skim the names only." ],
            [ "Sub-structure", "Inside each file, which methods changed, and what does each one return?" ],
            [ "One path", "Pick the path that matters most, usually the main path of the change. Follow which " \
                          "method calls which, and leave what each one does for later." ],
            [ "Callers", "Take one method or value the change affects and find everything that uses it, " \
                         "including code the change never touched." ],
            [ "One careful read", "Read the change from end to end once, slowly. When something looks odd, go " \
                                  "back to the pass that answers it." ]
          ] ],
          [ :paragraph, "Treat everything outside your current question as a black box: assume it does what its " \
                        "name says, and open it only when your question needs what is inside." ]
        ]
      },
      {
        heading: "Where people go wrong",
        blocks: [
          [ :paragraph, "The most common slip is reading only the lines the change shows. A diff, the list of lines " \
                        "a change adds and removes, hides the code around it, and that unchanged code can now behave " \
                        "differently. None of it appears in the diff." ],
          [ :paragraph, "The other slip is giving up and guessing. When the code feels too big, approving it because " \
                        "the names look right is tempting. Pick a smaller question instead, such as who calls this " \
                        "method, and answer that one." ]
        ]
      },
      {
        heading: "Code a machine wrote",
        blocks: [
          [ :paragraph, "An AI tool can write code faster than you can read it, and you still have to read it. A " \
                        "change that passes its tests can be far bigger than the task needed, or ignore how your " \
                        "team does things. Use the same passes, and at the structure pass also ask whether the " \
                        "change is the size the task called for." ]
        ]
      },
      {
        heading: "Worked example",
        blocks: [
          [ :paragraph, "Someone changes how an order adds up its total. Here is the diff:" ],
          [ :code, <<~DIFF.chomp ],
             class Order
               def total
            -    line_items.sum(&:price)
            +    line_items.sum(&:price_cents)
               end
             end
          DIFF
          [ :paragraph, "This mailer is not part of the change:" ],
          [ :code, <<~CALLER.chomp ],
            class ReceiptMailer < ApplicationMailer
              def receipt(order)
                @summary = "You paid $\#{order.total}"
              end
            end
          CALLER
          [ :steps, [
            [ "Structure", "One file changed, the Order model, and one method in it, total." ],
            [ "Sub-structure", "total still returns a sum of the line items. Only the field it sums changed, from " \
                               "price to price_cents." ],
            [ "One path", "total calls line_items, then price_cents on each item. You leave line_items closed and " \
                          "assume it returns this order's items." ],
            [ "Callers", "You search for .total and find ReceiptMailer#receipt. It puts a dollar sign in front of " \
                         "the number, so a $19.99 order that used to read $19.99 now reads $1999." ],
            [ "One careful read", "On the slow read you ask whether anything else shows total as dollars. If you " \
                                  "find one, you go back to the callers pass." ]
          ] ],
          [ :paragraph, "The callers pass found the bug, in a file the diff never showed you." ]
        ]
      }
    ]
  }.freeze

  LESSONS = { "reading_unfamiliar_code" => READING_UNFAMILIAR_CODE }.freeze

  def self.find(key)
    LESSONS[key.to_s]
  end

  def self.in_group(group)
    LESSONS.select { |_key, lesson| lesson[:group] == group }.keys
  end

  # Every piece of prose a reader sees, keyed for a failure message. A section
  # is one text, so a rule about a run of sentences reads the section whole.
  def self.learn_text
    LESSONS.each_with_object({}) do |(key, lesson), texts|
      texts["#{key}:summary"] = lesson[:summary]
      lesson[:sections].each do |section|
        texts["#{key}:#{section[:heading]}:heading"] = section[:heading]
        texts["#{key}:#{section[:heading]}"] = section_prose(section)
      end
    end
  end

  def self.section_prose(section)
    section[:blocks].filter_map do |type, content|
      case type
      when :paragraph then content
      when :steps then content.map { |label, text| "#{label}. #{text}" }.join(" ")
      end
    end.join(" ")
  end
  private_class_method :section_prose
end
