require "rails_helper"

RSpec.describe UsageHelper, type: :helper do
  it "shows zero as a whole-dollar amount" do
    expect(helper.usage_dollars(BigDecimal("0"))).to eq("$0.00")
  end

  it "shows an amount under a cent as less than a cent" do
    expect(helper.usage_dollars(BigDecimal("0.004"))).to eq("< $0.01")
  end

  it "shows 0.009 as less than a cent" do
    expect(helper.usage_dollars(BigDecimal("0.009"))).to eq("< $0.01")
  end

  it "shows exactly a cent as $0.01" do
    expect(helper.usage_dollars(BigDecimal("0.01"))).to eq("$0.01")
  end

  it "rounds to two decimal places" do
    expect(helper.usage_dollars(BigDecimal("4.1234"))).to eq("$4.12")
  end

  it "groups thousands" do
    expect(helper.usage_dollars(BigDecimal("1234.5"))).to eq("$1,234.50")
  end
end
