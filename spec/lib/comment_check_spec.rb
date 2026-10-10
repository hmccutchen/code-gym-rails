require_relative "../../lib/comment_check"

RSpec.describe CommentCheck do
  def messages(path, text)
    described_class.offenses_for(path, text).map { |offense| [ offense.line, offense.message ] }
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

  it "skips file types it has no scanner for" do
    expect(messages("README.md", "# Heading\n\n# Another\n")).to be_empty
  end
end
