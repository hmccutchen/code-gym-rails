require "rails_helper"
require "open3"

RSpec.describe "script/mint_invite_code.rb" do
  it "prints its usage when a required option is missing" do
    output, status = Open3.capture2e({ "RAILS_ENV" => "test" }, "bin/rails", "runner", "script/mint_invite_code.rb",
                                     chdir: Rails.root.to_s)

    expect(status).not_to be_success
    expect(output).to include("--seats N, --days N and --expires DATE are required.", "--label TEXT")
  end
end
