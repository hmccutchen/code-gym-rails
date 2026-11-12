require "tempfile"
require_relative "../../lib/comment_check"

RSpec.describe CommentCheck do
  def messages(path, text)
    described_class.offenses_for(path, text).map { |offense| [ offense.line, offense.message ] }
  end

  it "checks only file types it can scan, outside vendored and dependency folders" do
    expect(%w[config/a.yml app/views/a.html.erb app/javascript/a.js lefthook.yml].map { described_class.checked_path?(_1) }).to all(be(true))
    expect(%w[app/models/a.rb README.md vendor/prettier/a.yml spec/playwright/node_modules/a.js .claude/skills/a/b.py]
      .map { described_class.checked_path?(_1) }).to all(be(false))
  end

  it "accepts a one-line YAML comment above its key" do
    expect(messages("config/a.yml", "# Hourly in production.\nschedule: every hour\n")).to be_empty
  end

  it "flags consecutive YAML comment lines" do
    expect(messages("config/a.yml", "# One.\n# Two.\nkey: 1\n")).to include([ 2, "Keep each comment to a single line." ])
  end

  it "flags a comment followed by a blank line" do
    expect(messages("config/a.yml", "# Loose.\n\nkey: 1\n")).to eq([ [ 1, "Put the comment directly above the code it discusses." ] ])
  end

  it "does not read a hash inside quotes as a comment" do
    expect(messages("config/a.yml", "color: \"#fff\"\nlabel: 'a # b'\n")).to be_empty
  end

  it "counts trailing comments toward the limit of five" do
    text = (1..6).map { |n| "key#{n}: #{n} # note #{n}\n" }.join

    expect(messages("config/a.yml", text)).to eq([ [ 6, "This file has 6 comments; the limit is 5." ] ])
  end

  it "ignores a Python shebang and coding line" do
    expect(messages("script/a.py", "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\nprint(1)\n")).to be_empty
  end

  it "flags a CSS block comment spanning lines" do
    expect(messages("app/a.css", "/* One\n   two */\nbody { color: red; }\n")).to eq([ [ 1, "Keep each comment to a single line." ] ])
  end

  it "does not read a URL inside a JavaScript string as a comment" do
    expect(messages("app/a.js", "fetch(\"https://example.com\") // load it\n")).to be_empty
  end

  it "flags a multi-line ERB comment" do
    expect(messages("app/a.html.erb", "<%# One\n    two %>\n<p>Hi</p>\n")).to eq([ [ 1, "Keep each comment to a single line." ] ])
  end

  it "ignores an ERB strict-locals declaration" do
    expect(messages("app/_a.html.erb", "<%# locals: (user:) %>\n\n<p><%= user.name %></p>\n")).to be_empty
  end

  it "checks JavaScript and CSS embedded in ERB" do
    text = "<script>\n  // One\n  // Two\n  run();\n</script>\n<style>\n  /* Three\n     four */\n  p { margin: 0; }\n</style>\n"

    expect(messages("app/a.html.erb", text)).to contain_exactly(
      [ 3, "Keep each comment to a single line." ], [ 2, "Put the comment directly above the code it discusses." ],
      [ 7, "Keep each comment to a single line." ]
    )
  end

  it "does not count a bare route annotation toward the limit" do
    text = (1..5).map { |n| "key#{n}: #{n} # note #{n}\n" }.join + "# POST /responses/:id/review\nroute: 1\n"

    expect(messages("config/a.yml", text)).to be_empty
  end

  it "reads a Python or JavaScript comment marker with no space before it" do
    python = (1..6).map { |n| "value#{n} = #{n}# note\n" }.join
    javascript = (1..6).map { |n| "run#{n}();// note\n" }.join

    expect(messages("script/a.py", python)).to eq([ [ 6, "This file has 6 comments; the limit is 5." ] ])
    expect(messages("app/a.js", javascript)).to eq([ [ 6, "This file has 6 comments; the limit is 5." ] ])
  end

  it "requires a space before a YAML comment marker" do
    expect(messages("config/a.yml", "anchor: a#b\n")).to be_empty
  end

  it "does not read comment markers inside JavaScript or CSS strings" do
    javascript = (1..6).map { |n| "const s#{n} = \"/* not a comment */\";\n" }.join +
                 "const apostrophe = 1; // don't stop scanning\nrun();\n"
    css = "a::before { content: \"/* not a comment */\"; }\n"

    expect(messages("app/a.js", javascript)).to be_empty
    expect(messages("app/a.css", css)).to be_empty
  end

  it "keeps reading ERB comments after an apostrophe in page text" do
    text = "<p>Don't panic.</p>\n<%# One\n    two %>\n<p>Hi</p>\n"

    expect(messages("app/a.html.erb", text)).to eq([ [ 2, "Keep each comment to a single line." ] ])
  end

  it "treats a Python encoding line in either form as tooling" do
    expect(messages("script/a.py", "# coding: utf-8\n\nprint(1)\n")).to be_empty
  end

  it "treats an encoding-like YAML comment as prose" do
    expect(messages("config/a.yml", "# coding: utf-8\n\nkey: 1\n")).to eq([ [ 1, "Put the comment directly above the code it discusses." ] ])
  end

  def script(first_line)
    Tempfile.create("script") do |file|
      file.write("#{first_line}\nrun\n")
      file.close
      yield file.path
    end
  end

  it "checks a file with no extension when its shebang names a shell, and leaves a Ruby script to RuboCop" do
    checked = [ "#!/bin/bash -e", "#!/usr/bin/env bash", "#!/bin/sh", "#!/usr/bin/env sh" ].map { |line| script(line) { described_class.checked_path?(_1) } }

    expect(checked).to all(be(true))
    expect([ "#!/usr/bin/env ruby", "run" ].map { |line| script(line) { described_class.checked_path?(_1) } }).to all(be(false))
  end

  it "picks the shell scanner for a shell shebang and no scanner for a Ruby one" do
    expect(described_class::Scanners.for("bin/a", "#!/bin/bash -e\n")).to eq(described_class::Scanners.method(:shell_comments))
    expect(described_class::Scanners.for("bin/a", "#!/usr/bin/env ruby\n")).to be_nil
    expect(described_class::Scanners.for("bin/a", "")).to be_nil
  end

  it "reads shell comments, ignoring the shebang and a hash inside a parameter expansion" do
    text = "#!/bin/bash -e\n\n# One\n# Two\necho ${#items[@]} $# \"# quoted\"\n"

    expect(messages("bin/a", text)).to contain_exactly(
      [ 4, "Keep each comment to a single line." ], [ 3, "Put the comment directly above the code it discusses." ]
    )
  end

  it "picks a hash-comment scanner for a Dockerfile, .gitignore and .dockerignore by file name, at any depth" do
    scanners = %w[Dockerfile .gitignore .dockerignore app/.gitignore vendor/x/.dockerignore].map { described_class::Scanners.for(_1, "") }

    expect(scanners.map(&:name)).to eq(%i[dockerfile_comments ignore_file_comments ignore_file_comments ignore_file_comments ignore_file_comments])
    expect(described_class::Scanners.for("docs/Dockerfile.md", "")).to be_nil
    expect(%w[Dockerfile .gitignore .dockerignore].map { described_class.checked_path?(_1) }).to all(be(true))
  end

  it "reads an ignore file comment only when the line starts with a hash" do
    text = "# One\n/a#b\n  # indented is a pattern\n\\#escaped\n/c # part of the pattern\n"

    expect(comment_bodies(:ignore_file_comments, text)).to eq([ "One" ])
  end

  it "reads a Dockerfile comment only at the start of a line, and skips parser directives" do
    text = "# syntax=docker/dockerfile:1\n# check=error=true\n# escape=`\n# Real\nRUN echo # not a comment\n  # indented\nENV A=\"#b\"\n"

    expect(comment_bodies(:dockerfile_comments, text)).to eq([ "Real", "indented" ])
  end

  it "treats a RUN heredoc body in a Dockerfile as content" do
    text = "RUN <<EOF\n# in the script\nEOF\n# After\n"

    expect(comment_bodies(:dockerfile_comments, text)).to eq([ "After" ])
  end

  it "reports offenses in a Dockerfile and an ignore file" do
    expect(messages("Dockerfile", "FROM ruby\n# One\n\nRUN true\n")).to eq([ [ 2, "Put the comment directly above the code it discusses." ] ])
    expect(messages(".gitignore", "# One\n# Two\n/log\n")).to include([ 2, "Keep each comment to a single line." ])
    expect(messages(".dockerignore", (1..6).map { "# c#{_1}\n/a#{_1}\n" }.join)).to eq([ [ 11, "This file has 6 comments; the limit is 5." ] ])
  end

  def comment_bodies(scanner, text) = described_class::Scanners.public_send(scanner, text).map(&:body)

  it "does not read a JavaScript regex literal as a comment" do
    text = "const scheme = /https?:\\/\\//;\nconst glob = /[/*]/g;\nconst quote = /[\"']/;\nconst found = text.match(/\\/\\/+/) || [];\nrun();\n"

    expect(comment_bodies(:js_comments, text)).to be_empty
  end

  it "still reads a comment after JavaScript division or a regex literal" do
    text = "const half = total / 2; // halve it\nconst ratio = (a + b) / c / d; // ratio\nconst path = url.replace(/\\/+$/, \"\"); // trim\n"

    expect(comment_bodies(:js_comments, text)).to eq([ "halve it", "ratio", "trim" ])
  end

  it "does not read a hash line inside a YAML block scalar as a comment" do
    text = "# Runs the checks.\nrun: |\n  # not a comment\n  echo hi\n\n  # nor this\nnote: >-\n  # folded text\nsteps:\n  - |\n    # list item text\n  - plain # real\nkey: 1\n"

    expect(comment_bodies(:yaml_comments, text)).to eq([ "Runs the checks.", "real" ])
  end

  it "counts a comment on a YAML block scalar's indicator line" do
    expect(comment_bodies(:yaml_comments, "run: | # shell\n  echo hi\n")).to eq([ "shell" ])
  end

  it "reads a plain value that ends in > or | as text, so a comment indented below it still counts" do
    text = "title: a > b\nlist: x |\n  # real one\nnested:\n  # real two\n  key: 1\n"

    expect(comment_bodies(:yaml_comments, text)).to eq([ "real one", "real two" ])
  end

  it "reads a slash after a postfix ++ or -- as division, so the comment after it counts" do
    text = "const a = total++ / 2; // first\nconst b = total-- / 2; // second\n"

    expect(comment_bodies(:js_comments, text)).to eq([ "first", "second" ])
  end

  it "still reads a regex literal that starts the line after a postfix ++" do
    expect(comment_bodies(:js_comments, "count++\n/https?:\\/\\//.test(url) // real\n")).to eq([ "real" ])
  end

  it "ends a block scalar opened by a list item's key at that item's next key" do
    text = "steps:\n  - run: |\n      # script text\n    name: hi # inline\n    # own line\n  - |\n    # item text\n"

    expect(comment_bodies(:yaml_comments, text)).to eq([ "inline", "own line" ])
  end

  it "ends a block scalar at a comment indented less than its text" do
    expect(comment_bodies(:yaml_comments, "run: |\n    echo hi\n  # after\nkey: 1\n")).to eq([ "after" ])
    expect(comment_bodies(:yaml_comments, "run: |4\n    echo hi\n  # after\nkey: 1\n")).to eq([ "after" ])
  end

  it "opens no block scalar for a | inside a comment" do
    expect(comment_bodies(:yaml_comments, "nested: # example: |\n  a: 1 # real\n")).to eq([ "example: |", "real" ])
  end

  it "reads a keyword used as a property or a $ name as an operand, so the slash after it is division" do
    text = "const a = stats.in / 2; // first\nconst b = stats. in / 2; // second\nconst c = $return / 2; // third\n"

    expect(comment_bodies(:js_comments, text)).to eq([ "first", "second", "third" ])
  end

  it "still reads a regex literal after a keyword that stands alone" do
    expect(comment_bodies(:js_comments, "return /https?:\\/\\//.test(url) // real\n")).to eq([ "real" ])
  end

  it "skips a shell heredoc's body, quoted or not, and still counts comments after it" do
    text = "#!/bin/sh\ncat <<'EOF'\n# generated one\n# generated two\nEOF\ncat <<-END\n\t# tab text\n\tEND\n# real\necho hi\n"

    expect(comment_bodies(:shell_comments, text)).to eq([ "real" ])
  end

  it "opens no heredoc for << inside quotes, a comment or arithmetic" do
    text = "#!/bin/sh\necho \"usage: tool <<EOF\"\n# after quotes\necho ready # document <<EOF syntax\n# after comment\nvalue=$((1 << 2))\n# after arithmetic\n"

    expect(comment_bodies(:shell_comments, text)).to eq([ "after quotes", "document <<EOF syntax", "after comment", "after arithmetic" ])
  end

  it "keeps comments after a heredoc that never closes" do
    expect(comment_bodies(:shell_comments, "#!/bin/sh\ncat <<EOF\n# real\n")).to eq([ "real" ])
  end

  it "skips file types it has no scanner for" do
    expect(messages("README.md", "# Heading\n\n# Another\n")).to be_empty
  end
end
