require "rails_helper"

RSpec.describe User, "#write_learner_notes_setting!" do
  let(:user) { User.create!(email: "setting@example.com", provider: "fake", api_keys: { "fake" => "fake-key" }) }

  it "turns the setting on for an account it is offered to, and off again" do
    expect(user.write_learner_notes_setting!(true, offered: true)).to eq(:turned_on)
    expect(user.reload.learner_notes_enabled).to be(true)

    expect(user.write_learner_notes_setting!(false, offered: true)).to eq(:turned_off)
    expect(user.reload.learner_notes_enabled).to be(false)
  end

  it "refuses to turn on where it is not offered, but always turns off" do
    user.update!(learner_notes_enabled: true)

    expect(user.write_learner_notes_setting!(true, offered: false)).to eq(:own_key_needed)
    expect(user.write_learner_notes_setting!(false, offered: false)).to eq(:turned_off)
    expect(user.reload.learner_notes_enabled).to be(false)
  end

  it "writes under the user row lock" do
    expect(user).to receive(:with_lock).and_call_original

    user.write_learner_notes_setting!(true, offered: true)
  end

  it "names a deleted account" do
    stale = User.find(user.id)
    user.destroy!

    expect(stale.write_learner_notes_setting!(false, offered: true)).to eq(:deleted)
  end

  it "names an anonymized account" do
    user.update_columns(anonymized_at: Time.current)

    expect(user.write_learner_notes_setting!(false, offered: true)).to eq(:deleted)
  end
end
