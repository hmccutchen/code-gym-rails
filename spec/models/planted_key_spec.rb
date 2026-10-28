require "rails_helper"

RSpec.describe PlantedKey do
  describe ".text" do
    it "strips a string and bounds it, and gives nil for a blank or a non-string" do
      aggregate_failures do
        expect(described_class.text("  `find_each` loads in batches  ")).to eq("`find_each` loads in batches")
        expect(described_class.text("x" * (described_class::MAX_LENGTH + 50)).length).to eq(described_class::MAX_LENGTH)
        expect(described_class.text("   ")).to be_nil
        expect(described_class.text(nil)).to be_nil
        expect(described_class.text(42)).to be_nil
        expect(described_class.text([ "issue" ])).to be_nil
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
        expect(described_class.unquoted_parts([ "`current_user.update(params[:user])` assigns everything" ], within: [ code ])).to eq([])
        expect(described_class.unquoted_parts([ "`current_user.update(   params[:user])`" ], within: [ "current_user.update(\n params[:user])" ])).to eq([])
        expect(described_class.unquoted_parts([ "`update!(params)` and `current_user`" ], within: [ code ])).to eq([ "update!(params)" ])
      end
    end

    it "counts a text with no backticked quote as one unquoted part" do
      expect(described_class.unquoted_parts([ "The update assigns everything.", "`current_user`" ], within: [ code ]).size).to eq(1)
    end

    it "reads every text it is given, and ignores a missing one" do
      expect(described_class.unquoted_parts([ "`nope`", nil ], within: [ code, nil ])).to eq([ "nope" ])
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
