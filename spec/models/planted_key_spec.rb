require "rails_helper"

RSpec.describe PlantedKey do
  describe ".text" do
    it "strips a string and keeps it whole, and gives nil for a blank or a non-string" do
      aggregate_failures do
        expect(described_class.text("  `find_each` loads in batches  ")).to eq("`find_each` loads in batches")
        expect(described_class.text("x" * (described_class::MAX_LENGTH + 50)).length).to eq(described_class::MAX_LENGTH + 50)
        expect(described_class.text("   ")).to be_nil
        expect(described_class.text(nil)).to be_nil
        expect(described_class.text(42)).to be_nil
        expect(described_class.text([ "issue" ])).to be_nil
      end
    end
  end

  describe ".too_long?" do
    it "is true when any text in a cleaned key, however nested, runs past the limit" do
      long = "x" * (described_class::MAX_LENGTH + 1)

      aggregate_failures do
        expect(described_class.too_long?({ "issue" => "x" * described_class::MAX_LENGTH })).to be(false)
        expect(described_class.too_long?({ "issue" => "a", "fix" => long })).to be(true)
        expect(described_class.too_long?({ "flaws" => [ { "flaw" => "a", "pushback" => long } ] })).to be(true)
        expect(described_class.too_long?({ "missable_requirements" => [ "a", long ] })).to be(true)
        expect(described_class.too_long?(nil)).to be(false)
      end
    end
  end

  describe ".list" do
    it "maps each entry through the block, drops what comes back nil and keeps at most max" do
      list = described_class.list([ " a ", "", 3, "b", "c" ], max: 2) { |entry| described_class.text(entry) }

      expect(list).to eq(%w[a b])
    end

    it "gives an empty list for anything that isn't a list" do
      expect(described_class.list("a", max: 3) { |entry| entry }).to eq([])
      expect(described_class.list(nil, max: 3) { |entry| entry }).to eq([])
    end
  end

  describe ".fields" do
    it "keeps the named fields, cleaned, and gives nil unless every one survives" do
      key = { "issue" => " `user.posts` per row ", "fix" => "Preload them.", "extra" => "dropped" }

      expect(described_class.fields(key, %w[issue fix])).to eq("issue" => "`user.posts` per row", "fix" => "Preload them.")
      expect(described_class.fields(key.merge("fix" => " "), %w[issue fix])).to be_nil
      expect(described_class.fields("not a hash", %w[issue fix])).to be_nil
    end
  end

  describe ".unquoted_parts" do
    let(:code) { "def update\n  current_user.update(params[:user])\nend" }

    it "returns each backticked quote not found in the text, with whitespace collapsed on both sides" do
      aggregate_failures do
        expect(described_class.unquoted_parts([ "`current_user.update(params[:user])` assigns everything" ], within: [ code ], language: "ruby_rails")).to eq([])
        expect(described_class.unquoted_parts([ "`current_user.update(   params[:user])`" ], within: [ "current_user.update(\n params[:user])" ], language: "ruby_rails")).to eq([])
        expect(described_class.unquoted_parts([ "`update!(params)` and `current_user`" ], within: [ code ], language: "ruby_rails")).to eq([ "update!(params)" ])
      end
    end

    it "ignores whitespace entirely, since formatting adds spaces the provider never wrote" do
      expect(described_class.unquoted_parts([ "`{a: 1}` and `x+1`" ], within: [ "{ a: 1 }\ny = x + 1" ], language: "ruby_rails")).to eq([])
    end

    it "leaves a quote under three non-space characters unchecked, so a stray `.` neither passes nor fails" do
      expect(described_class.unquoted_parts([ "`.` then `ab`" ], within: [ "nothing here" ], language: "ruby_rails")).to eq([])
      expect(described_class.unquoted_parts([ "`.` then `abc`" ], within: [ "nothing here" ], language: "ruby_rails")).to eq([ "abc" ])
    end

    it "counts a text with no backticked quote as one unquoted part" do
      expect(described_class.unquoted_parts([ "The update assigns everything.", "`current_user`" ], within: [ code ], language: "ruby_rails").size).to eq(1)
    end

    it "reads every text it is given, and ignores a missing one" do
      expect(described_class.unquoted_parts([ "`nope`", nil ], within: [ code, nil ], language: "ruby_rails")).to eq([ "nope" ])
    end

    it "matches a quote that differs from the code only by a trailing comma" do
      expect(described_class.unquoted_parts([ "`timeout: 5,`" ], within: [ "call(timeout: 5)" ], language: "ruby_rails")).to eq([])
    end

    it "applies the JavaScript rules when the language is JavaScript" do
      quote = [ "`return ids.map(id=>fetch(id))`" ]
      code = [ "return ids.map((id) => fetch(id));" ]

      expect(described_class.unquoted_parts(quote, within: code, language: "javascript")).to eq([])
      expect(described_class.unquoted_parts(quote, within: code, language: "ruby_rails")).to eq([ "return ids.map(id=>fetch(id))" ])
    end
  end

  describe ".store!" do
    it "writes a cleaned key back to the section, or deletes the key and keeps the section" do
      section = { "snippet" => "code", described_class::FIELD => { "issue" => " raw " } }

      described_class.store!(section, { "issue" => "raw" })
      expect(section).to eq("snippet" => "code", described_class::FIELD => { "issue" => "raw" })

      described_class.store!(section, nil)
      expect(section).to eq("snippet" => "code")
    end
  end
end
