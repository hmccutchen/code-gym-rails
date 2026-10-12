require "rails_helper"

RSpec.describe PublicFileHelper, type: :helper do
  it "versions a public file's path with a digest of its bytes" do
    digest = Digest::SHA256.file(Rails.public_path.join("icon-192.png")).hexdigest.first(8)

    expect(helper.versioned_public_path("icon-192.png")).to eq("/icon-192.png?v=#{digest}")
  end

  it "gives files with different bytes different versions" do
    expect(helper.versioned_public_path("icon-192.png").split("?v=").last)
      .not_to eq(helper.versioned_public_path("apple-touch-icon.png").split("?v=").last)
  end
end
