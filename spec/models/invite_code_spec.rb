require "rails_helper"

RSpec.describe InviteCode, type: :model do
  def mint(**options) = described_class.mint(seats: 1, expires_at: 1.day.from_now, trial_days: 7, **options)

  it "mints a 26-character base32 code and keeps only its digest" do
    record, code = mint(seats: 2, daily_request_cap: 12, label: "pilot")

    expect(code).to match(/\A[A-Z2-7]{26}\z/)
    expect(record.code_digest).to eq(Digest::SHA256.hexdigest(code))
    expect(record.attributes.values).not_to include(code)
    expect(described_class.find_by_code(code)).to eq(record)
  end

  it "finds a code typed with spaces, dashes and lower case, and nothing for a wrong one" do
    record, code = mint

    expect(described_class.find_by_code(code.downcase.scan(/.{1,4}/).join("-"))).to eq(record)
    expect(described_class.find_by_code(code.tr("A-Z2-7", "B-ZA3-72"))).to be_nil
    expect(described_class.find_by_code("")).to be_nil
    expect(described_class.find_by_code(code[0..-2])).to be_nil
  end

  it "takes one seat per redemption and refuses past the seats or the deadline" do
    record, = mint(seats: 2)

    expect(record.redeem!).to be(true)
    expect(record.redeem!).to be(true)
    expect(record.redeem!).to be(false)
    expect(record.reload.redeemed_count).to eq(2)

    fresh, = mint
    travel_to(2.days.from_now) { expect(fresh.redeem!).to be(false) }
    expect(fresh.reload.redeemed_count).to eq(0)
  end

  it "is available while a seat is left before the deadline" do
    record, = mint

    expect(record).to be_available
    travel_to(2.days.from_now) { expect(record).not_to be_available }
    record.redeem!
    expect(record).not_to be_available
  end

  it "requires seats and a trial length" do
    expect { described_class.mint(seats: 1, expires_at: 1.day.from_now, trial_days: nil) }
      .to raise_error(ActiveRecord::RecordInvalid, /Trial days/)
    expect { mint(seats: 0) }.to raise_error(ActiveRecord::RecordInvalid, /Seats/)
  end
end
