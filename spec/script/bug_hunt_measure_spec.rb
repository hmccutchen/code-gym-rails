require "rails_helper"
require "open3"
require Rails.root.join("script/bug_hunt_measure/build")
require Rails.root.join("script/bug_hunt_measure/report")

module BugHuntMeasureFixtures
  def self.section(registry_id, language, snippet, key, rung: "mid_level")
    { "kind" => "code_review", "language" => language, "registry_id" => registry_id, "rung" => rung, "concept" => "c",
      "purpose" => "Do the thing.", "shown" => { "snippet" => snippet }, "answer_key" => key }
  end

  def self.key(witness: nil, looks_right_on: nil, fixed_snippet: nil)
    { "issue" => "i", "why_it_matters" => "w", "fix" => "f", "witness" => witness, "looks_right_on" => looks_right_on,
      "fixed_snippet" => fixed_snippet }.compact
  end

  RUBY = [
    section("rb_delete_while_each", "ruby_rails", "def remove_evens(nums)\n  nums.each { |n| nums.delete(n) if n.even? }\n  nums\nend",
            key(witness: { "call" => "remove_evens([1, 2, 4, 5])", "expected" => "[1, 5]", "returns" => "[1, 4, 5]" },
                looks_right_on: { "call" => "remove_evens([1, 2, 3, 4])", "expected" => "[1, 3]" },
                fixed_snippet: "def remove_evens(nums)\n  nums.reject(&:even?)\nend")),
    section("rb_bang_returns_nil", "ruby_rails", "def tag_count(tags)\n  tags.uniq!.size\nend",
            key(witness: { "call" => "tag_count([\"a\", \"b\"])", "expected" => "2", "returns" => "raises NoMethodError" },
                fixed_snippet: "def tag_count(tags)\n  tags.uniq.size\nend")),
    section("rb_integer_division", "ruby_rails", "def share(n)\n  loop {} if n.zero?\n  n\nend",
            key(witness: { "call" => "share(1)", "expected" => "2", "returns" => "1" },
                looks_right_on: { "call" => "share(0)", "expected" => "0" })),
    section("rb_split_remainder", "ruby_rails", "def split(n)\n  exit 3\nend",
            key(witness: { "call" => "split(3)", "expected" => "1", "returns" => "1" })),
    section("rb_float_equality", "ruby_rails", "def total(x",
            key(witness: { "call" => "total(1)", "expected" => "1", "returns" => "1" })),
    section("rb_to_i_silent", "ruby_rails", "def quantity(text)\n  Order.find(text)\nend",
            key(witness: { "call" => "quantity(\"3\")", "expected" => "3", "returns" => "3" })),
    section("rb_ensure_return", "ruby_rails", "def save\n  :ok\nend", key(witness: { "call" => "save", "expected" => "[1," }))
  ].freeze

  JAVASCRIPT = [
    section("js_foreach_async", "javascript",
            "const save = async (item) => item;\n\nexport async function saveAll(items) {\n  const saved = [];\n" \
            "  items.forEach(async (item) => {\n    saved.push(await save(item));\n  });\n  return [...saved];\n}",
            key(witness: { "call" => "saveAll([\"a\", \"b\"])", "expected" => "[\"a\", \"b\"]", "returns" => "[]" },
                fixed_snippet: "const save = async (item) => item;\n\nexport async function saveAll(items) {\n  const saved = [];\n" \
                               "  for (const item of items) {\n    saved.push(await save(item));\n  }\n  return [...saved];\n}")),
    section("js_sort_mutates", "javascript",
            "const save = async (item) => item;\n\nexport async function saveAll(items) {\n  const saved = [];\n" \
            "  items.forEach(async (item) => {\n    saved.push(await save(item));\n  });\n  return saved;\n}",
            key(witness: { "call" => "saveAll([\"a\", \"b\"])", "expected" => "[\"a\", \"b\"]", "returns" => "[]" })),
    section("js_detached_method", "javascript", "class Counter {\n  count = 0;\n  increment() { this.count += 1; }\n}",
            key(witness: { "call" => "(() => { const run = new Counter().increment; return run(); })()", "expected" => "1",
                           "returns" => "raises TypeError" })),
    section("js_fill_shared", "javascript", "const grid = new Array(3).fill(;",
            key(witness: { "call" => "grid", "expected" => "[]", "returns" => "[]" })),
    section("js_default_sort", "javascript", "export const sorted = (xs) => xs;",
            key(witness: { "call" => "fetchScores()", "expected" => "[]", "returns" => "[]" }))
  ].freeze

  def self.write(dir, sections)
    path = File.join(dir, "drafts.json")
    File.write(path, JSON.pretty_generate("sections" => sections))
    path
  end
end

RSpec.describe BugHuntMeasure::Build do
  let(:dir) { Dir.mktmpdir }
  let(:drafts_path) { BugHuntMeasureFixtures.write(dir, BugHuntMeasureFixtures::RUBY + BugHuntMeasureFixtures::JAVASCRIPT) }
  let(:harness_dir) { File.join(dir, "harness") }

  after { FileUtils.rm_rf(dir) }

  def build = described_class.new(drafts_path, harness_dir).call

  it "names drafts by registry order and writes one harness per check, looks-right checks only where the key has one" do
    build
    lines = File.readlines(File.join(harness_dir, "harnesses.txt"), chomp: true)

    expect(lines).to include("rb01-bug_real ruby rb01-bug_real.rb", "rb01-looks_right ruby rb01-looks_right.rb",
                             "rb01-fix_looks_right ruby rb01-fix_looks_right.rb", "js09-bug_real node js09-bug_real.mjs")
    expect(lines.grep(/\Arb04-/).map { |line| line.split.first })
      .to eq(%w[rb04-bug_real rb04-returns_match rb04-fix_witness])
  end

  it "writes the subject as the code then the call, and a literal file only for a literal" do
    build

    expect(File.read(File.join(harness_dir, "rb01-bug_real.subject.rb"))).to end_with("nums\nend\nremove_evens([1, 2, 4, 5])\n")
    expect(File.read(File.join(harness_dir, "rb01-bug_real.expected.rb"))).to eq("[1, 5]\n")
    expect(File).not_to exist(File.join(harness_dir, "rb04-returns_match.expected.rb"))
    expect(File.read(File.join(harness_dir, "rb04-returns_match.rb"))).to include('SPEC     = { "raises" => "NoMethodError" }')
    expect(File.read(File.join(harness_dir, "js09-bug_real.subject.mjs")))
      .to end_with("export const __bughuntResult = await (async () => (saveAll([\"a\", \"b\"])))();\n")
    expect(File.read(File.join(harness_dir, "js09-bug_real.expected.mjs"))).to eq("export default ([\"a\", \"b\"]);\n")
  end

  it "writes a harness whose key part is missing as one that reports key_unparsable" do
    build

    expect(File.read(File.join(harness_dir, "rb07-fix_witness.rb"))).to include("SPEC     = nil")
    expect(File.read(File.join(harness_dir, "rb11-returns_match.rb"))).to include("SPEC     = nil")
  end

  it "keeps the manifest out of the archive, at its top level with no links, run.sh executable" do
    built = build
    members = []
    Zlib::GzipReader.open(built[:archive]) do |gzip|
      Gem::Package::TarReader.new(gzip) { |tar| tar.each { |entry| members << [ entry.full_name, entry.header.mode, entry.symlink? ] } }
    end

    expect(members.map(&:first)).to include("run.sh", "harnesses.txt", "build_id", "rb01-bug_real.rb")
    expect(members.map(&:first)).not_to include("manifest.json")
    expect(members.map(&:first)).to all(satisfy { |name| !name.include?("/") })
    expect(members.find { |name, _, _| name == "run.sh" }[1]).to eq(0o755)
    expect(members.map(&:last)).to all(be(false))
    expect(built[:sha256]).to eq(Digest::SHA256.file(built[:archive]).hexdigest)
  end

  it "records the build id, the drafts and every harness in the manifest" do
    build
    manifest = JSON.parse(File.read(File.join(harness_dir, "manifest.json")))

    expect(manifest["build_id"]).to eq(File.read(File.join(harness_dir, "build_id")).strip)
    expect(manifest["drafts"].map { |draft| draft["draft"] }).to include("rb01", "js09")
    expect(manifest["drafts"].first).to include("registry_id" => "rb_delete_while_each", "lines" => 4, "longest_line" => 45)
    expect(manifest["harnesses"].first).to eq("harness" => "rb01-bug_real", "draft" => "rb01", "check" => "bug_real", "runtime" => "ruby")
  end

  it "reads one drafts file per language into one folder" do
    ruby = BugHuntMeasureFixtures.write(Dir.mktmpdir, BugHuntMeasureFixtures::RUBY.first(1))
    node = BugHuntMeasureFixtures.write(Dir.mktmpdir, BugHuntMeasureFixtures::JAVASCRIPT.first(1))

    expect(described_class.new([ ruby, node ], harness_dir).call[:drafts]).to eq(2)
  end

  it "runs nothing it writes" do
    expect(Kernel).not_to receive(:system)
    expect(Open3).not_to receive(:capture2e)
    expect(Open3).not_to receive(:popen3)
    allow_any_instance_of(described_class).to receive(:`).and_raise("ran a command")
    allow_any_instance_of(described_class).to receive(:system).and_raise("ran a command")

    build
  end

  it "refuses a folder inside the repository, one that exists, and an entry the registry doesn't hold" do
    expect { described_class.new(drafts_path, Rails.root.join("tmp", "bug-hunt-harness").to_s) }.to raise_error(ArgumentError, /outside/)
    FileUtils.mkdir_p(harness_dir)
    expect { described_class.new(drafts_path, harness_dir) }.to raise_error(ArgumentError, /already exists/)

    stray = BugHuntMeasureFixtures.write(Dir.mktmpdir, [ BugHuntMeasureFixtures.section("rb_cut", "ruby_rails", "x", {}) ])
    expect { described_class.new(stray, File.join(dir, "other")).call }.to raise_error(ArgumentError, /isn't in the ruby_rails registry/)
  end
end

RSpec.describe "the bug_hunt harness runner", :runs_code do
  let(:dir) { Dir.mktmpdir }
  let(:workspace) { Dir.mktmpdir }

  before do
    tools = %w[bash node].all? { |tool| system("command -v #{tool} > /dev/null 2>&1") } &&
            (system("command -v timeout > /dev/null 2>&1") || system("command -v gtimeout > /dev/null 2>&1"))
    skip "needs bash, node and timeout" unless tools
  end

  after { FileUtils.rm_rf([ dir, workspace ]) }

  def results(sections, only)
    built = BugHuntMeasure::Build.new(BugHuntMeasureFixtures.write(dir, sections), File.join(dir, "harness")).call
    system("tar", "-xzf", built[:archive], "-C", workspace, exception: true)
    output, status = Open3.capture2e({ "BUGHUNT_NETWORK_OFF" => "never" }, "bash", File.join(workspace, "run.sh"), only)
    expect(status).to be_success, output

    lines = File.readlines(File.join(workspace, "results.jsonl"), chomp: true).map { |line| JSON.parse(line) }
    [ lines.first, lines.drop(1).to_h { |line| [ line["harness"], line.except("harness") ] } ]
  end

  it "runs every Ruby harness from the extracted archive and reports each outcome" do
    run, by_harness = results(BugHuntMeasureFixtures::RUBY, "ruby")

    expect(run).to include("network" => "on", "runtime" => { "ruby" => RUBY_VERSION })
    expect(by_harness).to include(
      "rb01-bug_real" => { "outcome" => "pass", "reason" => "mismatched" },
      "rb01-returns_match" => { "outcome" => "pass", "reason" => "matched" },
      "rb01-looks_right" => { "outcome" => "pass", "reason" => "matched" },
      "rb01-fix_witness" => { "outcome" => "pass", "reason" => "matched" },
      "rb04-bug_real" => { "outcome" => "pass", "reason" => "mismatched", "error" => "NoMethodError" },
      "rb04-returns_match" => { "outcome" => "pass", "reason" => "matched", "error" => "NoMethodError" },
      "rb07-looks_right" => { "outcome" => "not_runnable", "reason" => "timeout" },
      "rb07-fix_witness" => { "outcome" => "not_runnable", "reason" => "key_unparsable" },
      "rb08-bug_real" => { "outcome" => "not_runnable", "reason" => "no_result" },
      "rb09-bug_real" => { "outcome" => "not_runnable", "reason" => "syntax" },
      "rb10-bug_real" => { "outcome" => "not_runnable", "reason" => "not_core", "error" => "NameError" },
      "rb11-bug_real" => { "outcome" => "not_runnable", "reason" => "key_unparsable" },
      "rb11-returns_match" => { "outcome" => "not_runnable", "reason" => "key_unparsable" }
    )
  end

  it "runs every JavaScript harness as an ES module, comparing a snapshot after pending promises settle" do
    _run, by_harness = results(BugHuntMeasureFixtures::JAVASCRIPT, "node")

    expect(by_harness).to include(
      "js09-bug_real" => { "outcome" => "pass", "reason" => "mismatched" },
      "js09-returns_match" => { "outcome" => "pass", "reason" => "matched" },
      "js09-fix_witness" => { "outcome" => "pass", "reason" => "matched" },
      "js02-bug_real" => { "outcome" => "fail", "reason" => "matched" },
      "js07-returns_match" => { "outcome" => "pass", "reason" => "matched", "error" => "TypeError" },
      "js03-bug_real" => { "outcome" => "not_runnable", "reason" => "syntax" },
      "js04-bug_real" => { "outcome" => "not_runnable", "reason" => "not_core", "error" => "ReferenceError" }
    )
  end
end

RSpec.describe BugHuntMeasure::Report do
  let(:dir) { Dir.mktmpdir }
  let(:harness_dir) { File.join(dir, "harness") }
  let(:out_dir) { File.join(dir, "out") }
  let(:sections) { BugHuntMeasureFixtures::RUBY.first(2) + BugHuntMeasureFixtures::JAVASCRIPT.first(1) }
  let(:manifest) do
    BugHuntMeasure::Build.new(BugHuntMeasureFixtures.write(dir, sections), harness_dir).call
    JSON.parse(File.read(File.join(harness_dir, "manifest.json")))
  end

  after { FileUtils.rm_rf(dir) }

  def results(lines, build: manifest["build_id"], runtime: { "ruby" => "3.3.6", "node" => "22.11.0" })
    path = File.join(dir, "results-#{SecureRandom.hex(3)}.jsonl")
    File.write(path, ([ { "build" => build, "network" => "off", "runtime" => runtime }.to_json ] + lines.map(&:to_json)).join("\n") + "\n")
    path
  end

  def all_pass(except: {})
    manifest["harnesses"].map do |harness|
      except.fetch(harness["harness"]) { { "outcome" => "pass", "reason" => harness["check"] == "bug_real" ? "mismatched" : "matched" } }
            .merge("harness" => harness["harness"])
    end
  end

  def report(*paths, seed: 7) = described_class.new(harness_dir, paths, out_dir, seed: seed).call

  it "counts every check and writes a sheet holding only failures and the seeded sample" do
    path = results(all_pass(except: { "rb04-fix_witness" => { "outcome" => "fail", "reason" => "mismatched" } }))

    counts = report(path)

    expect(counts).to include("check 1: pass 3", "check 4: pass 2 · fail 1", "drafts failing check 1, 3 or 4: 1 of 3",
                              "at most 2: ship as specified", "rb_bang_returns_nil: failed check 4", "network off", "sample seed: 7")
    sheet = File.read(File.join(out_dir, "failures.md"))
    expect(sheet).to include("## Failures (1)", "### rb04 · rb_bang_returns_nil", "rb04-fix_witness.subject.rb:")
    expect(sheet).to include("## Passing sample (seed 7)")
  end

  it "counts a harness that couldn't run as a failure of its check, and not_core as a failure of check 5" do
    path = results(all_pass(except: { "rb01-bug_real" => { "outcome" => "not_runnable", "reason" => "not_core", "error" => "NameError" } }))

    expect(report(path)).to include("check 1: pass 2 · fail 1", "check 5: pass 2 · fail 1", "rb_delete_while_each: failed check 1, check 5")
  end

  it "says sandbox question when more than two drafts fail checks 1, 3 or 4" do
    failing = manifest["harnesses"].select { |harness| harness["check"] == "bug_real" }
                                   .to_h { |harness| [ harness["harness"], { "outcome" => "fail", "reason" => "matched" } ] }

    expect(report(results(all_pass(except: failing)))).to include("3 of 3 (more than 2: sandbox question)")
  end

  it "repeats the passing sample's pick with the same seed" do
    path = results(all_pass)
    report(path, seed: 11)
    first = File.read(File.join(out_dir, "failures.md"))
    FileUtils.rm_rf(out_dir)
    report(path, seed: 11)

    expect(File.read(File.join(out_dir, "failures.md"))).to eq(first)
  end

  it "takes one results file per runtime" do
    lines = all_pass
    ruby  = results(lines.select { |line| line["harness"].start_with?("rb") }, runtime: { "ruby" => "3.3.6" })
    node  = results(lines.select { |line| line["harness"].start_with?("js") }, runtime: { "node" => "22.1.0" })

    expect(report(ruby, node)).to include("drafts: 3")
  end

  {
    "another build"         => -> { [ results(all_pass, build: "000000000000") ] },
    "another Ruby"          => -> { [ results(all_pass, runtime: { "ruby" => "3.4.1", "node" => "22.1.0" }) ] },
    "another Node major"    => -> { [ results(all_pass, runtime: { "ruby" => "3.3.6", "node" => "20.1.0" }) ] },
    "a missing harness"     => -> { [ results(all_pass.drop(1)) ] },
    "a repeated harness"    => -> { [ results(all_pass + all_pass.first(1)) ] },
    "an unknown harness"    => -> { [ results(all_pass + [ { "harness" => "rb99-bug_real", "outcome" => "pass", "reason" => "matched" } ]) ] },
    "a reason off the list" => -> { [ results(all_pass(except: { "rb01-bug_real" => { "outcome" => "pass", "reason" => "maybe" } })) ] },
    "an extra key"          => -> { [ results(all_pass(except: { "rb01-bug_real" => { "outcome" => "pass", "reason" => "matched", "note" => "x" } })) ] },
    "a runtime not run"     => -> { [ results(all_pass, runtime: { "ruby" => "3.3.6" }) ] }
  }.each do |problem, paths|
    it "refuses, writing nothing, on #{problem}" do
      given = instance_exec(&paths)

      expect { report(*given) }.to raise_error(described_class::Refused)
      expect(File).not_to exist(out_dir)
    end
  end

  it "refuses an output folder inside the repository" do
    manifest
    expect { described_class.new(harness_dir, [], Rails.root.join("tmp", "bug-hunt-out").to_s) }.to raise_error(ArgumentError, /outside/)
  end
end
