# Design notes: docs/code-notes/app/models/section_kind_guide.md
module SectionKindGuide
  GUIDES = {
    "code_review" => {
      summary: "Find the one problem in a short piece of code and say how you'd fix it. " \
               "This builds the habit of reading a change closely before you approve it.",
      example: "You see a ten-line method from a library app that emails members about overdue books. " \
               "The question asks what's wrong with it and how you'd fix it. " \
               "On some days the code is a test file or a database migration instead."
    },
    "design_comparison" => {
      summary: "Two pieces of code both work, and you pick the one that suits the system described. " \
               "Then you name the fact from the scenario or question that decides it.",
      example: "A grocery list app will add new kinds of items later. " \
               "Piece A and Piece B both save an item today, built two different ways. " \
               "You choose one and point to the sentence that settles it."
    },
    "pattern" => {
      summary: "Each day's section names a design pattern and why it exists, then asks how you'd apply it to a stated problem. " \
               "The answer box starts with headings for the parts a full answer covers.",
      example: "The setting is a gym log, where one button saves a workout, updates a streak and sends a message. " \
               "You're asked how you'd structure the work using the day's pattern, and you describe it in words."
    },
    "challenge" => {
      summary: "Write working code for a small task the question describes. " \
               "Some days you start from a skeleton, and other days from an empty box.",
      example: "The task is a method that sorts a shopping list by aisle, with a sentence saying what it should return. " \
               "You write the method in the answer box."
    },
    "architecture" => {
      summary: "Choose between two or three ways to build something, and justify the choice by what each one costs. " \
               "You write reasoning, not code.",
      example: "A library app has to tell members when a book they reserved comes back. " \
               "One option checks every few minutes, and another reacts the moment the book is returned. " \
               "You pick one for the situation described and say what you'd give up."
    },
    "security_review" => {
      summary: "Find the one weakness someone could exploit in a short piece of code, and say how you'd close it. " \
               "It trains you to read code the way an attacker would.",
      example: "You see a short controller action that shows a shared shopping list. " \
               "The question asks what someone could exploit here and how you'd stop it."
    },
    "parsons_problem" => {
      summary: "Put shuffled pieces of code back in the order that works. " \
               "Drag them, or move one with Ctrl (Command on a Mac) and the up or down arrow.",
      example: "A short method that totals a gym member's weekly workouts arrives in a random order. " \
               "You arrange the pieces until the method would run and give the right total."
    },
    "plan_review" => {
      summary: "Read an implementation plan, written as if by an AI assistant, before any code exists. " \
               "Say what you'd push back on, since a problem costs less to fix in a plan than in finished code.",
      example: "The plan lays out five steps for letting gym members export their workout history. " \
               "You're asked what you'd want changed before you approve it."
    },
    # Names no gap and no kind of gap: the real ones are the section's hidden answer key.
    "ambiguity_hunt" => {
      summary: "Read a vague feature request and write down what you'd need clarified before you could build it. " \
               "Asking early costs less than building the wrong thing.",
      example: "A product manager writes: “Let people pause their daily practice while they're on holiday.” " \
               "You're asked what you'd need answered before building it."
    },
    "pseudocode_to_code" => {
      summary: "Write the steps to solve a problem in plain words, without worrying about syntax. " \
               "When your answer is reviewed, Code Gym turns your steps into code exactly as written, " \
               "so you can see what a missing step would do.",
      example: "The problem is merging overlapping bookings in a meeting room's calendar. " \
               "You write your steps, and “Check my plan” can point out gaps before you submit."
    }
  }.freeze

  def self.for(key)
    GUIDES.fetch(key.to_s)
  end

  def self.learn_text
    GUIDES.each_with_object({}) do |(key, guide), texts|
      texts["kind:#{key}:summary"] = guide[:summary]
      texts["kind:#{key}:example"] = guide[:example]
    end
  end
end
