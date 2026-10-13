require "rails_helper"

RSpec.describe WorkedExample do
  def kinds(text)
    described_class.parts(text).map(&:kind)
  end

  it "splits commented Ruby fragments from the prose after them, keeping both fragments in one block" do
    text = <<~TEXT.strip
      # Failure: one query per post
      posts = Post.limit(20)
      posts.each do |post|
        puts post.author.name
      end

      # Corrected: loaded in bulk
      posts = Post.includes(:author).limit(20)

      The first version fails because each `post.author` call runs its own query. In the second, `includes` loads them first.
    TEXT

    parts = described_class.parts(text)

    expect(parts.map(&:kind)).to eq(%i[code prose])
    expect(parts.first.text).to start_with("# Failure").and include("end\n\n# Corrected").and end_with(".limit(20)")
    expect(parts.last.text).to start_with("The first version fails")
  end

  it "reads one-line fragments as code by their closing brace" do
    text = "orders.each { |order| puts order.customer.name }\n\n" \
           "Order.includes(:customer).each { |order| puts order.customer.name }\n\n" \
           "The first loads each customer when it is touched. The second loads them all at once."

    expect(kinds(text)).to eq(%i[code prose])
  end

  it "reads a line that ends without sentence punctuation as code" do
    expect(kinds("Post.includes(comments: :user)\n\nThat loads both levels.")).to eq(%i[code prose])
  end

  it "reads a paragraph with neither a full stop nor anything code-like as prose" do
    expect(kinds("A worked example")).to eq(%i[prose])
  end

  it "keeps a fenced fragment whole across its blank lines and drops the fence markers" do
    text = "```ruby\na = 1\n\nb = 2\n```\n\nBoth lines run in order."

    parts = described_class.parts(text)

    expect(parts.map(&:kind)).to eq(%i[code prose])
    expect(parts.first.text).to eq("a = 1\n\nb = 2")
  end

  it "keeps prose that wraps over several lines as one prose paragraph" do
    text = "The slow page is what happens when the association is never loaded:\n" \
           "touching it per row is what issues a query per row."

    expect(kinds(text)).to eq(%i[prose])
  end

  it "returns a text with no code as a single prose part, as the page showed it before" do
    expect(described_class.parts("A worked example.")).to eq([ described_class::Part.new(kind: :prose, text: "A worked example.") ])
  end

  it "keeps the indentation of a fragment's first line" do
    expect(described_class.parts("\n  indented = true\n").first.text).to eq("  indented = true")
  end
end
