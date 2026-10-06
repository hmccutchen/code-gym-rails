require "rails_helper"

RSpec.describe InviteCode, type: :model do
  it "mints a 26-character base32 code and keeps only its digest" do
    record, code = described_class.mint(seats: 2, expires_at: 1.week.from_now, provider: "gemini", trial_days: 7,
                                        daily_request_cap: 12, label: "pilot")

    expect(code).to match(/\A[A-Z2-7]{26}\z/)
    expect(record.code_digest).to eq(Digest::SHA256.hexdigest(code))
    expect(record.attributes.values).not_to include(code)
    expect(record).to be_trial
    expect(described_class.find_by_code(code)).to eq(record)
  end

  it "finds a code typed with spaces, dashes and lower case, and nothing for a wrong one" do
    record, code = described_class.mint(seats: 1, expires_at: 1.week.from_now)

    expect(described_class.find_by_code(code.downcase.scan(/.{1,4}/).join("-"))).to eq(record)
    expect(described_class.find_by_code(code.tr("A-Z2-7", "B-ZA3-72"))).to be_nil
    expect(described_class.find_by_code("")).to be_nil
    expect(described_class.find_by_code(code[0..-2])).to be_nil
  end

  it "takes one seat per redemption and refuses past the seats or the deadline" do
    record, = described_class.mint(seats: 2, expires_at: 1.day.from_now)

    expect(record.redeem!).to be(true)
    expect(record.redeem!).to be(true)
    expect(record.redeem!).to be(false)
    expect(record.reload.redeemed_count).to eq(2)

    fresh, = described_class.mint(seats: 1, expires_at: 1.day.from_now)
    travel_to(2.days.from_now) { expect(fresh.redeem!).to be(false) }
    expect(fresh.reload.redeemed_count).to eq(0)
  end

  it "requires a trial length for a trial code and a known provider" do
    expect { described_class.mint(seats: 1, expires_at: 1.day.from_now, provider: "gemini") }
      .to raise_error(ActiveRecord::RecordInvalid, /Trial days/)
    expect { described_class.mint(seats: 1, expires_at: 1.day.from_now, provider: "nope", trial_days: 7) }
      .to raise_error(ActiveRecord::RecordInvalid, /Provider/)
    expect { described_class.mint(seats: 0, expires_at: 1.day.from_now) }
      .to raise_error(ActiveRecord::RecordInvalid, /Seats/)
  end

  it "is a join code without a provider" do
    record, = described_class.mint(seats: 1, expires_at: 1.day.from_now)
    expect(record).not_to be_trial
  end
end
