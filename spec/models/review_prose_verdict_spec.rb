require "rails_helper"

RSpec.describe ReviewProseVerdict do
  let(:review) do
    { "rating" => "solid", "correct" => [ "Preloads the association." ],
      "missed" => [ "The loop queries once per row.", "Each row runs its own query.", "No index on user_id." ],
      "better_questions" => [], "next_step" => "Read about includes and eager_load.",
      "improved_code" => "User.includes(:posts)", "difficulty" => { "level" => "moderate" } }
  end
  let(:projection) { described_class.project(review) }

  def edit(fields, issues = [ { "type" => "verbosity", "evidence" => "Each row runs its own query." } ])
    { "status" => "edit", "issues" => issues, "fields" => fields }
  end

  def parse(raw) = described_class.parse(raw, projection: projection)

  describe ".project" do
    it "takes its fields and their shapes from AI_REVIEW_FIELDS" do
      expect(projection.keys).to eq(DailyResponse::AI_REVIEW_FIELDS.keys)
    end

    it "reads a string list field as one entry, nil as empty, and joins an array-valued text field" do
      projected = described_class.project("correct" => "  One point. ", "missed" => nil,
                                          "next_step" => [ "Study transactions", "" ])
      expect(projected).to eq("correct" => [ "One point." ], "missed" => [], "better_questions" => [],
                              "next_step" => "Study transactions")
    end
  end

  describe ".parse" do
    it "parses keep" do
      expect(parse("status" => "keep").status).to eq(:keep)
    end

    it "accepts a merge of non-adjacent entries placed at its earliest source" do
      verdict = parse(edit("missed" => [ { "from" => [ 0, 1 ], "text" => "Each row runs its own query." },
                                         { "from" => [ 2 ], "text" => "user_id has no index." } ]))
      expect(verdict.merges).to eq("missed" => [ [ 0, 1 ] ])
    end

    it "accepts [0,2] then [1]" do
      expect(parse(edit("missed" => [ { "from" => [ 0, 2 ], "text" => "a" }, { "from" => [ 1 ], "text" => "b" } ])).edit?).to be(true)
    end

    it "accepts an unmerged rewrite with a plain-language issue alone" do
      verdict = parse(edit({ "next_step" => "Read about includes." }, [ { "type" => "plain_language_violation", "evidence" => "eager_load" } ]))
      expect(verdict.fields).to eq("next_step" => "Read about includes.")
    end

    {
      "a non-object" => [],
      "an unknown status" => { "status" => "reject" },
      "an edit with no issues" => { "status" => "edit", "issues" => [], "fields" => { "next_step" => "x" } },
      "issues that are not a list" => { "status" => "edit", "issues" => { "type" => "verbosity" }, "fields" => { "next_step" => "x" } },
      "an unknown issue type" => { "status" => "edit", "issues" => [ { "type" => "tone", "evidence" => "x" } ], "fields" => { "next_step" => "x" } },
      "blank evidence" => { "status" => "edit", "issues" => [ { "type" => "verbosity", "evidence" => " " } ], "fields" => { "next_step" => "x" } },
      "empty fields" => { "status" => "edit", "issues" => [ { "type" => "verbosity", "evidence" => "x" } ], "fields" => {} }
    }.each do |name, raw|
      it "refuses #{name}" do
        expect { parse(raw) }.to raise_error(described_class::Invalid)
      end
    end

    it "refuses a non-prose field, so the rating and code can never be rewritten" do
      %w[rating improved_code difficulty].each do |field|
        expect { parse(edit(field => "x")) }.to raise_error(described_class::Invalid)
      end
    end

    # An empty field has nothing to cite, so a rewrite of it is invented.
    it "drops a rewrite of an empty field and keeps the rest of the edit" do
      verdict = parse(edit("better_questions" => [ { "from" => [ 0 ], "text" => "invented" } ],
                           "next_step" => "Read about includes."))

      expect(verdict.fields).to eq("next_step" => "Read about includes.")
      expect(verdict.apply(review)["better_questions"]).to eq([])
    end

    it "drops an empty field's rewrite without judging its shape" do
      verdict = parse(edit("better_questions" => "not even a list", "next_step" => "Read about includes."))

      expect(verdict.fields).to eq("next_step" => "Read about includes.")
    end

    it "reads an edit whose only rewrites were of empty fields as keep" do
      verdict = parse(edit("better_questions" => [ { "from" => [ 0 ], "text" => "invented" } ]))

      expect(verdict.status).to eq(:keep)
      expect(verdict.apply(review)).to equal(review)
    end

    it "refuses a dropped, duplicated, out-of-range, empty or non-integer index" do
      [
        [ { "from" => [ 0 ], "text" => "a" }, { "from" => [ 1 ], "text" => "b" } ],
        [ { "from" => [ 0, 1 ], "text" => "a" }, { "from" => [ 1, 2 ], "text" => "b" } ],
        [ { "from" => [ 0, 1, 2, 3 ], "text" => "a" } ],
        [ { "from" => [], "text" => "a" }, { "from" => [ 0, 1, 2 ], "text" => "b" } ],
        [ { "from" => [ "0" ], "text" => "a" }, { "from" => [ 1, 2 ], "text" => "b" } ]
      ].each do |entries|
        expect { parse(edit("missed" => entries)) }.to raise_error(described_class::Invalid)
      end
    end

    context "when every prose field of the graded review is empty" do
      let(:review) { { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => nil } }

      it "parses keep" do
        expect(parse("status" => "keep").status).to eq(:keep)
      end

      it "drops a rewrite of next_step, storing nothing invented" do
        verdict = parse(edit("next_step" => "Read about includes."))

        expect(verdict.status).to eq(:keep)
        expect(verdict.apply(review)).to equal(review)
      end

      it "drops an empty-string rewrite of next_step the same way" do
        expect(parse(edit("next_step" => "")).status).to eq(:keep)
      end
    end

    it "refuses entries out of earliest-position order, or a descending from" do
      expect { parse(edit("missed" => [ { "from" => [ 1 ], "text" => "b" }, { "from" => [ 0, 2 ], "text" => "a" } ])) }
        .to raise_error(described_class::Invalid)
      expect { parse(edit("missed" => [ { "from" => [ 2, 0 ], "text" => "a" }, { "from" => [ 1 ], "text" => "b" } ])) }
        .to raise_error(described_class::Invalid)
    end

    it "refuses a merge without a verbosity issue" do
      raw = edit({ "missed" => [ { "from" => [ 0, 1 ], "text" => "a" }, { "from" => [ 2 ], "text" => "b" } ] },
                 [ { "type" => "plain_language_violation", "evidence" => "x" } ])
      expect { parse(raw) }.to raise_error(described_class::Invalid)
    end

    it "refuses blank or non-string rewritten text" do
      expect { parse(edit("next_step" => " ")) }.to raise_error(described_class::Invalid)
      expect { parse(edit("next_step" => [ "a" ])) }.to raise_error(described_class::Invalid)
      expect { parse(edit("missed" => [ { "from" => [ 0, 1, 2 ], "text" => "" } ])) }.to raise_error(described_class::Invalid)
    end

    it "never quotes provider text in its messages" do
      expect { parse("status" => "SENTINEL-1") }.to raise_error(described_class::Invalid) { |e| expect(e.message).not_to include("SENTINEL") }
      expect { parse(edit("SENTINEL-2" => "x")) }.to raise_error(described_class::Invalid) { |e| expect(e.message).not_to include("SENTINEL") }
    end
  end

  describe "#apply" do
    let(:verdict) do
      parse(edit("missed" => [ { "from" => [ 0, 1 ], "text" => "Each row runs its own query." },
                               { "from" => [ 2 ], "text" => "user_id has no index." } ]))
    end

    it "rewrites the named field and leaves every protected and unnamed field untouched" do
      applied = verdict.apply(review)
      expect(applied["missed"]).to eq([ "Each row runs its own query.", "user_id has no index." ])
      expect(applied.slice("rating", "improved_code", "difficulty", "correct", "next_step"))
        .to eq(review.slice("rating", "improved_code", "difficulty", "correct", "next_step"))
    end

    it "keeps every prose field exactly as graded under graded_prose" do
      raw_review = review.merge("correct" => "A string list field.", "better_questions" => nil)
      expect(verdict.apply(raw_review)[described_class::ORIGINAL_KEY])
        .to eq(raw_review.slice(*DailyResponse::AI_REVIEW_FIELDS.keys))
    end

    it "stores a rewritten string list field as an array" do
      stringy = review.merge("correct" => "One long point.")
      verdict = described_class.parse(edit({ "correct" => [ { "from" => [ 0 ], "text" => "One point." } ] },
                                           [ { "type" => "verbosity", "evidence" => "long" } ]),
                                      projection: described_class.project(stringy))
      expect(verdict.apply(stringy)["correct"]).to eq([ "One point." ])
    end

    it "returns the review unchanged on keep" do
      expect(parse("status" => "keep").apply(review)).to equal(review)
    end
  end

  describe ".schema" do
    let(:shapes) { described_class.schema.fetch("anyOf").index_by { |shape| shape.dig("properties", "status", "const") } }

    def objects_in(node)
      return [] unless node.is_a?(Hash) || node.is_a?(Array)
      own = node.is_a?(Hash) && node["type"] == "object" ? [ node ] : []
      own + (node.is_a?(Hash) ? node.values : node).flat_map { |child| objects_in(child) }
    end

    it "offers one shape per status and draws issue types from the closed list" do
      expect(shapes.keys).to eq(described_class::STATUSES)
      expect(shapes["edit"].dig("properties", "issues", "items", "properties", "type", "enum")).to eq(described_class::ISSUE_TYPES)
    end

    it "offers exactly the prose fields, lists as cited entries, none required" do
      fields = shapes["edit"].dig("properties", "fields")
      expect(fields["properties"].keys).to eq(DailyResponse::AI_REVIEW_FIELDS.keys)
      expect(fields["required"]).to eq([])
      expect(fields.dig("properties", "missed", "items", "properties", "from", "items")).to eq("type" => "integer")
      expect(fields.dig("properties", "next_step")).to eq("type" => "string")
    end

    it "closes every object" do
      expect(objects_in(described_class.schema)).to all(include("additionalProperties" => false))
    end
  end
end
