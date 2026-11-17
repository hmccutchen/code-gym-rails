require "rails_helper"

RSpec.describe "The one open learner item per key index" do
  include AuthHelpers

  let(:user) { create_user_with_key }

  def write(term: "STI", status: "open", kind: "term", user: self.user)
    LearnerItem.new(user: user, concept: "open_closed", bucket: "ruby_rails", kind: kind, term: (term if kind == "term"),
                    label: "A label.", status: status, expires_on: Date.new(2026, 11, 30)).tap { |row| row.save!(validate: false) }
  end

  it "refuses a second open row for one key, a term differing only in case included" do
    write

    expect { write }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { write(term: "sti") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "stores a term with its spaces collapsed, so a spacing variant is the same key" do
    expect(write(term: "Single Table  Inheritance").reload.term).to eq("Single Table Inheritance")
    expect { write(term: "single   table inheritance") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a second open row for a key with no term" do
    write(kind: "misconception")

    expect { write(kind: "misconception") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a second row once the first is closed" do
    first = write
    first.update_columns(status: "used")

    expect { write }.not_to raise_error
    expect { write(status: "dismissed") }.not_to raise_error
  end

  it "keeps each account's keys apart" do
    write

    expect { write(user: create_user_with_key(email: "other@example.com")) }.not_to raise_error
  end
end
