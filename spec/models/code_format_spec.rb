require "rails_helper"

RSpec.describe CodeFormat do
  before { allow(described_class).to receive(:all).and_call_original }

  def without_whitespace(code)
    code.gsub(/\s/, "")
  end

  describe "Ruby" do
    let(:messy) do
      <<~RUBY
        class OrdersController < ApplicationController
            def index
          @orders = Order.all
                @orders.each do |order|
              puts order.customer.name
                    end
            end
        end
      RUBY
    end

    it "re-indents the code" do
      formatted = described_class.all([ messy ], language: "ruby_rails").sole

      expect(formatted.lines.map { |line| line[/\A */].size }).to eq([ 0, 2, 4, 4, 6, 4, 2, 0 ])
    end

    # Layout cops only: a planted defect has to survive formatting.
    it "changes nothing but whitespace" do
      formatted = described_class.all([ messy + "x  =  1 + 2   # padded\n" ], language: "ruby_rails").sole

      expect(without_whitespace(formatted)).to eq(without_whitespace(messy + "x  =  1 + 2   # padded\n"))
    end

    it "keeps a hash lined up as a table" do
      table = "RATES = {\n  \"ups\"   => UpsRate,\n  \"fedex\" => FedexRate\n}\n"

      expect(described_class.all([ table ], language: "ruby_rails")).to eq([ table ])
    end

    it "hands back code it cannot parse unchanged" do
      broken = "def index(\n    @orders =\n"

      expect(described_class.all([ broken ], language: "ruby_rails")).to eq([ broken ])
    end

    it "keeps the original's trailing-newline state" do
      expect(described_class.all([ "def a\n      1\nend" ], language: "ruby_rails")).to eq([ "def a\n  1\nend" ])
    end

    it "formats one snippet at a time when called from several threads" do
      threads = 3.times.map { |i| Thread.new { described_class.all([ "def m#{i}\n      #{i}\nend\n" ], language: "ruby_rails").sole } }

      expect(threads.map(&:value)).to eq(3.times.map { |i| "def m#{i}\n  #{i}\nend\n" })
    end
  end

  describe "JavaScript" do
    it "re-indents the code and handles JSX and TypeScript" do
      snippets = [
        "function load( ids ){\n      return ids.map(id=>fetch(id))\n}\n",
        "const Row = ({order}) => <li   className=\"row\">{order.total}</li>\n",
        "function total(items: Item[]): number { return items.length }\n"
      ]

      expect(described_class.all(snippets, language: "javascript")).to eq([
        "function load(ids) {\n  return ids.map((id) => fetch(id));\n}\n",
        "const Row = ({ order }) => <li className=\"row\">{order.total}</li>;\n",
        "function total(items: Item[]): number {\n  return items.length;\n}\n"
      ])
    end

    it "hands back only the snippets Prettier cannot parse unchanged" do
      expect(described_class.all([ "function x( {", "let a=1" ], language: "javascript")).to eq([ "function x( {", "let a = 1;" ])
    end

    it "hands back every snippet unchanged when Node cannot run" do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT)
      allow(Rails.logger).to receive(:warn)

      expect(described_class.all([ "let a=1" ], language: "javascript")).to eq([ "let a=1" ])
      expect(Rails.logger).to have_received(:warn).with("[code_format] language=javascript fallback=Errno::ENOENT")
    end
  end

  it "hands back code in a language it has no formatter for unchanged" do
    expect(described_class.all([ "x  =  1" ], language: "cobol")).to eq([ "x  =  1" ])
  end
end
