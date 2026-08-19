require "rails_helper"

RSpec.describe PreviewEnvironment do
  after { ENV.delete(described_class::VAR) }

  it "is inactive when the variable is absent" do
    expect(described_class.active?).to be(false)
  end

  it "is inactive when the variable is blank" do
    ENV[described_class::VAR] = "   "

    expect(described_class.active?).to be(false)
  end

  it "is active when the variable is set" do
    ENV[described_class::VAR] = "1"

    expect(described_class.active?).to be(true)
  end

  # The suite boots without it, which is what makes Task 4's callback-absence
  # assertion meaningful.
  it "is inactive by default in the test environment" do
    expect(ENV[described_class::VAR]).to be_nil
  end
end
