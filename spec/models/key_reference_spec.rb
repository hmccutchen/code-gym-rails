require "rails_helper"

RSpec.describe KeyReference do
  def resolves?(span, code, language: "ruby_rails") = described_class.resolves?(span, code: code, language: language)

  describe "a Const.method reference" do
    it "resolves when the receiver and the method appear on one line as a call" do
      code = "def call\n  Adoption.create!(pet: pet, family: family)\nend"

      expect(resolves?("Adoption.create!", code)).to be(true)
    end

    it "resolves when the receiver and the method appear on one line as a stub" do
      aggregate_failures do
        expect(resolves?("Adoption.create!", "allow(Adoption).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)")).to be(true)
        expect(resolves?("ProcessedWebhook.exists?", "allow(ProcessedWebhook).to receive(:exists?).with(event_id: \"evt_123\")")).to be(true)
      end
    end

    it "resolves a chained receiver such as Rails.cache" do
      expect(resolves?("Rails.cache.fetch", "expect(Rails.cache).to receive(:fetch)\n  .with(\"summary\", expires_in: 1.hour)")).to be(true)
    end

    it "resolves a namespaced receiver" do
      expect(resolves?("Billing::Invoice.settle!", "Billing::Invoice.settle!(invoice)")).to be(true)
    end

    it "misses when the receiver and the method only appear on different lines" do
      code = "pet = Pet.find(id)\nAdoption.where(pet: pet)\nrecord.create!"

      expect(resolves?("Pet.create!", code)).to be(false)
    end

    it "misses a method the code never calls or stubs on that receiver" do
      expect(resolves?("Adoption.destroy!", "allow(Adoption).to receive(:create!)")).to be(false)
    end

    it "misses a method name that only appears as part of a longer name" do
      expect(resolves?("Adoption.create", "allow(Adoption).to receive(:create!)")).to be(false)
    end

    it "resolves a reference written with (...) the way it resolves the bare name" do
      aggregate_failures do
        expect(resolves?("Rails.cache.fetch(...)", "expect(Rails.cache).to receive(:fetch)")).to be(true)
        expect(resolves?("Adoption.create!(...)", "allow(Adoption).to receive(:create!)")).to be(true)
        expect(resolves?("Adoption.create!(...)", "Adoption.create!(pet: pet)")).to be(true)
      end
    end

    it "resolves a call the formatter split across lines, and a have_received stub" do
      aggregate_failures do
        expect(resolves?("Rails.cache.fetch", "Rails.cache\n  .fetch(\"summary\", expires_in: 1.hour)")).to be(true)
        expect(resolves?("Rails.cache.fetch", "expect(Rails.cache).to have_received(:fetch)")).to be(true)
      end
    end

    it "misses when the receiver and the method share a line but the method is called on something else" do
      expect(resolves?("Adoption.create!", "Pet.create!(adoption: Adoption.new)")).to be(false)
    end

    it "misses when the receiver only appears as the namespace of a longer constant" do
      expect(resolves?("Adoption.create!", "Adoption::Record.create!(x: 1)")).to be(false)
    end
  end

  describe "a Const#method reference" do
    let(:code) do
      "class CheckoutBook\n  def call\n    Loan.create!\n  end\nend\n\n" \
        "class HoldPickupJob < ApplicationJob\n  def perform(hold_id)\n    Hold.find(hold_id)\n  end\nend"
    end

    it "resolves when the class body defines the method, even on a different line from the class" do
      expect(resolves?("HoldPickupJob#perform", code)).to be(true)
    end

    it "misses when the method is defined in a different class" do
      expect(resolves?("CheckoutBook#perform", code)).to be(false)
    end

    it "misses when no class of that name is shown" do
      expect(resolves?("AdoptPet#rollback", code)).to be(false)
    end

    it "misses a class that only shares the name's prefix as a namespace" do
      expect(resolves?("Foo#perform", "class Foo::Bar\n  def perform\n  end\nend")).to be(false)
    end

    it "ends the class body at the class's own end, so a later method doesn't count" do
      aggregate_failures do
        expect(resolves?("Foo#perform", "class Foo\n  def call\n  end\nend\n\nRSpec.describe Foo do\n  def perform\n  end\nend")).to be(false)
        expect(resolves?("Foo#perform", "class Foo\nend\n\ndef perform\nend")).to be(false)
      end
    end

    it "resolves a method in a class nested inside a module" do
      expect(resolves?("Foo#perform", "module Jobs\n  class Foo\n    def perform\n    end\n  end\nend")).to be(true)
    end
  end

  describe "an elided call" do
    let(:code) { "create(:invoice, tenant: tenant, amount_cents: 5_000, settled_at: 1.day.ago)" }

    it "resolves when every piece around the ... is in the code, in order" do
      aggregate_failures do
        expect(resolves?("create(:invoice, ...)", code)).to be(true)
        expect(resolves?("create(:invoice, ..., settled_at: 1.day.ago)", code)).to be(true)
      end
    end

    it "misses when a piece is absent or the pieces are out of order" do
      aggregate_failures do
        expect(resolves?("create(:payment, ...)", code)).to be(false)
        expect(resolves?("settled_at: 1.day.ago ... create(:invoice", code)).to be(false)
      end
    end

    it "misses when no piece is long enough to check, so a bare ... never passes" do
      expect(resolves?("a(...)", code)).to be(false)
    end
  end

  describe "a span with no reference shape" do
    it "misses a bare name the code doesn't contain, such as a setting the snippet never shows" do
      expect(resolves?(":null_store", "expect(Rails.cache).to receive(:fetch)")).to be(false)
    end

    it "misses prose and arbitrary expressions, which only a verbatim match may pass" do
      aggregate_failures do
        expect(resolves?("update!(params)", "current_user.update(params[:user])")).to be(false)
        expect(resolves?("the transaction wrapper", "Adoption.transaction do\nend")).to be(false)
      end
    end
  end

  it "resolves nothing in JavaScript until a JavaScript run shows the shapes it needs" do
    code = "allow(Adoption).to receive(:create!)"

    expect(resolves?("Adoption.create!", code, language: "javascript")).to be(false)
  end
end
