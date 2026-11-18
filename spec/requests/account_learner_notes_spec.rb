require "rails_helper"

RSpec.describe "The Learner notes setting on the Account page", type: :request do
  let(:user) { create_user_with_key(email: "notes-setting@example.com") }

  def setting_section = Nokogiri::HTML(response.body).at_css("#learner-notes-setting")

  context "with LEARNER_NOTES on" do
    before { stub_env("LEARNER_NOTES" => "1") }

    it "is off by default and offered to an account on its own key" do
      login_as(user)

      get account_path

      expect(user.reload.learner_notes_enabled).to be(false)
      expect(setting_section.text).to include("Learner notes: off")
      expect(setting_section.at_css("form[action='#{learner_notes_account_path}'] input[name=enabled][value='1']")).to be_present
    end

    it "turns the setting on and off by the state the button posts" do
      login_as(user)

      patch learner_notes_account_path, params: { enabled: "1" }
      expect(response).to redirect_to(account_path)
      follow_redirect!
      expect(response.body).to include("Learner notes are on.")
      expect(setting_section.text).to include("Learner notes: on")
      expect(user.reload.learner_notes_enabled).to be(true)

      2.times { patch learner_notes_account_path, params: { enabled: "0" } }
      follow_redirect!
      expect(response.body).to include("Learner notes are off.")
      expect(user.reload.learner_notes_enabled).to be(false)
    end

    it "writes the setting under the user row lock" do
      login_as(user)
      locked = []
      allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        locked << original.receiver.id
        original.call(*args, &block)
      end

      patch learner_notes_account_path, params: { enabled: "1" }

      expect(locked).to include(user.id)
      expect(user.reload.learner_notes_enabled).to be(true)
    end

    it "is not offered on a house key, and refuses to turn on there" do
      trial_user = create_trial_user
      login_as(trial_user)

      get account_path
      expect(setting_section).to be_nil

      patch learner_notes_account_path, params: { enabled: "1" }
      expect(response).to redirect_to(account_path)
      follow_redirect!
      expect(response.body).to include("Learner notes need your own API key.")
      expect(trial_user.reload.learner_notes_enabled).to be(false)
    end

    it "lets an account that lost its own key turn its notes off, and says nothing runs without one" do
      user.update!(learner_notes_enabled: true)
      user.update_columns(api_keys: {}, provider: nil)
      login_as(user)

      get account_path

      expect(setting_section.text).to include(I18n.t("accounts.learner_notes.state_needs_key"))
      expect(setting_section.at_css("form[action='#{learner_notes_account_path}'] input[name=enabled][value='0']")).to be_present

      patch learner_notes_account_path, params: { enabled: "0" }

      expect(user.reload.learner_notes_enabled).to be(false)
    end

    it "shows a keyless account whose setting is off no setting at all" do
      user.update_columns(api_keys: {}, provider: nil)
      login_as(user)

      get account_path

      expect(setting_section).to be_nil
    end
  end

  context "with LEARNER_NOTES off" do
    it "hides the setting and refuses a posted change" do
      login_as(user)

      get account_path
      expect(setting_section).to be_nil

      patch learner_notes_account_path, params: { enabled: "1" }
      expect(response).to have_http_status(:not_found)
      expect(user.reload.learner_notes_enabled).to be(false)
    end
  end

  describe "the section's lists and actions" do
    let(:today) { Date.new(2026, 11, 18) }

    around { |example| travel_to(Time.utc(2026, 11, 18, 15)) { example.run } }

    before do
      stub_env("LEARNER_NOTES" => "1")
      user.update!(learner_notes_enabled: true)
    end

    def section = Nokogiri::HTML(response.body).at_css("#learner-notes")

    def reference(date, source, section = "code_review")
      { "date" => date.iso8601, "source" => source, "section" => (section unless source == "note") }.compact
    end

    def item(concept: "n_plus_one", kind: "misconception", term: nil, status: "open", label: "Each row runs its own query.",
             evidence: [ reference(today - 15, "duck") ], came_up_on: nil, **attrs)
      LearnerItem.create!(user: user, concept: concept, bucket: "ruby_rails", kind: kind, term: term, label: label,
                          status: status, evidence: evidence,
                          came_up_on: came_up_on || evidence.map { |ref| ref["date"] }.uniq.sort.reverse,
                          expires_on: today + 10, **attrs)
    end

    def set_on(date)
      DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                            problem_set: { "code_review" => { "question" => "Find the bug", "concept" => "n_plus_one" } })
    end

    def note_on(date, body: "The loop confused me.", explanation: "It runs one query per row.")
      exercise = set_on(date)
      LearnerExtraction.count_attempt!(exercise, close: true)
      LearnerNote.create!(user: user, daily_exercise: exercise, body: body, question_key: "hardest",
                          explain_section: ("code_review" if explanation), explain_concept: ("n_plus_one" if explanation),
                          explain_phrasing: ("explain.first" if explanation), explanation: explanation,
                          explanation_reply: ({ "sound" => "Right.", "correction" => nil } if explanation))
    end

    def waiting_extraction(exercise)
      job = ExtractLearnerItemsJob.new(user_id: user.id, daily_exercise_id: exercise.id, daily_response_id: nil,
                                       run: ExtractLearnerItemsJob::FALLBACK)
      SolidQueue::Job.create!(queue_name: job.queue_name, class_name: job.class.name, arguments: job.serialize,
                              active_job_id: job.job_id, priority: JobPriority::BACKGROUND, scheduled_at: 1.day.from_now)
    end

    it "lists open items with their label, concept, kind, origin, the dates they came up and their expiry" do
      item(evidence: [ reference(today - 13, "duck"), reference(today - 15, "duck") ],
           came_up_on: [ (today - 6).iso8601, (today - 13).iso8601, (today - 15).iso8601 ])
      item(concept: "memoization", kind: "term", term: "memoize", label: "What memoize means.",
           evidence: [ reference(today - 2, "note") ])
      login_as(user)

      get account_path

      rows = section.css(".learner-item-open")
      expect(rows.size).to eq(2)
      first = rows.find { |row| row.text.include?("Each row runs its own query.") }
      expect(first.text).to include("N plus one", "A possible misunderstanding", "From your thinking-partner questions on Nov 3",
                                    "Came up on Nov 3, Nov 5 and Nov 12", "Expires on Nov 28")
      expect(first.css("button").map(&:text)).to eq([ "I've got this", "Delete" ])
      second = rows.find { |row| row.text.include?("What memoize means.") }
      expect(second.text).to include("Memoization", "A term you asked about", "From your note on Nov 16")
    end

    it "states a returned item's history as plain fact" do
      item(returned_after: today - 15, evidence: [ reference(today - 6, "answer") ])
      login_as(user)

      get account_path

      expect(section.at_css(".learner-item-open").text)
        .to include("You marked this as got on Nov 3. It came up again on Nov 12.")
    end

    it "closes an open item with I've got this, dated in the owner's own zone, and refuses a closed one" do
      user.update!(time_zone: "Pacific/Auckland")
      open_item = item
      login_as(user)

      patch got_it_account_learner_item_path(open_item)

      expect(response).to redirect_to(account_path(anchor: "learner-notes"))
      expect(open_item.reload).to have_attributes(status: "dismissed", closed_on: Date.new(2026, 11, 19))
      follow_redirect!
      expect(section.css(".learner-item-open")).to be_empty
      closed = section.at_css(".learner-item-closed")
      expect(closed.text).to include("Each row runs its own query.", "You marked this as got on Nov 19", "Came up on Nov 3")
      expect(closed.css("button").map(&:text)).to eq([ "Delete" ])

      patch got_it_account_learner_item_path(open_item)
      follow_redirect!
      expect(response.body).to include("That reminder is already closed.")
      expect(open_item.reload.closed_on).to eq(Date.new(2026, 11, 19))
    end

    it "closes an item under the user row lock" do
      open_item = item
      login_as(user)
      locked = []
      allow(User).to receive(:lock).and_wrap_original do |original, *args|
        locked << args
        original.call(*args)
      end

      patch got_it_account_learner_item_path(open_item)

      expect(locked).not_to be_empty
      expect(open_item.reload.status).to eq("dismissed")
    end

    it "keeps a dismissed item in the closed list for 30 days, and never lists an expired one" do
      item(status: "dismissed", closed_on: today - 30, label: "Closed thirty days ago.")
      item(concept: "memoization", status: "dismissed", closed_on: today - 31, label: "Closed thirty-one days ago.")
      item(concept: "caching", status: "expired", closed_on: today - 1, label: "Expired yesterday.")
      login_as(user)

      get account_path

      closed = section.css(".learner-item-closed").map(&:text).join
      expect(closed).to include("Closed thirty days ago.")
      expect(closed).not_to include("Closed thirty-one days ago.", "Expired yesterday.")
    end

    it "deletes an item, and finds nothing on another account's" do
      own = item
      other_user = create_user_with_key(email: "other-notes@example.com")
      theirs = LearnerItem.create!(user: other_user, concept: "n_plus_one", bucket: "ruby_rails", kind: "concept",
                                   label: "Theirs.", evidence: [ reference(today, "note") ], came_up_on: [ today.iso8601 ],
                                   expires_on: today + 14)
      login_as(user)

      delete account_learner_item_path(own)
      expect(LearnerItem.exists?(own.id)).to be(false)

      delete account_learner_item_path(theirs)
      expect(LearnerItem.exists?(theirs.id)).to be(true)
      follow_redirect!
      expect(response.body).to include("That was already deleted.")
    end

    it "lists daily notes and explanations with their questions and dates" do
      note_on(today - 2)
      login_as(user)

      get account_path

      note = section.at_css(".learner-note-row")
      expect(note.text).to include("Nov 16", "What was the hardest part of today's set?", "The loop confused me.")
      expect(note.css("button").map(&:text)).to eq([ "Delete" ])
      explanation = section.at_css(".learner-explanation-row")
      expect(explanation.text).to include("Nov 16", "In your own words, what does N plus one do?", "It runs one query per row.")
    end

    it "deletes a note and every item that cited it, even one with other evidence, keeping the explanation" do
      note = note_on(today - 2)
      only_note = item(evidence: [ reference(today - 2, "note") ])
      mixed = item(concept: "memoization", evidence: [ reference(today - 2, "note"), reference(today - 2, "duck") ])
      other_day = item(concept: "caching", evidence: [ reference(today - 3, "note") ])
      explained = item(concept: "scope_chaining", evidence: [ reference(today - 2, "explanation") ])
      login_as(user)

      delete note_account_learner_note_path(note)

      expect(note.reload).to have_attributes(body: nil, question_key: nil, explanation: "It runs one query per row.")
      expect(LearnerItem.where(id: [ only_note, mixed, other_day, explained ].map(&:id))).to contain_exactly(other_day, explained)
      follow_redirect!
      expect(section.css(".learner-note-row")).to be_empty
    end

    it "deletes an explanation with its reply and every item that cited it, keeping the note" do
      note = note_on(today - 2)
      mixed = item(evidence: [ reference(today - 2, "explanation"), reference(today - 2, "answer") ])
      noted = item(concept: "memoization", evidence: [ reference(today - 2, "note") ])
      login_as(user)

      delete explanation_account_learner_note_path(note)

      expect(note.reload).to have_attributes(explanation: nil, explanation_reply: nil, explain_concept: nil,
                                             explain_section: nil, explain_phrasing: nil, body: "The loop confused me.")
      expect(LearnerItem.where(id: [ mixed.id, noted.id ])).to contain_exactly(noted)
      follow_redirect!
      expect(section.css(".learner-explanation-row")).to be_empty
    end

    it "deletes the row outright once nothing is left in it, even for a set already read, keeping the set's counts" do
      note = note_on(today - 2, explanation: nil)
      login_as(user)

      delete note_account_learner_note_path(note)

      expect(LearnerNote.exists?(note.id)).to be(false)
      expect(LearnerExtraction.for(note.daily_exercise.reload)).to have_attributes(attempts: 1, closed?: true)
    end

    it "discards a waiting extraction for the deleted note's set, and leaves another set's" do
      note = note_on(today - 2)
      other = note_on(today - 3)
      waiting = [ waiting_extraction(note.daily_exercise), waiting_extraction(other.daily_exercise) ]
      login_as(user)

      delete explanation_account_learner_note_path(note)

      expect(SolidQueue::Job.where(id: waiting.map(&:id)).pluck(:id)).to eq([ waiting.last.id ])
    end

    it "deletes every note row and item at once, and discards every waiting extraction" do
      read = note_on(today - 2)
      unread = LearnerNote.create!(user: user, daily_exercise: set_on(today), body: "Before submitting.")
      item
      waiting = waiting_extraction(read.daily_exercise)
      login_as(user)

      delete all_account_learner_notes_path

      expect(LearnerItem.where(user: user)).to be_empty
      expect(LearnerNote.where(id: [ read.id, unread.id ])).to be_empty
      expect(LearnerExtraction.for(read.daily_exercise.reload)).to have_attributes(attempts: 1, closed?: true)
      expect(SolidQueue::Job.where(id: waiting.id)).to be_empty
      follow_redirect!
      expect(response.body).to include("Every learner note and reminder was deleted.")
      expect(section.css(".learner-item-open, .learner-note-row, .learner-explanation-row")).to be_empty
    end

    it "shows the section with the switch off while the account has rows, without the setting" do
      stub_env("LEARNER_NOTES" => nil)
      item
      login_as(user)

      get account_path

      expect(section.at_css(".learner-item-open")).to be_present
      expect(setting_section).to be_nil
      delete account_learner_item_path(LearnerItem.sole)
      expect(LearnerItem.count).to eq(0)
    end

    it "keeps the section's fixed copy free of tier words" do
      copy = I18n.t("accounts.learner_notes").to_s
      expect(I18n.t("accounts.learner_notes").values.flat_map { |value| value.is_a?(Hash) ? value.values : [ value ] })
        .to all(satisfy { |line| line !~ /tier|reduced|struggl|trouble|weak|score|level/i })
      expect(copy).not_to be_empty
    end
  end
end
