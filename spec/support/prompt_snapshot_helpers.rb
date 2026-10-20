module PromptSnapshotHelpers
  PROMPT_SNAPSHOT_DIR = Rails.root.join("spec/fixtures/family_prompt_snapshots").freeze

  # Rebaseline with UPDATE_PROMPT_SNAPSHOTS=1 only when a prompt change is the intended deliverable.
  def expect_prompt_snapshot(name, text)
    path = PROMPT_SNAPSHOT_DIR.join("#{name}.txt")
    File.write(path, text) if ENV["UPDATE_PROMPT_SNAPSHOTS"]

    expect(path).to exist,
      "No snapshot at #{path.relative_path_from(Rails.root)}. Record it against unmodified code with UPDATE_PROMPT_SNAPSHOTS=1."
    expect(text).to eq(File.read(path))
  end
end

RSpec.configure do |config|
  config.include PromptSnapshotHelpers
end
