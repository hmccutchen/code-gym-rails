require "rails_helper"

RSpec.describe "Profile", type: :request do
  let(:user) { create_user_with_key }

  describe "PATCH /profile" do
    it "requires login" do
      patch profile_path, params: { user: { name: "New" } }
      expect(response).to redirect_to(login_path)
    end

    it "updates the name and returns it as JSON" do
      login_as(user)

      patch profile_path,
            params: { user: { name: "  Renamed  " } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("name" => "Renamed", "time_zone" => "UTC", "adaptive_set_size" => true)
      expect(user.reload.name).to eq("Renamed")
    end

    it "rejects a blank name without changing the record" do
      login_as(user)
      original = user.name

      patch profile_path,
            params: { user: { name: "   " } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["errors"]).to be_present
      expect(user.reload.name).to eq(original)
    end

    it "updates the time_zone and returns 200" do
      login_as(user)
      patch profile_path,
            params: { user: { time_zone: "America/Los_Angeles" } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(user.reload.time_zone).to eq("America/Los_Angeles")
    end

    it "strips surrounding whitespace from a time_zone before validating" do
      login_as(user)
      patch profile_path,
            params: { user: { time_zone: "  America/Los_Angeles  " } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(user.reload.time_zone).to eq("America/Los_Angeles")
    end

    it "stores a blank time_zone as nil (leaves it to auto-detect)" do
      user.update!(time_zone: "America/Chicago")
      login_as(user)
      patch profile_path,
            params: { user: { time_zone: "" } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(user.reload.time_zone).to be_nil
    end

    it "rejects an invalid time_zone with 422 and no change" do
      user.update!(time_zone: "America/Chicago")
      login_as(user)
      patch profile_path,
            params: { user: { time_zone: "Mars/Phobos" } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.time_zone).to eq("America/Chicago")
    end

    def patch_profile(payload)
      patch profile_path,
            params: { user: payload }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    it "stores stated weights and exclusions" do
      login_as(user)

      patch_profile(section_kind_weights: { "challenge" => 0.25 }, excluded_section_kinds: [ "parsons_problem" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.section_kind_weights).to eq("challenge" => 0.25)
      expect(user.excluded_section_kinds).to eq([ "parsons_problem" ])
    end

    # Active Record's cast is too forgiving for a request boundary — the same
    # reasoning as BOOLEAN_VALUES above it.
    it "rejects a weight sent as a string" do
      login_as(user)

      patch_profile(section_kind_weights: { "challenge" => "0.25" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.section_kind_weights).to eq({})
    end

    it "rejects a weight that is not one of the stops" do
      login_as(user)

      patch_profile(section_kind_weights: { "challenge" => 3 })

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.section_kind_weights).to eq({})
    end

    it "refuses an exclusion that would empty a slot" do
      login_as(user)

      patch_profile(excluded_section_kinds: ExerciseSection.thirds.map(&:key))

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.excluded_section_kinds).to eq([])
    end

    # A wrong-shaped value used to read as blank, get dropped by strong
    # parameters, and come back 200 having applied nothing — a success status
    # for a write that did not happen.
    it "rejects a present-but-wrong-shaped preference rather than reporting success" do
      login_as(user)
      user.update!(section_kind_weights: { "challenge" => 4.0 }, excluded_section_kinds: [ "parsons_problem" ])

      [ { section_kind_weights: [] }, { section_kind_weights: nil },
        { excluded_section_kinds: {} }, { excluded_section_kinds: nil } ].each do |payload|
        patch_profile(payload)

        expect(response).to have_http_status(:unprocessable_content), "expected 422 for #{payload.inspect}"
      end

      expect(user.reload.section_kind_weights).to eq("challenge" => 4.0)
      expect(user.excluded_section_kinds).to eq([ "parsons_problem" ])
    end

    describe "the stale-tab precondition" do
      def version = user.reload.section_kind_preferences_version

      it "accepts two saves in order when each posts the version it last saw" do
        login_as(user)

        patch_profile(section_kind_weights: { "challenge" => 0.25 },
                      section_kind_preferences_version: version)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["section_kind_preferences_version"]).to eq(version)

        patch_profile(section_kind_weights: { "challenge" => 2.0 },
                      section_kind_preferences_version: version)
        expect(response).to have_http_status(:ok)
        expect(user.reload.section_kind_weights).to eq("challenge" => 2.0)
      end

      # The two-tab clobber this exists to stop: tab B posts the version it read
      # before tab A saved, so its write is refused rather than silently
      # replacing A's.
      it "refuses a save posting a version that has moved on, and writes nothing" do
        login_as(user)
        stale = version

        patch_profile(section_kind_weights: { "challenge" => 4.0 },
                      section_kind_preferences_version: stale)
        expect(response).to have_http_status(:ok)

        patch_profile(section_kind_weights: { "architecture" => 0.5 },
                      section_kind_preferences_version: stale)

        expect(response).to have_http_status(:conflict)
        expect(user.reload.section_kind_weights).to eq("challenge" => 4.0)
        expect(response.parsed_body.dig("current", "section_kind_weights")).to eq("challenge" => 4.0)
        expect(response.parsed_body.dig("current", "section_kind_preferences_version")).to eq(version)
      end

      # The specific bug a whole-row updated_at would reintroduce: an unrelated
      # field shares the row, so a coarse stamp would move and refuse a mix save
      # that nothing had raced.
      it "does not treat an unrelated field's save as a conflict" do
        login_as(user)
        held = version

        patch_profile(time_zone: "America/Los_Angeles")
        expect(response).to have_http_status(:ok)
        expect(user.reload.time_zone).to eq("America/Los_Angeles")

        patch_profile(section_kind_weights: { "challenge" => 0.5 },
                      section_kind_preferences_version: held)

        expect(response).to have_http_status(:ok)
        expect(user.reload.section_kind_weights).to eq("challenge" => 0.5)
      end

      # Absent version means no precondition, the way an absent If-Match does.
      it "applies a save that posts no version at all" do
        login_as(user)
        user.update!(section_kind_weights: { "challenge" => 4.0 })

        patch_profile(section_kind_weights: { "architecture" => 2.0 })

        expect(response).to have_http_status(:ok)
        expect(user.reload.section_kind_weights).to eq("architecture" => 2.0)
      end

      it "leaves the body untouched for a caller that changes no preferences" do
        login_as(user)

        patch_profile(name: "Renamed")

        expect(response.parsed_body.keys).to contain_exactly("name", "time_zone", "adaptive_set_size")
      end

      # Deliberate coupling: weights and difficulty share one version, so a
      # stale tab is refused whichever half it touched.
      it "refuses a lock save from a tab that missed another tab's weight save" do
        login_as(user)
        stale = version

        patch_profile(section_kind_weights: { "challenge" => 4.0 }, section_kind_preferences_version: stale)
        expect(response).to have_http_status(:ok)

        patch_profile(section_kind_levels: { "challenge" => "senior" }, locked_section_kinds: [ "challenge" ],
                      section_kind_preferences_version: stale)

        expect(response).to have_http_status(:conflict)
        expect(user.reload.locked_section_kinds).to eq([])
        expect(response.parsed_body["current"]).to include("section_kind_levels" => {}, "locked_section_kinds" => [])
      end

      it "reports the version after a difficulty-only save" do
        login_as(user)

        patch_profile(section_kind_levels: { "pattern" => "junior" }, section_kind_preferences_version: version)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["section_kind_preferences_version"]).to eq(version)
      end
    end

    # Writes replace rather than merge, so returning a slider to its default is
    # expressed by the key being absent — one representation of default, not two.
    it "replaces the stored preferences rather than merging into them" do
      login_as(user)
      user.update!(section_kind_weights: { "challenge" => 0.25, "architecture" => 2.0 })

      patch_profile(section_kind_weights: { "architecture" => 2.0 })

      expect(response).to have_http_status(:ok)
      expect(user.reload.section_kind_weights).to eq("architecture" => 2.0)
    end

    # Every slider back to Default, or the last exclusion unchecked — the full
    # reset a user actually performs, distinct from the smaller-replaces-larger
    # case above.
    it "clears previously-stored preferences on a full reset" do
      login_as(user)
      user.update!(section_kind_weights: { "challenge" => 0.25 }, excluded_section_kinds: [ "parsons_problem" ])

      patch_profile(section_kind_weights: {}, excluded_section_kinds: [])

      expect(response).to have_http_status(:ok)
      expect(user.reload.section_kind_weights).to eq({})
      expect(user.excluded_section_kinds).to eq([])
    end

    # permit(excluded_section_kinds: []) silently drops a non-scalar entry
    # rather than raising, so without this guard the malformed payload below
    # would arrive as [] and clear the user's existing exclusions with a 200.
    it "rejects an exclusion list containing a non-string entry" do
      login_as(user)
      user.update!(excluded_section_kinds: [ "parsons_problem" ])

      patch_profile(excluded_section_kinds: [ { "a" => 1 } ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.excluded_section_kinds).to eq([ "parsons_problem" ])
    end

    it "stores stated levels and locks, including for code_review" do
      login_as(user)

      patch_profile(section_kind_levels: { "code_review" => "senior", "challenge" => "junior" },
                    locked_section_kinds: [ "challenge" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.section_kind_levels).to eq("code_review" => "senior", "challenge" => "junior")
      expect(user.locked_section_kinds).to eq([ "challenge" ])
    end

    it "rejects a level outside the vocabulary" do
      login_as(user)

      patch_profile(section_kind_levels: { "challenge" => "strong" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].join).to include("junior, senior, principal_engineer")
      expect(user.reload.section_kind_levels).to eq({})
    end

    it "rejects a lock with no level" do
      login_as(user)

      patch_profile(locked_section_kinds: [ "challenge" ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.locked_section_kinds).to eq([])
    end

    it "rejects a present-but-wrong-shaped difficulty preference rather than reporting success" do
      login_as(user)
      user.update!(section_kind_levels: { "challenge" => "senior" }, locked_section_kinds: [ "challenge" ])

      [ { section_kind_levels: [] }, { section_kind_levels: nil }, { section_kind_levels: { "challenge" => 1 } },
        { locked_section_kinds: {} }, { locked_section_kinds: nil }, { locked_section_kinds: [ { "a" => 1 } ] } ].each do |payload|
        patch_profile(payload)

        expect(response).to have_http_status(:unprocessable_content), "expected 422 for #{payload.inspect}"
      end

      expect(user.reload.section_kind_levels).to eq("challenge" => "senior")
      expect(user.locked_section_kinds).to eq([ "challenge" ])
    end

    it "clears every level and lock on empty values" do
      login_as(user)
      user.update!(section_kind_levels: { "challenge" => "senior" }, locked_section_kinds: [ "challenge" ])

      patch_profile(section_kind_levels: {}, locked_section_kinds: [])

      expect(response).to have_http_status(:ok)
      expect(user.reload.section_kind_levels).to eq({})
      expect(user.locked_section_kinds).to eq([])
    end
  end

  describe "PATCH /profile with the adaptive set size preference" do
    it "saves the preference and echoes it back" do
      login_as(user)

      patch profile_path,
            params: { user: { adaptive_set_size: false } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["adaptive_set_size"]).to be(false)
      expect(user.reload.adaptive_set_size).to be(false)
    end

    # The column is NOT NULL and Active Record's cast turns "" and null into
    # nil, so without a boundary check these are a 500 rather than a rejection.
    it "rejects a value that is not a boolean instead of crashing or guessing" do
      login_as(user)

      [ nil, "", "banana", 2 ].each do |value|
        patch profile_path,
              params: { user: { adaptive_set_size: value } }.to_json,
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

        expect(response).to have_http_status(:unprocessable_content), "#{value.inspect} was accepted"
        expect(user.reload.adaptive_set_size).to be(true)
      end
    end

    it "still accepts the string forms a form post would send" do
      login_as(user)

      patch profile_path,
            params: { user: { adaptive_set_size: "0" } }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(user.reload.adaptive_set_size).to be(false)
    end
  end
end
