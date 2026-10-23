require "rails_helper"

RSpec.describe "Admin::JudgeSolves", type: :request do
  let(:admin) { create_user_with_key(email: "admin@example.com", name: "Admin") }
  let(:member) { create_user_with_key(email: "member@example.com", name: "Member") }
  let(:exercise) { exercise_for(member, Date.current) }

  before { ENV["ADMIN_EMAILS"] = "admin@example.com" }
  after  { ENV.delete("ADMIN_EMAILS") }

  def exercise_for(user, date)
    DailyExercise.create!(user: user, date: date, generated_at: Time.current.change(usec: 0), language: "ruby_rails",
                          problem_set: { "design_comparison" => section_text("shipped") })
  end

  def section_text(tag, better: "a")
    { "title" => "Title #{tag}", "scenario" => "Scenario #{tag}", "question" => "Question #{tag}",
      "piece_a" => "piece_a_#{tag} = 1", "piece_b" => "piece_b_#{tag} = 2", "concept" => "caching",
      "answer_key" => { "better" => better, "deciding_fact" => "Deciding #{tag}", "principle" => "Principle #{tag}",
                        "why_other_fails" => "Fails #{tag}" } }
  end

  def solve!(tag, on: exercise, **overrides)
    attributes = { user_id: on&.user_id, daily_exercise: on, set_generated_at: on&.generated_at, source: "live",
                   section: "design_comparison", attempt: 0, edit_check: false, shipped: true, edit_reverted: false,
                   rung: "senior", locked: false, concept: "caching", judge_status: "keep", judge_pick: "b",
                   key_better: "a", matched: false, judged_section: section_text(tag),
                   judge_provider: "anthropic", judge_model: "claude-test" }
    JudgeSolve.create!(attributes.merge(overrides))
  end

  def synthetic!(tag, **overrides)
    solve!(tag, on: nil, source: "synthetic", **overrides)
  end

  def review!(target = exercise, sections: %w[design_comparison])
    DailyResponse.create!(user: target.user, daily_exercise: target, date: target.date, submitted_at: Time.current,
                          ai_review: sections.index_with { { "rating" => "solid" } })
  end

  def entry(solve) = page.at_css("article##{ActionView::RecordIdentifier.dom_id(solve)}")

  def page = Nokogiri::HTML(response.body)

  def withheld_line = page.at_css(".withheld-count strong").text

  def placeholders = page.css(".judge-solve-waiting:not(.waiting-more)").map { |node| node.text.squish }

  def placeholder_text(solve) = "#{solve.created_at.to_date.iso8601} · #{solve.source} · #{solve.rung} · waiting for the engineer's review"

  def expect_hidden(solve, tag)
    expect(entry(solve)).to be_nil
    expect(placeholders).to include(placeholder_text(solve))
    expect(response.body).not_to include("Deciding #{tag}", "piece_a_#{tag}", "piece_b_#{tag}", "Title #{tag}",
                                         "Scenario #{tag}", "Principle #{tag}", "Fails #{tag}")
    expect(page.css("form.verdict-form").map { |form| URI(form["action"]).path }).not_to include(admin_judge_solve_path(solve))
  end

  describe "GET /admin/judge_solves" do
    it "redirects a non-admin to root with an alert" do
      login_as(member)

      get admin_judge_solves_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Not authorized.")
    end

    it "hides an unreviewed shipped row, live or replay, showing only its date, source and rung" do
      live = solve!("live")
      replay = solve!("replay", source: "replay")
      login_as(admin)

      get admin_judge_solves_path(source: "all", show: "all")

      expect_hidden(live, "live")
      expect_hidden(replay, "replay")
      expect(placeholders).to contain_exactly(placeholder_text(live), placeholder_text(replay))
    end

    it "hides a live row whose shipped is false by accident, with its key and pick nowhere in the body" do
      accidental = solve!("accident", shipped: false, judge_pick: "b", key_better: "a")
      login_as(admin)

      get admin_judge_solves_path(show: "all")

      expect_hidden(accidental, "accident")
      expect(response.body).not_to include("Judge's pick", "judge-pick", "Key: piece")
      expect(page.css("form")).to be_empty
    end

    it "hides a reverted edit's edit-check row before review" do
      reverted = solve!("edited", edit_check: true, shipped: false, edit_reverted: true, revert_reason: "solve_mismatch")
      login_as(admin)

      get admin_judge_solves_path(show: "reverts")

      expect_hidden(reverted, "edited")
    end

    it "hides the pre-edit draft of a kept edit before review" do
      draft = solve!("predraft", shipped: false, matched: true, judge_pick: "a")
      solve!("kept", edit_check: true, matched: true, judge_pick: "a")
      login_as(admin)

      get admin_judge_solves_path(show: "all")

      expect_hidden(draft, "predraft")
    end

    it "hides a row when only another section of the day has been reviewed" do
      row = solve!("partly")
      review!(sections: %w[code_review])
      login_as(admin)

      get admin_judge_solves_path(show: "all")

      expect_hidden(row, "partly")
    end

    it "keeps a regenerated set's old row hidden after the new set's section is reviewed" do
      old_row = solve!("oldset", set_generated_at: exercise.generated_at - 1.hour)
      solve!("newset")
      review!
      login_as(admin)

      get admin_judge_solves_path(show: "all")

      expect_hidden(old_row, "oldset")
    end

    it "shows replaced_by_retry, section_dropped and synthetic rows before review" do
      retried = solve!("retried", shipped: false, never_shown_reason: "replaced_by_retry")
      dropped = solve!("dropped", shipped: false, never_shown_reason: "section_dropped")
      made_up = synthetic!("synthetic")
      login_as(admin)

      get admin_judge_solves_path(source: "all")

      [ retried, dropped, made_up ].each { |solve| expect(entry(solve)).to be_present }
      expect(response.body).to include("Deciding retried", "Deciding dropped", "Deciding synthetic", "replaced by a retry")
    end

    it "shows a reviewed row's problem, pieces, key, pick and form" do
      row = solve!("reviewed")
      review!
      login_as(admin)

      get admin_judge_solves_path

      shown = entry(row)
      expect(shown.text).to include("Title reviewed", "Scenario reviewed", "Question reviewed", "Deciding reviewed",
                                    "Principle reviewed", "Fails reviewed", "Key: piece A", "Judge's pick: B")
      expect(shown.css("pre.snippet code.highlight").size).to eq(2)
      expect(shown.css("select[name='judge_solve[human_call]'] option").map { |o| o["value"] })
        .to eq([ "" ] + JudgeSolve::MISMATCH_CALLS)
      expect(shown.at_css("form input[name='_method']")["value"]).to eq("patch")
    end

    it "offers the matched calls on a matched row" do
      row = solve!("matched", matched: true, judge_pick: "a")
      review!
      login_as(admin)

      get admin_judge_solves_path(show: "all")

      expect(entry(row).css("select option").map { |o| o["value"] }).to eq([ "" ] + JudgeSolve::MATCHED_CALLS)
    end

    it "offers no form on an unsolved row" do
      row = solve!("unsolved", matched: nil, judge_pick: nil, judge_status: nil, unsolved_reason: "invalid_output")
      review!
      login_as(admin)

      get admin_judge_solves_path(show: "all")

      expect(entry(row).text).to include("Unsolved: invalid_output")
      expect(entry(row).at_css("form")).to be_nil
    end

    it "shows a reverted edit beside its shipped original once both are readable" do
      original = solve!("original", matched: true, judge_pick: "a")
      edited = solve!("edited", edit_check: true, shipped: false, edit_reverted: true, revert_reason: "solve_mismatch")
      review!
      login_as(admin)

      get admin_judge_solves_path

      shown = entry(edited)
      expect(shown.at_css(".original-prose").text).to include("Title original", "Scenario original", "Question original")
      expect(shown.at_css(".edited-prose").text).to include("Title edited")
      expect(shown.text).to include("Edit reverted: solve mismatch")
      expect(entry(original)).to be_nil
    end

    it "shows no original beside a reverted edit when the original is not readable" do
      edited = synthetic!("edited", edit_check: true, shipped: false, edit_reverted: true, revert_reason: "judge_rejected")
      login_as(admin)

      get admin_judge_solves_path(source: "synthetic", show: "reverts")

      expect(entry(edited).at_css(".original-prose")).to be_nil
    end

    it "links a live row to its replay and back" do
      live = solve!("same")
      replay = solve!("same", source: "replay", judge_pick: "a", matched: true)
      review!
      login_as(admin)

      get admin_judge_solves_path(source: "all", show: "all")

      live_link = entry(live).at_css(".counterpart a")["href"]
      replay_link = entry(replay).at_css(".counterpart a")["href"]
      expect(live_link).to end_with("##{ActionView::RecordIdentifier.dom_id(replay)}")
      expect(replay_link).to end_with("##{ActionView::RecordIdentifier.dom_id(live)}")
    end

    it "orders reverted edits first, then mismatches, newest first" do
      review!
      old_mismatch = solve!("old", created_at: 2.days.ago)
      matched = solve!("matched", matched: true, judge_pick: "a", created_at: 1.minute.ago)
      new_mismatch = solve!("new", created_at: 1.day.ago)
      reverted = solve!("rev", edit_check: true, shipped: false, edit_reverted: true, revert_reason: "judge_failed",
                               matched: nil, judge_pick: nil, judge_status: nil, created_at: 3.days.ago)
      login_as(admin)

      get admin_judge_solves_path(show: "all")

      ids = page.css("article.judge-solve").map { |node| node["id"] }
      expect(ids).to eq([ reverted, new_mismatch, old_mismatch, matched ].map { |s| ActionView::RecordIdentifier.dom_id(s) })
    end

    it "shows one placeholder and one withheld section for a hidden section with an edit, as for one without" do
      solve!("draft", shipped: false)
      solve!("edit", edit_check: true)
      plain_day = exercise_for(member, Date.yesterday)
      plain = solve!("plain", on: plain_day)
      login_as(admin)

      get admin_judge_solves_path(show: "all")

      expect(placeholders.size).to eq(2)
      expect(placeholders).to include(placeholder_text(plain))
      expect(withheld_line).to eq("Withheld pending review: 2")
    end

    it "caps the placeholders and says how many more are waiting" do
      stub_const("JudgeSolve::Listing::WAITING_LIMIT", 2)
      4.times { |offset| solve!("w#{offset}", on: exercise_for(member, Date.current - offset.days)) }
      login_as(admin)

      get admin_judge_solves_path

      expect(placeholders.size).to eq(2)
      expect(page.at_css(".waiting-more").text).to eq("and 2 more")
    end

    describe "paging" do
      before do
        stub_const("JudgeSolve::Listing::PAGE_SIZE", 2)
        review!
        3.times { |offset| solve!("p#{offset}", created_at: offset.minutes.ago) }
        login_as(admin)
      end

      def listed = page.css("article.judge-solve").size

      it "shows a fixed page of entries and links to the next with the filters kept" do
        get admin_judge_solves_path(source: "real")

        expect(listed).to eq(2)
        expect(page.at_css("nav.pagination a[rel='next']")["href"]).to eq(admin_judge_solves_path(source: "real", show: "mismatches", page: 2))

        get admin_judge_solves_path(source: "real", page: 2)

        expect(listed).to eq(1)
        expect(page.at_css("nav.pagination").text).to include("Page 2 of 2")
        expect(page.at_css("a[rel='prev']")["href"]).to eq(admin_judge_solves_path(source: "real", show: "mismatches"))
      end

      it "drops the page when a filter changes and reads an out-of-range page as the last" do
        get admin_judge_solves_path(page: 99)

        expect(listed).to eq(1)
        expect(page.css(".solve-filters a").map { |link| link["href"] }).to all(satisfy { |href| !href.include?("page=") })
      end
    end

    describe "filters" do
      let!(:live_mismatch) { solve!("live_mismatch") }
      let!(:live_matched) { solve!("live_matched", matched: true, judge_pick: "a", human_call: "key_right") }
      let!(:replay_mismatch) { solve!("replay_mismatch", source: "replay", human_call: "judge_right") }
      let!(:made_up) { synthetic!("synthetic") }
      let!(:reverted) do
        solve!("reverted", edit_check: true, shipped: false, edit_reverted: true, revert_reason: "judge_rejected",
                           matched: true, judge_pick: "a")
      end

      before do
        review!
        login_as(admin)
      end

      def listed = page.css("article.judge-solve").map { |node| node["id"] }

      def ids(*solves) = solves.map { |solve| ActionView::RecordIdentifier.dom_id(solve) }

      it "defaults to live mismatches and reverts" do
        get admin_judge_solves_path
        expect(listed).to eq(ids(reverted, live_mismatch))
      end

      it "reads source=real as live plus replay" do
        get admin_judge_solves_path(source: "real")
        expect(listed).to contain_exactly(*ids(reverted, live_mismatch, replay_mismatch))
      end

      it "reads source=replay, synthetic and all" do
        get admin_judge_solves_path(source: "replay")
        expect(listed).to eq(ids(replay_mismatch))

        get admin_judge_solves_path(source: "synthetic")
        expect(listed).to eq(ids(made_up))

        get admin_judge_solves_path(source: "all")
        expect(listed).to contain_exactly(*ids(reverted, live_mismatch, replay_mismatch, made_up))
      end

      it "reads show=reverts and show=all" do
        get admin_judge_solves_path(show: "reverts")
        expect(listed).to eq(ids(reverted))

        get admin_judge_solves_path(show: "all")
        expect(listed).to contain_exactly(*ids(reverted, live_mismatch, live_matched))
      end

      it "reads call=uncalled and each call value" do
        get admin_judge_solves_path(source: "all", show: "all", call: "uncalled")
        expect(listed).to contain_exactly(*ids(reverted, live_mismatch, made_up))

        get admin_judge_solves_path(source: "all", show: "all", call: "key_right")
        expect(listed).to eq(ids(live_matched))

        get admin_judge_solves_path(source: "all", show: "all", call: "judge_right")
        expect(listed).to eq(ids(replay_mismatch))
      end

      it "falls back to the defaults on unknown values" do
        get admin_judge_solves_path(source: "everything", show: "nonsense", call: "maybe")
        expect(listed).to eq(ids(reverted, live_mismatch))
      end
    end

    describe "show=matched_sample" do
      before { login_as(admin) }

      def sampled = page.css("article.judge-solve").map { |node| node["id"] }

      it "draws only readable, uncalled, solved, matched rows below principal engineer, from live and replay" do
        review!
        eligible_live = solve!("eligible_live", matched: true, judge_pick: "a")
        eligible_replay = solve!("eligible_replay", source: "replay", matched: true, judge_pick: "a")
        solve!("called", matched: true, judge_pick: "a", human_call: "key_right")
        solve!("mismatch")
        solve!("unsolved", matched: nil, judge_pick: nil, judge_status: nil)
        solve!("principal", matched: true, judge_pick: "a", rung: "principal_engineer")
        synthetic!("synthetic", matched: true, judge_pick: "a")
        unreviewed = exercise_for(member, Date.yesterday)
        solve!("hidden", on: unreviewed, matched: true, judge_pick: "a")

        get admin_judge_solves_path(source: "all", show: "matched_sample")

        expect(sampled).to contain_exactly(*[ eligible_live, eligible_replay ].map { |s| ActionView::RecordIdentifier.dom_id(s) })
        expect(response.body).not_to include("Deciding hidden")
        expect(page.css(".judge-solve-waiting")).to be_empty
      end

      it "draws nothing when the call filter names a call, and the usual sample for uncalled" do
        review!
        sampled_row = solve!("eligible", matched: true, judge_pick: "a")

        get admin_judge_solves_path(show: "matched_sample", call: "key_right")
        expect(sampled).to be_empty

        get admin_judge_solves_path(show: "matched_sample", call: "uncalled")
        expect(sampled).to eq([ ActionView::RecordIdentifier.dom_id(sampled_row) ])
      end

      it "respects n and clamps it" do
        review!
        4.times { |i| solve!("m#{i}", matched: true, judge_pick: "a") }

        get admin_judge_solves_path(show: "matched_sample", n: 2)
        expect(sampled.size).to eq(2)

        get admin_judge_solves_path(show: "matched_sample", n: 0)
        expect(sampled.size).to eq(1)

        get admin_judge_solves_path(show: "matched_sample", n: 10_000)
        expect(sampled.size).to eq(4)
      end
    end

    describe "header counts" do
      it "leaves hidden rows out of every count and counts them only on the withheld line" do
        solve!("hidden")
        solve!("hidden_matched", on: exercise_for(member, Date.yesterday), matched: true, judge_pick: "a")
        login_as(admin)

        get admin_judge_solves_path

        expect(withheld_line).to eq("Withheld pending review: 2")
        expect(page.css(".outcome-counts td[data-outcome], .revert-counts td[data-reason]").map(&:text)).to all(eq("0"))
        expect(page.css(".mismatch-calls td[data-source], .matched-calls td[data-source]").map(&:text)).to all(eq("0"))
      end

      it "counts readable rows by source and outcome" do
        review!
        solve!("a")
        solve!("b", source: "replay", matched: true, judge_pick: "a")
        login_as(admin)

        get admin_judge_solves_path

        live = page.at_css(".outcome-counts tr[data-source='live']")
        expect(live.at_css("td[data-outcome='mismatched']").text).to eq("1")
        expect(live.at_css("td[data-outcome='solved']").text).to eq("1")
        expect(page.at_css(".outcome-counts tr[data-source='replay'] td[data-outcome='matched']").text).to eq("1")
        expect(withheld_line).to eq("Withheld pending review: 0")
      end
    end
  end

  describe "PATCH /admin/judge_solves/:id" do
    let(:row) { solve!("patched") }

    it "redirects a non-admin and saves nothing" do
      review!
      login_as(member)

      patch admin_judge_solve_path(row), params: { judge_solve: { human_call: "key_right" } }

      expect(response).to redirect_to(root_path)
      expect(row.reload.human_call).to be_nil
    end

    it "returns 404 for a hidden row and saves nothing" do
      login_as(admin)

      patch admin_judge_solve_path(row), params: { judge_solve: { human_call: "key_right", human_note: "x" } }

      expect(response).to have_http_status(:not_found)
      expect(row.reload).to have_attributes(human_call: nil, human_note: nil, human_called_at: nil)
    end

    it "saves each mismatch call and the note, stamping the time, and keeps the filters" do
      review!
      login_as(admin)

      JudgeSolve::MISMATCH_CALLS.each do |call|
        patch admin_judge_solve_path(row, source: "real", show: "all"), params: { judge_solve: { human_call: call, human_note: "because" } }

        expect(row.reload).to have_attributes(human_call: call, human_note: "because")
        expect(row.human_called_at).to be_within(5.seconds).of(Time.current)
        expect(response).to redirect_to(admin_judge_solves_path(source: "real", show: "all", anchor: ActionView::RecordIdentifier.dom_id(row)))
        expect(flash[:notice]).to eq("Call saved.")
      end
    end

    it "saves each matched call on a matched row and refuses judge_right there" do
      matched = solve!("matched", matched: true, judge_pick: "a")
      review!
      login_as(admin)

      JudgeSolve::MATCHED_CALLS.each do |call|
        patch admin_judge_solve_path(matched), params: { judge_solve: { human_call: call } }
        expect(matched.reload.human_call).to eq(call)
      end

      patch admin_judge_solve_path(matched), params: { judge_solve: { human_call: "judge_right" } }

      expect(matched.reload.human_call).to eq(JudgeSolve::MATCHED_CALLS.last)
      expect(flash[:alert]).to eq("That call doesn't fit this record. Nothing was saved.")
    end

    it "refuses both_wrong on a mismatched row and any unknown value" do
      review!
      login_as(admin)

      %w[both_wrong made_up].each do |call|
        patch admin_judge_solve_path(row), params: { judge_solve: { human_call: call } }
        expect(row.reload.human_call).to be_nil
      end
    end

    it "ignores every attribute other than the call and the note" do
      review!
      login_as(admin)

      patch admin_judge_solve_path(row), params: { judge_solve: { human_call: "key_right", judge_pick: "a", matched: true,
                                                                  key_better: "b", shipped: false, source: "replay" } }

      expect(row.reload).to have_attributes(human_call: "key_right", judge_pick: "b", matched: false, key_better: "a",
                                            shipped: true, source: "live")
    end

    it "clears the call when the blank option is chosen, stamping the time" do
      row.update_columns(human_call: "key_right", human_called_at: 2.days.ago)
      review!
      login_as(admin)

      patch admin_judge_solve_path(row), params: { judge_solve: { human_call: "", human_note: "" } }

      expect(row.reload).to have_attributes(human_call: nil, human_note: nil)
      expect(row.human_called_at).to be_within(5.seconds).of(Time.current)
    end

    it "leaves the call time alone on a note-only save" do
      called_at = 2.days.ago.change(usec: 0)
      row.update_columns(human_call: "key_right", human_called_at: called_at)
      review!
      login_as(admin)

      patch admin_judge_solve_path(row), params: { judge_solve: { human_call: "key_right", human_note: "second look" } }

      expect(row.reload).to have_attributes(human_call: "key_right", human_note: "second look", human_called_at: called_at)
    end

    it "keeps the page in the redirect" do
      stub_const("JudgeSolve::Listing::PAGE_SIZE", 1)
      solve!("other", created_at: 1.day.ago)
      review!
      login_as(admin)

      patch admin_judge_solve_path(row, page: 2), params: { judge_solve: { human_call: "key_right" } }

      expect(response).to redirect_to(admin_judge_solves_path(source: "live", show: "mismatches", page: 2,
                                                              anchor: ActionView::RecordIdentifier.dom_id(row)))
    end
  end
end
