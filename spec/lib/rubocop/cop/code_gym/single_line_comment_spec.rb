require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../../lib/rubocop/cop/code_gym/single_line_comment"

RSpec.describe RuboCop::Cop::CodeGym::SingleLineComment, :config do
  include RuboCop::RSpec::ExpectOffense

  it "accepts a one-line comment" do
    expect_no_offenses(<<~RUBY)
      # Retried once because the provider drops idle sockets.
      call
    RUBY
  end

  it "flags consecutive comment lines as one offense" do
    expect_offense(<<~RUBY)
      # The provider drops idle sockets,
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Keep each comment to a single line.
      # so the call is retried once.
      call
    RUBY
  end

  it "flags an own-line comment continuing a trailing one" do
    expect_offense(<<~RUBY)
      call # retried once
           ^^^^^^^^^^^^^^ Keep each comment to a single line.
           # because sockets drop
    RUBY
  end

it "accepts an own-line comment that starts a new comment for the next line" do
  expect_no_offenses(<<~RUBY)
    x = 1 # one
    # Why y is two.
    y = 2
  RUBY
end

it "accepts trailing comments on consecutive code lines" do
    expect_no_offenses(<<~RUBY)
      first = 1 # one
      second = 2 # two
    RUBY
  end

  it "accepts one-line comments separated by a blank line" do
    expect_no_offenses(<<~RUBY)
      # One reason.

      # Another reason.
      call
    RUBY
  end

  it "flags a =begin block" do
    expect_offense(<<~RUBY)
      =begin
      ^^^^^^ Keep each comment to a single line.
      notes
      =end
      call
    RUBY
  end

  it "ignores a shebang, magic comments and directives beside a comment" do
    expect_no_offenses(<<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      # rubocop:disable Style/Foo
      # One reason.
      call
      # rubocop:enable Style/Foo
    RUBY
  end

  it "does not treat # lines inside a heredoc as comments" do
    expect_no_offenses(<<~'RUBY')
      PROMPT = <<~TEXT
        # Heading
        # Subheading
      TEXT
    RUBY
  end
end
