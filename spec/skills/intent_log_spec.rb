require "date"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "The intent-log skill's scripts" do
  let(:repo) { Dir.mktmpdir }
  let(:prs) { [] }
  let(:skill) do
    File.join(repo, "skill copy").tap { FileUtils.cp_r(File.expand_path("../../.claude/skills/intent-log", __dir__), _1) }
  end

  before do
    system("git", "init", "-q", "-b", "mine", repo, exception: true)
    system("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
           "commit", "-q", "--allow-empty", "-m", "start", exception: true)
    write("docs/intent/_since", "2026-10-20\n")
  end

  after { FileUtils.remove_entry(repo) }

  def pr(number, author:, state: "MERGED", created: "2026-10-20T15:00:00Z", branch: "work-#{number}", bot: false)
    { "number" => number, "state" => state, "title" => "PR #{number}", "createdAt" => created,
      "headRefName" => branch, "author" => { "login" => author, "is_bot" => bot } }
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
    File.write(File.join(repo, path), text)
  end

  def entry(login, *bullets, heading: "Tue Oct 20, 2026")
    write("docs/intent/#{login}.md", "# #{login}\n\n## #{heading}\n\n#{bullets.map { "- #{_1}" }.join("\n")}\n")
  end

  def run(script, *args, env: {}, stdin: "")
    write(".bin/gh", "#!/usr/bin/env ruby\nputs(ARGV.first(2) == %w[api user] ? \"me\" : File.read(#{File.join(repo, "prs.json").inspect}))\n")
    File.chmod(0o755, File.join(repo, ".bin/gh"))
    write("prs.json", JSON.generate(prs))
    Open3.capture2e({ "PATH" => "#{File.join(repo, ".bin")}:#{ENV["PATH"]}" }.merge(env),
                    "ruby", File.join(skill, script), *args, chdir: repo, stdin_data: stdin)
  end

  def check(*args)
    output, status = run("compose.rb")
    raise output unless status.success?

    run("check.rb", *args)
  end

  describe "check.rb" do
    it "passes when each of your PRs since the cutoff is tagged once, bare on the checked-out branch" do
      prs.push(pr(1, author: "me"), pr(2, author: "me", state: "OPEN", branch: "mine"))
      entry("me", "first thing `#1`", "second thing `#2`")

      output, status = check
      expect(status).to be_success, output
    end

    it "fails on your PR that no entry tags" do
      prs.push(pr(1, author: "me"))
      entry("me", "nothing shipped")

      output, status = check
      expect(status).not_to be_success
      expect(output).to include("#1 (merged) by me is in no entry")
    end

    it "leaves a teammate's missing and stale tags to them unless --all" do
      prs.push(pr(1, author: "me"), pr(2, author: "teammate"), pr(3, author: "teammate"))
      entry("me", "mine `#1`")
      entry("teammate", "theirs `#2 open`")

      output, status = check
      expect(status).to be_success, output

      output, status = check("--all")
      expect(status).not_to be_success
      expect(output).to include("`#2 open` marks a merged PR", "#3 (merged) by teammate is in no entry")
    end

    it "owes nothing for a bot's PR or one opened before _since, even after an older entry is backfilled" do
      prs.push(pr(1, author: "dependabot", bot: true), pr(2, author: "me", created: "2026-10-18T15:00:00Z"))
      write("docs/intent/me.md", "# me\n\n## Mon Oct 12, 2026\n\n- backfilled\n\n## Tue Oct 20\n\n- today\n")

      output, status = check
      expect(status).to be_success, output
    end

    it "refuses a PR listing the limit cut short" do
      prs.push(pr(1, author: "me"), pr(2, author: "me"))
      entry("me", "both `#1` and `#2`")

      output, status = check("--limit", "2")
      expect(status).not_to be_success
      expect(output).to include("returned 2 PRs, the --limit")
    end

    it "rewraps the per-person file under --fix and composes the log again" do
      prs.push(pr(1, author: "me"))
      entry("me", "#{"lengthy " * 12}`#1`")
      expect(check.last).not_to be_success

      run("check.rb", "--fix")

      output, status = run("check.rb")
      expect(status).to be_success, output
      expect(File.readlines(File.join(repo, "docs/intent/me.md")).map { _1.chomp.length }.max).to be <= 79
    end
  end

  describe "intent-nag.rb" do
    it "counts your staged days as unwritten when only a teammate has logged" do
      [ 3, 4, 5 ].each { write(".intent/staging/#{Date.today - _1}.jsonl", "{}\n") }
      entry("teammate", "theirs", heading: Date.today.strftime("%a %b %-d, %Y"))
      run("compose.rb")

      output, status = run("intent-nag.rb", env: { "INTENT_AUTHOR" => "me", "CLAUDE_PROJECT_DIR" => repo }, stdin: "{}")
      expect(status.exitstatus).to eq(2)
      expect(output).to include("3 days behind", "docs/intent/me.md")
    end

    it "reads a range heading through its last day" do
      %w[2026-10-16 2026-10-17 2026-10-18].each { write(".intent/staging/#{_1}.jsonl", "{}\n") }
      entry("me", "a long weekend", heading: "Thu Oct 15-18, 2026")

      output, status = run("intent-nag.rb", env: { "INTENT_AUTHOR" => "me", "CLAUDE_PROJECT_DIR" => repo }, stdin: "{}")
      expect(status.exitstatus).to eq(0), output
    end
  end

  describe "extract.rb" do
    it "keeps two quick prompts that share a long opening but differ after it" do
      shared = "Here is the stack trace from the failing job, pasted in full so you can see it: #{"x" * 80}"
      turns = [ [ "15:00:00", "#{shared} fix the retry" ], [ "15:01:00", "#{shared} actually, revert it instead" ] ]
      encoded = File.expand_path(repo).tr("/", "-")
      write("home/.claude/projects/#{encoded}/s.jsonl", turns.map do |time, text|
        JSON.generate("type" => "user", "timestamp" => "2026-10-20T#{time}Z", "message" => { "content" => text })
      end.join("\n") + "\n")

      output, status = run("extract.rb", "dump", "2026-10-20", "--repo", repo, "--cap", "1000",
                           env: { "HOME" => File.join(repo, "home"), "TZ" => "UTC" })
      expect(status).to be_success, output
      expect(output).to include("fix the retry", "actually, revert it instead")
    end
  end

  describe "intent-stage.rb" do
    it "stages under the project dir even when the session started in a subdirectory" do
      write("transcript.jsonl", JSON.generate("type" => "user", "timestamp" => "2026-10-20T15:00:00Z",
                                              "message" => { "content" => "add the swap sheet" }) + "\n")
      event = { "transcript_path" => File.join(repo, "transcript.jsonl"), "cwd" => File.join(repo, "app"), "session_id" => "s" }

      run("intent-stage.rb", env: { "CLAUDE_PROJECT_DIR" => repo, "TZ" => "UTC" }, stdin: JSON.generate(event))
      expect(File.read(File.join(repo, ".intent/staging/2026-10-20.jsonl"))).to include("add the swap sheet")
      expect(Dir.exist?(File.join(repo, "app/.intent"))).to be(false)
    end
  end
end
