require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../../lib/rubocop/cop/code_gym/comment_limit"

RSpec.describe RuboCop::Cop::CodeGym::CommentLimit, :config do
  include RuboCop::RSpec::ExpectOffense

  let(:cop_config) { { "Max" => 2 } }

  it "accepts a file at the limit" do
    expect_no_offenses(<<~RUBY)
      # One.
      first
      second # Two.
    RUBY
  end

  it "flags every comment past the limit, trailing ones included" do
    expect_offense(<<~RUBY)
      # One.
      first
      # Two.
      second
      # Three.
      ^^^^^^^^ This file has 4 comments; the limit is 2. Move the reasoning into docs.
      third # Four.
            ^^^^^^^ This file has 4 comments; the limit is 2. Move the reasoning into docs.
    RUBY
  end

  it "does not count magic comments, directives or heredoc lines" do
    expect_no_offenses(<<~'RUBY')
      # frozen_string_literal: true
      # rubocop:disable Style/Foo
      # One.
      PROMPT = <<~TEXT
        # Heading
      TEXT
      # Two.
      call
    RUBY
  end
end
