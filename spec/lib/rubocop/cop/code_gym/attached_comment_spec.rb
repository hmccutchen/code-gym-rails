require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../../lib/rubocop/cop/code_gym/attached_comment"

RSpec.describe RuboCop::Cop::CodeGym::AttachedComment, :config do
  include RuboCop::RSpec::ExpectOffense

  it "accepts a comment directly above code" do
    expect_no_offenses(<<~RUBY)
      # Retried once because the provider drops idle sockets.
      call
    RUBY
  end

  it "accepts a trailing comment" do
    expect_no_offenses(<<~RUBY)
      call # retried once
    RUBY
  end

  it "accepts a comment in a deliberately empty branch" do
    expect_no_offenses(<<~RUBY)
      case day
      when :weekend
        # Weekends never break a streak.
      when :weekday
        count
      end
    RUBY
  end

  it "flags a comment separated from code by a blank line" do
    expect_offense(<<~RUBY)
      # Retried once because the provider drops idle sockets.
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Put the comment directly above the code it discusses.

      call
    RUBY
  end

  it "flags a comment at the end of the file" do
    expect_offense(<<~RUBY)
      call
      # Trailing thought.
      ^^^^^^^^^^^^^^^^^^^ Put the comment directly above the code it discusses.
    RUBY
  end

  it "accepts a reason directly above a rubocop directive and its code" do
    expect_no_offenses(<<~RUBY)
      # The provider SDK reads this global.
      # rubocop:disable Style/GlobalVars
      $client = build
    RUBY
  end

  it "does not flag a =begin block that code directly follows" do
    expect_no_offenses(<<~RUBY)
      =begin
      notes
      =end
      call
    RUBY
  end

  it "flags a comment followed by a =begin block" do
    expect_offense(<<~RUBY)
      # Reason.
      ^^^^^^^^^ Put the comment directly above the code it discusses.
      =begin
      notes
      =end
      call
    RUBY
  end

  it "ignores a magic comment followed by a blank line" do
    expect_no_offenses(<<~RUBY)
      # frozen_string_literal: true

      call
    RUBY
  end
end
