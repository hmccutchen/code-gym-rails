require "rails_helper"

RSpec.describe KeyQuote do
  describe ".normalize" do
    it "removes whitespace everywhere, inside strings too, and one comma at the very end" do
      expect(described_class.normalize("foo(a, \"b c\"),", language: "ruby_rails")).to eq("foo(a,\"bc\")")
    end

    it "keeps Ruby's quotes, semicolons and inner trailing commas" do
      expect(described_class.normalize("['a', 'b',];", language: "ruby_rails")).to eq("['a','b',];")
    end

    it "undoes Prettier's rewrites on JavaScript, applied after the whitespace is gone" do
      aggregate_failures do
        expect(described_class.normalize("fetch('a', {\n  b: 1,\n},\n);", language: "javascript")).to eq("fetch(\"a\",{b:1})")
        expect(described_class.normalize("ids.map((id) => load(id))", language: "javascript")).to eq("ids.map(id=>load(id))")
        expect(described_class.normalize("(a, b) => a", language: "javascript")).to eq("(a,b)=>a")
      end
    end

    it "misses a JavaScript quote that stops before a bare arrow parameter's arrow, which whitespace alone would match" do
      code = "const done = (order) => order.paid;"
      quote = "done = (order)"

      expect(described_class.normalize(code, language: "javascript")).not_to include(described_class.normalize(quote, language: "javascript"))
      expect(code.gsub(/\s/, "")).to include(quote.gsub(/\s/, ""))
    end
  end

  describe ".find" do
    {
      "ruby_rails" => [
        [ "foo(a,b)", "x = 1\nfoo(a, b)\n", 2..2 ],
        [ "{a: 1}", "opts = { a: 1 }", 1..1 ],
        [ "foo(a,b)", "foo(a, c)", nil ]
      ],
      "javascript" => [
        [ "return fetchJson('/api/orders/' + orderId)", "async function load(orderId) {\n  return fetchJson(\n    \"/api/orders/\" + orderId,\n  );\n}", 2..4 ],
        [ "return ids.map(id=>fetch(id))", "return ids.map((id) => fetch(id));", 1..1 ]
      ]
    }.each do |language, cases|
      cases.each do |quote, code, range|
        it "finds #{quote.inspect} in #{language} code at #{range.inspect}" do
          expect(described_class.find(code, quote, language: language)).to eq(range)
        end
      end
    end

    it "spans every source line the match touches" do
      code = "def total\n  items.sum do |item|\n    item.price\n  end\nend"

      expect(described_class.find(code, "do |item| item.price end", language: "ruby_rails")).to eq(2..4)
    end

    it "finds nothing for a quote that normalizes to nothing" do
      expect(described_class.find("a,\nb", " , ", language: "ruby_rails")).to be_nil
    end
  end

  describe ".line" do
    let(:options) { "const options = {\n  retries: 3,\n  timeoutMs: 5000,\n};" }

    {
      "ruby_rails" => [
        [ "foo(a,b)", "x = 1\nfoo(a, b)", 2..2 ],
        [ "{a: 1}", "opts\n{ a: 1 }", 2..2 ],
        [ "end", "def a\nend\ndef b\nend", nil ],
        [ "foo(a)", "x = foo(a)", nil ]
      ],
      "javascript" => [
        [ "return fetchJson('/api/orders/' + orderId)", "async function load(orderId) {\n  return fetchJson(\n    \"/api/orders/\" + orderId,\n  );\n}", 2..4 ],
        [ "return ids.map(id=>fetch(id))", "function all(ids) {\n  return ids.map((id) => fetch(id));\n}", 2..2 ],
        [ "}", "if (a) {\n}\nif (b) {\n}", nil ]
      ]
    }.each do |language, cases|
      cases.each do |quote, code, range|
        it "matches #{quote.inspect} as a whole #{language} line at #{range.inspect}" do
          expect(described_class.line(code, quote, language: language)).to eq(range)
        end
      end
    end

    it "matches a JavaScript property whose trailing comma Prettier added" do
      expect(described_class.line(options, "timeoutMs: 5000", language: "javascript")).to eq(3..3)
    end

    it "joins wrapped lines only for JavaScript" do
      expect(described_class.line("foo(\n  a,\n)", "foo(a)", language: "ruby_rails")).to be_nil
      expect(described_class.line("foo(\n  a,\n)", "foo(a)", language: "javascript")).to eq(1..3)
    end

    it "matches a JavaScript statement Prettier wrapped onto more than four lines" do
      wrapped = "const order = await createOrder(\n  customerId,\n  lineItems,\n  shippingAddress,\n  couponCode,\n);\nreturn order;"
      quote = "const order = await createOrder(customerId, lineItems, shippingAddress, couponCode);"

      expect(described_class.line(wrapped, quote, language: "javascript")).to eq(1..6)
    end

    it "builds runs only between non-blank lines, so blank-line padding stays cheap" do
      padded = "const total = sum(\n#{"\n" * 1_000}  items,\n);"
      allow(described_class).to receive(:normalize).and_call_original

      expect(described_class.line(padded, "const total = sum(items);", language: "javascript")).to eq(1..1_003)
      expect(described_class).to have_received(:normalize).at_most(1_100).times
    end

    it "never matches a blank line, and never counts a run twice by padding it with one" do
      expect(described_class.line("a\n\n", "", language: "ruby_rails")).to be_nil
      expect(described_class.line("x();\n\nreturnValue();\n", "returnValue()", language: "javascript")).to eq(3..3)
    end
  end
end
