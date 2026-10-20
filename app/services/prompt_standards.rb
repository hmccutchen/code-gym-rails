module PromptStandards
  PLAIN_LANGUAGE_STANDARD = <<~STANDARD.chomp.freeze
    Write prose for the engineer this way:

    Avoid, in order of how often these actually show up:
    - Manufactured rhetorical contrast — "not X, but Y" used purely for punch when a plain sentence says the same thing.
    - Buzzwords and jargon. Use the plain-language equivalent; if a technical term is genuinely necessary, define it briefly on first use.
    - Placeholder phrases — "please note," "at this time," "it's worth mentioning."
    - Overusing "please" in instructions — state it directly.
    - Starting every sentence with the same construction.
    - Exclamation points, outside genuine, rare emphasis.
    - Forced cleverness or trying to sound entertaining.
    - Both choppy fragments and long-winded run-ons.

    Aim for:
    - Active voice — make clear who or what is doing the thing.
    - Second person, direct address.
    - Concrete over abstract — a specific example beats a general description of the same idea.
    - Conditions before instructions, not after.
    - Natural rhythm — if a sentence sounds stilted read aloud, rewrite it.

    Calibration: too informal ("This is a total game-changer!") and too formal/overwrought ("The interface undergoes a paradigmatic transformation") are both wrong; aim for the plain middle ("This changes how the interface works").
  STANDARD

  def self.explain_differently_standard(subject)
    "Explain the SAME #{subject} again using a genuinely different approach — a\n" \
      "different analogy, a different level of abstraction, or a concrete worked\n" \
      "scenario instead of a principle. Do not repeat the original wording."
  end

  def self.prior_framings(prior_alternates)
    return "No alternate framing has been given yet." if prior_alternates.empty?

    "Framings already given (do NOT reprise these angles or analogies):\n" +
      prior_alternates.map.with_index(1) { |a, i| "#{i}. #{UserText.tagged(a, blank: '')}" }.join("\n")
  end
end
