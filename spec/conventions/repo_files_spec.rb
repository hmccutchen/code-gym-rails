require "rails_helper"

RSpec.describe "Conventions held over the repository's own files" do
  REFERENCE_DOCS = %w[CLAUDE.md .github/copilot-instructions.md].freeze
  REFERENCE_ROOTS = %w[app lib spec config docs bin db script .claude .github].freeze
  GITIGNORED_REFERENCES = %w[spec/examples.txt].freeze

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  def instruction_docs
    REFERENCE_DOCS.map { |path| Rails.root.join(path).to_s } + Dir[Rails.root.join(".claude/{rules,agents}/*.md")].sort
  end

  def referenced_paths(path)
    roots = REFERENCE_ROOTS.map { |root| Regexp.escape(root) }.join("|")
    pattern = Regexp.new("`((?:#{roots})/[^`\\s<*{]+)`")
    File.readlines(path).each_with_index.flat_map do |line, index|
      line.gsub(/~~.*?~~/, "").scan(pattern).flatten.map { |reference| [ reference.sub(/[:#]\d+.*\z/, "").sub(/[.,;:]\z/, ""), index + 1 ] }
    end
  end

  it "names only files that exist whenever an instruction doc gives a repository path" do
    missing = instruction_docs.flat_map do |doc|
      referenced_paths(doc).filter_map do |reference, line|
        next if GITIGNORED_REFERENCES.include?(reference) || Rails.root.join(reference).exist?

        "#{relative(doc)}:#{line}: #{reference}"
      end
    end

    expect(missing).to be_empty, "paths named in instructions that do not exist:\n#{missing.join("\n")}"
  end

  it "ignores a struck-through reference, which records a file that was deleted, and keeps the rest of the line" do
    doc = Tempfile.new([ "doc", ".md" ])
    doc.write("~~delete `spec/gone_spec.rb`~~ and read `spec/rails_helper.rb`\n")
    doc.close

    expect(referenced_paths(doc.path).map(&:first)).to eq([ "spec/rails_helper.rb" ])
  end

  it "pins every CI job to ubuntu-24.04 rather than a moving label" do
    runners = YAML.load_file(Rails.root.join(".github/workflows/ci.yml")).fetch("jobs").transform_values { |job| job["runs-on"] }

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
end
