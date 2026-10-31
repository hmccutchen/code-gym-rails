require "rails_helper"
require "open3"

RSpec.describe "script/draft_key_samples.rb" do
  it "refuses --run without --max-cost, before reserving the file or making a call" do
    dir = Dir.mktmpdir
    path = File.join(dir, "keys.json")
    env = { "ANTHROPIC_API_KEY" => "sk-ant-test", "RAILS_ENV" => "test" }

    output, status = Open3.capture2e(env, "bin/rails", "runner", "script/draft_key_samples.rb", "code_review", path, "--count", "1", "--run",
                                     chdir: Rails.root.to_s)

    expect(status).not_to be_success
    expect(output).to include("Pass --max-cost DOLLARS with --run.")
    expect(File).not_to exist(path)
  ensure
    FileUtils.rm_rf(dir)
  end
end
