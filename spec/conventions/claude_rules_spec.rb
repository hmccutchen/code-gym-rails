require "rails_helper"

RSpec.describe "Conventions held over .claude/rules" do
  def rule_files = Dir[Rails.root.join(".claude/rules/*.md")].sort

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  def paths_of(path)
    frontmatter = File.read(path)[/\A---\n(.*?)\n---\n/m, 1]
    frontmatter && YAML.safe_load(frontmatter)&.fetch("paths", nil)
  end

  def alternatives(glob)
    group = glob.match(/\{([^{}]*)\}/)
    return [ glob ] unless group

    group[1].split(",").flat_map { |choice| alternatives(group.pre_match + choice + group.post_match) }
  end

  it "gives every rule file a non-empty paths list" do
    unscoped = rule_files.reject { |path| paths_of(path).is_a?(Array) && paths_of(path).any? }

    expect(unscoped.map { |path| relative(path) }).to be_empty
  end

  it "matches a file with every glob alternative, so a rename cannot silently stop a rule loading" do
    stale = rule_files.flat_map do |path|
      Array(paths_of(path)).flat_map { |glob| alternatives(glob) }.filter_map do |pattern|
        "#{relative(path)}: #{pattern}" if Dir.glob(pattern, base: Rails.root).empty?
      end
    end

    expect(stale).to be_empty
  end
end
