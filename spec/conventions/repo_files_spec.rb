require "rails_helper"

RSpec.describe "Conventions held over the repository's own files" do
  REFERENCE_DOCS = %w[CLAUDE.md .github/copilot-instructions.md].freeze
  REFERENCE_ROOTS = %w[app lib spec config docs bin db script .claude .github].freeze
  GITIGNORED_REFERENCES = %w[spec/examples.txt].freeze
  BARE_EXTENSIONS = %w[rb yml yaml toml md json js].freeze

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  def ci_workflow = YAML.load_file(Rails.root.join(".github/workflows/ci.yml"))

  def instruction_docs
    REFERENCE_DOCS.map { |path| Rails.root.join(path).to_s } + Dir[Rails.root.join(".claude/{rules,agents}/*.md")].sort
  end

  def referenced_paths(path)
    roots = REFERENCE_ROOTS.map { |root| Regexp.escape(root) }.join("|")
    pattern = Regexp.new("`((?:#{roots})/[^`\\s<*{]+|\\.?[\\w-]+(?:\\.[\\w-]+)*\\.(?:#{BARE_EXTENSIONS.join('|')}))`")
    File.readlines(path).each_with_index.flat_map do |line, index|
      line.gsub(/~~.*?~~/, "").scan(pattern).flatten.map { |reference| [ reference.sub(/[:#]\d+.*\z/, "").sub(/[.,;:]\z/, ""), index + 1 ] }
    end
  end

  def tracked_basenames = @tracked_basenames ||= `git -C #{Rails.root} ls-files`.split("\n").map { |file| File.basename(file) }.to_set

  def reference_exists?(reference)
    return true if GITIGNORED_REFERENCES.include?(reference) || Rails.root.join(reference).exist?

    !reference.include?("/") && tracked_basenames.include?(reference)
  end

  def missing_references(doc)
    referenced_paths(doc).reject { |reference, _line| reference_exists?(reference) }
  end

  it "names only files that exist whenever an instruction doc gives a repository path" do
    missing = instruction_docs.flat_map { |doc| missing_references(doc).map { |reference, line| "#{relative(doc)}:#{line}: #{reference}" } }

    expect(missing).to be_empty, "paths named in instructions that do not exist:\n#{missing.join("\n")}"
  end

  it "checks a bare filename too, finding it at the root or under any folder, and flags one that exists nowhere" do
    doc = Tempfile.new([ "doc", ".md" ])
    doc.write("read `.rubocop_todo.yml` and `ai_service.rb` but not `.rubocop_todo_deleted.yml`\n")
    doc.close

    expect(missing_references(doc.path).map(&:first)).to eq([ ".rubocop_todo_deleted.yml" ])
  end

  it "ignores a struck-through reference, which records a file that was deleted, and keeps the rest of the line" do
    doc = Tempfile.new([ "doc", ".md" ])
    doc.write("~~delete `spec/gone_spec.rb`~~ and read `spec/rails_helper.rb`\n")
    doc.close

    expect(referenced_paths(doc.path).map(&:first)).to eq([ "spec/rails_helper.rb" ])
  end

  it "uploads failure screenshots from the folder Capybara saves them to" do
    upload = ci_workflow.dig("jobs", "system_test", "steps").find { |step| step["name"] == "Upload failure screenshots" }

    expect(upload).to be_present, "ci.yml's system_test job has no step named Upload failure screenshots"
    expect(Rails.root.join(upload.dig("with", "path"))).to eq(Pathname(Capybara.save_path))
  end

  it "pins every CI job to ubuntu-24.04 rather than a moving label" do
    runners = ci_workflow.fetch("jobs").transform_values { |job| job["runs-on"] }

    expect(runners.reject { |_job, runner| runner == "ubuntu-24.04" }).to be_empty
  end

  def table_documented?(rows, table)
    rows.any? { |row| row.start_with?("| `#{table.classify}`") || row.match?(/\A\| `\w+` \| table `#{table}`:/) }
  end

  it "counts a table as documented by its model's row or a table alias in that row's own position, not a passing mention" do
    rows = [ "| `DailyKindSwapEvent` | table `daily_kind_swaps`: user_id |", "| `User` | see also table `invite_codes` for the other side |" ]

    expect(table_documented?(rows, "daily_kind_swaps")).to be(true)
    expect(table_documented?(rows, "users")).to be(true)
    expect(table_documented?(rows, "invite_codes")).to be(false)
  end

  it "lists every table in the models rule's table, so a new model is documented where its rule loads" do
    rows = File.readlines(Rails.root.join(".claude/rules/models.md")).select { |line| line.start_with?("| `") }
    tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]
    undocumented = tables.reject { |table| table.start_with?("solid_") || table_documented?(rows, table) }

    expect(undocumented).to be_empty, "tables with no row in .claude/rules/models.md: #{undocumented.join(', ')}"
  end

  def rooted?(token) = REFERENCE_ROOTS.any? { |root| token.start_with?("#{root}/") }

  def entry_paths(text)
    text.lines.select { |line| line.start_with?("- `") }.flat_map { |line| resolved_paths(line.split(" — ", 2).first.scan(/`([^`\s]+)`/).flatten) }.to_set
  end

  def resolved_paths(tokens)
    folder = tokens.find { |token| rooted?(token) }&.then { |token| File.dirname(token) }
    tokens.map { |token| rooted?(token) || folder.nil? || token.end_with?("/") ? token : File.join(folder, token) }
  end

  def file_map_paths = @file_map_paths ||= entry_paths(File.read(Rails.root.join("docs/file-map.md")))

  def mapped?(path, paths = file_map_paths) = paths.include?(path)

  def mappable_files
    tracked = `git -C #{Rails.root} ls-files app lib bin script config`.split("\n")
    tracked.reject { |path| path.start_with?("app/views/") }.select { |path| path.start_with?("bin/") || path.match?(/\.(rb|js|py)\z/) }
  end

  it "lists every .rb, .js and .py file under app (outside the views), lib, script and config, and every bin file, in docs/file-map.md" do
    unlisted = mappable_files.reject { |path| mapped?(path) }

    expect(unlisted).to be_empty, "files with no entry in docs/file-map.md:\n#{unlisted.join("\n")}"
  end

  it "names only files that exist in every entry's file list, reading folders as written" do
    missing = file_map_paths.reject { |path| path.end_with?("/") || Rails.root.join(path).exist? }

    expect(missing).to be_empty, "docs/file-map.md names files that do not exist:\n#{missing.sort.join("\n")}"
  end

  it "takes a file's paths from the file list that opens an entry, not from a name its description mentions" do
    map = "- `app/javascript/controllers/application.js` — starts Stimulus; `index.js` loads the rest.\n"

    expect(mapped?("app/javascript/controllers/index.js", entry_paths(map))).to be(false)
    expect(mapped?("app/javascript/controllers/application.js", entry_paths(map))).to be(true)
  end

  it "reads a short name in a grouped entry below the folder of the entry's first full path, and no other folder" do
    map = "- `app/models/house_keys.rb` / `trial_mode.rb` — keys.\n- `app/models/a/b.rb` (+ `b/c.rb`, `Archspec.rb`) — grouped.\n"
    paths = entry_paths(map)

    expect(mapped?("app/models/trial_mode.rb", paths)).to be(true)
    expect(mapped?("app/services/trial_mode.rb", paths)).to be(false)
    expect(mapped?("app/models/a/b/c.rb", paths)).to be(true)
    expect(mapped?("app/models/b/c.rb", paths)).to be(false)
    expect(mapped?("lib/x/b/c.rb", paths)).to be(false)
  end

  it "reads a file as listed by its full path and an unknown file as unlisted" do
    expect(mapped?("app/models/coverage_exception/history.rb")).to be(true)
    expect(mapped?("app/models/definitely_not_a_file_xyz.rb")).to be(false)
  end
end
