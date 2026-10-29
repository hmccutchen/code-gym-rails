require "rails_helper"

RSpec.describe ExerciseSection::CodeReview do
  describe ".reject_unusable!" do
    def snippet_of(count) = Array.new(count) { |index| "line_#{index} = #{index}" }.join("\n")

    it "accepts a snippet at the line cap" do
      expect { described_class.reject_unusable!({ "snippet" => snippet_of(described_class::MAX_SNIPPET_LINES) }) }.not_to raise_error
    end

    it "refuses a snippet past the line cap, naming its length and none of its code" do
      expect { described_class.reject_unusable!({ "snippet" => snippet_of(described_class::MAX_SNIPPET_LINES + 1) }) }
        .to raise_error(ProviderError::InvalidResponseError) { |error|
          expect(error.message).to include("#{described_class::MAX_SNIPPET_LINES + 1} lines")
          expect(error.message).not_to include("line_0")
        }
    end

    it "counts the lines shown, not the blank ones between them" do
      spaced = Array.new(described_class::MAX_SNIPPET_LINES, "x = 1").join("\n\n")

      expect { described_class.reject_unusable!({ "snippet" => spaced }) }.not_to raise_error
    end

    it "refuses a missing, blank or non-string snippet" do
      [ nil, "  \n ", 42 ].each do |value|
        expect { described_class.reject_unusable!({ "snippet" => value }) }
          .to raise_error(ProviderError::InvalidResponseError, /snippet/), "accepted #{value.inspect}"
      end
    end

    it "accepts every curated real-source excerpt as formatted, since a grounded snippet keeps its excerpt's shape" do
      allow(CodeFormat).to receive(:all).and_call_original
      formatted = CodeFormat.all(RealSource.all.map(&:text), language: RealSource::LANGUAGE)

      formatted.each { |snippet| expect { described_class.reject_unusable!({ "snippet" => snippet }) }.not_to raise_error }
    end
  end
end

RSpec.describe ExerciseSection::CodeReview, "multi-file sections" do
  def numbered(name, count) = Array.new(count) { |index| "#{name}_#{index} = #{index}" }.join("\n")

  def file_fields(number, path:, code:, changed:)
    { "file_#{number}_path" => path, "file_#{number}_code" => code, "file_#{number}_changed" => changed }
  end

  def two_files(first_lines: 3, second_lines: 3)
    file_fields(1, path: "app/models/order.rb", code: numbered("order", first_lines), changed: [ "order_0 = 0" ])
      .merge(file_fields(2, path: "app/models/item.rb", code: numbered("item", second_lines), changed: [ "item_1 = 1" ]))
  end

  def third_file(lines: 3, path: "app/models/cart.rb")
    file_fields(3, path: path, code: numbered("cart", lines), changed: [ "cart_0 = 0" ])
  end

  def refusal_for(section, file_range: 2..3, language: "ruby_rails")
    described_class.reject_unusable!(section, language: language, file_range: file_range)
    nil
  rescue ProviderError::UnusableSectionError => e
    e
  end

  def code_for(section, **) = refusal_for(section, **)&.code

  describe ".files" do
    it "returns each complete file in order, with its changed lines once they are line numbers" do
      section = two_files.merge("file_1_changed" => [ 1, 3 ], "file_2_changed" => [ "item_1 = 1" ])

      expect(described_class.files(section)).to eq([
        described_class::File.new(path: "app/models/order.rb", code: numbered("order", 3), changed: [ 1, 3 ]),
        described_class::File.new(path: "app/models/item.rb", code: numbered("item", 3), changed: [])
      ])
    end

    it "skips a file missing its path or code" do
      section = two_files.merge("file_2_path" => " ", "file_3_code" => "x = 1")

      expect(described_class.files(section).map(&:path)).to eq([ "app/models/order.rb" ])
    end

    it "returns nothing for a single-file section" do
      expect(described_class.files({ "snippet" => "x = 1" })).to eq([])
    end
  end

  describe ".reject_unusable! on a multi-file range" do
    it "accepts two or three complete files with a resolved changed line" do
      expect(code_for(two_files)).to be_nil
      expect(code_for(two_files.merge(third_file))).to be_nil
    end

    it "refuses a file count outside the range" do
      expect(code_for(two_files, file_range: 2..2)).to be_nil
      expect(code_for(two_files.merge(third_file), file_range: 2..2)).to eq("code_review.file_count_wrong")
      expect(code_for(two_files.except("file_2_path", "file_2_code", "file_2_changed"))).to eq("code_review.file_count_wrong")
    end

    it "refuses a snippet where files were asked for" do
      expect(code_for(two_files.merge("snippet" => "x = 1"))).to eq("code_review.file_count_wrong")
    end

    it "refuses half a third file as incomplete, not as a wrong count" do
      expect(code_for(two_files.merge("file_3_path" => "app/models/cart.rb"), file_range: 2..2)).to eq("code_review.file_incomplete")
      expect(code_for(two_files.merge("file_3_code" => "x = 1"))).to eq("code_review.file_incomplete")
    end

    it "refuses a path or code of the wrong type, and changed lines that aren't a list of strings" do
      expect(code_for(two_files.merge("file_2_code" => 42))).to eq("code_review.file_incomplete")
      expect(code_for(two_files.merge("file_2_path" => ""))).to eq("code_review.file_incomplete")
      expect(code_for(two_files.merge("file_2_changed" => "item_1 = 1"))).to eq("code_review.file_incomplete")
      expect(code_for(two_files.merge("file_2_changed" => [ 2 ]))).to eq("code_review.file_incomplete")
    end

    it "refuses a file past MAX_FILE_LINES" do
      expect(code_for(two_files(first_lines: described_class::MAX_FILE_LINES))).to be_nil
      expect(code_for(two_files(first_lines: described_class::MAX_FILE_LINES + 1))).to eq("code_review.file_too_long")
    end

    it "refuses files that together run past MAX_SNIPPET_LINES" do
      at_cap = two_files(first_lines: 14, second_lines: 13).merge(third_file(lines: 13))
      past_cap = two_files(first_lines: 14, second_lines: 14).merge(third_file(lines: 13))

      expect(described_class::MAX_SNIPPET_LINES).to eq(40)
      expect(code_for(at_cap)).to be_nil
      expect(code_for(past_cap)).to eq("code_review.file_too_long")
    end

    it "refuses a path past MAX_PATH_LENGTH, or two files with the same path" do
      longest = "app/#{'a' * (described_class::MAX_PATH_LENGTH - 7)}.rb"

      expect(code_for(two_files.merge("file_2_path" => longest))).to be_nil
      expect(code_for(two_files.merge("file_2_path" => "a#{longest}"))).to eq("code_review.path_invalid")
      expect(code_for(two_files.merge("file_2_path" => "app/models/order.rb"))).to eq("code_review.path_invalid")
    end

    it "refuses a section where no file has a resolved changed line" do
      section = two_files.merge("file_1_changed" => [ "nothing_like_it" ], "file_2_changed" => [])

      expect(code_for(section)).to eq("code_review.changed_lines_unresolved")
      expect(code_for(two_files.except("file_1_changed", "file_2_changed"))).to eq("code_review.changed_lines_unresolved")
    end

    it "carries counts and numbers in its messages, never the code or a quote" do
      planted = "SENTINEL_9f2"
      sections = [
        two_files.merge("file_2_code" => "#{planted} = 1\n" * (described_class::MAX_FILE_LINES + 1)),
        two_files.merge("file_2_path" => "#{planted}/#{'a' * described_class::MAX_PATH_LENGTH}"),
        two_files.merge("file_1_changed" => [ planted ], "file_2_changed" => [ planted ]),
        two_files.merge("file_3_code" => planted),
        two_files.merge("snippet" => planted)
      ]

      sections.each do |section|
        error = refusal_for(section)
        expect(error).to be_present
        expect(error.message).not_to include(planted)
      end
    end
  end

  describe "resolving changed lines" do
    def resolved(section, language: "ruby_rails", file_range: 2..2)
      described_class.reject_unusable!(section, language: language, file_range: file_range)
      section.values_at("file_1_changed", "file_2_changed")
    end

    it "resolves a line quoted before formatting spaced it" do
      section = two_files.merge("file_1_code" => "class Order\n  def total = items.sum(&:price)\nend",
                                "file_1_changed" => [ "def total=items.sum(&:price)" ])

      expect(resolved(section)).to eq([ [ 2 ], [ 2 ] ])
    end

    it "drops a line its file repeats, a line matching nothing, and a line that only contains the quote" do
      code = "class Order\n  def total\n    items.sum(&:price)\n  end\nend"
      section = two_files.merge("file_1_code" => code, "file_1_changed" => [ "end", "missing = 1", "items.sum", "def total" ])

      expect(resolved(section)).to eq([ [ 2 ], [ 2 ] ])
    end

    it "stores sorted, unique line numbers" do
      section = two_files.merge("file_1_changed" => [ "order_2 = 2", "order_0 = 0", "order_2 = 2" ])

      expect(resolved(section).first).to eq([ 1, 3 ])
    end

    it "marks every line of a JavaScript run Prettier wrapped" do
      code = "const total = items\n  .map((item) => item.price)\n  .reduce(add, 0);\nexport default total;"
      section = two_files.merge("file_1_code" => code,
                                "file_1_changed" => [ "const total = items.map(item => item.price).reduce(add, 0)" ],
                                "file_2_code" => "export const add = (a, b) => a + b;", "file_2_changed" => [])

      expect(resolved(section, language: "javascript")).to eq([ [ 1, 2, 3 ], [] ])
    end
  end

  describe "what a passing section keeps" do
    it "leaves no field of an absent third file" do
      section = two_files.merge("file_3_changed" => [ "stray" ])

      described_class.reject_unusable!(section, language: "ruby_rails", file_range: 2..3)

      expect(section.keys.grep(/\Afile_3_/)).to eq([])
      expect(section.keys.grep(/\Afile_2_/)).to contain_exactly("file_2_path", "file_2_code", "file_2_changed")
    end

    it "keeps a single-file section exactly as before on the default range" do
      section = { "snippet" => numbered("x", 5), "question" => "q" }
      original = section.deep_dup

      described_class.reject_unusable!(section, language: "ruby_rails")

      expect(section).to eq(original)
      expect(code_for({ "snippet" => " " }, file_range: 1..1)).to eq("code_review.snippet_missing")
    end

    it "leaves no file field on a single-file range, so the section never reads as multi-file" do
      section = { "snippet" => numbered("x", 5) }.merge(two_files, third_file)

      described_class.reject_unusable!(section, language: "ruby_rails", file_range: 1..1)

      expect(section.keys).to eq([ "snippet" ])
      expect(described_class.files(section)).to eq([])
    end
  end

  describe ".arrange!" do
    it "drops a diagram from a multi-file section and keeps one on a single-file section" do
      multi = two_files.merge("diagram" => "graph TD; A-->B")
      single = { "snippet" => "x = 1", "diagram" => "graph TD; A-->B" }

      described_class.arrange!(multi)
      described_class.arrange!(single)

      expect(multi).not_to have_key("diagram")
      expect(single["diagram"]).to eq("graph TD; A-->B")
    end
  end

  describe ".review_context" do
    it "lists each file under its path, with its changed lines and code, in place of the snippet" do
      section = { "question" => "What breaks?",
                  "file_1_path" => "app/models/order.rb", "file_1_code" => "a = 1\nb = 2", "file_1_changed" => [ 2 ],
                  "file_2_path" => "app/models/item.rb", "file_2_code" => "c = 3", "file_2_changed" => [],
                  "answer_key" => { "issue" => "ANSWER-KEY-SENTINEL" } }

      expect(described_class.review_context(section: section, answer: "The total.", rating: "right_level")).to eq(<<~CONTEXT.chomp)
        Code Review question: What breaks?
        File: app/models/order.rb
        Changed lines: 2
        a = 1
        b = 2
        File: app/models/item.rb
        Changed lines: none
        c = 3
        Their answer:
        <engineer_text>
        The total.
        </engineer_text>
        Their self-rating: right_level
      CONTEXT
    end
  end

  it "formats each file's code alongside the snippet" do
    expect(described_class.code_fields).to eq(%w[snippet file_1_code file_2_code file_3_code])
  end
end
