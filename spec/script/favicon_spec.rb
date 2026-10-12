require "spec_helper"
require_relative "../support/png_pixels"

# script/generate_icons.py needs Pillow, which CI lacks, so this checks the favicon it wrote.
RSpec.describe "public/favicon.ico" do
  let(:rows) { PngPixels.rows(PngPixels.inside_ico(File.expand_path("../../public/favicon.ico", __dir__))) }

  it "is 32 by 32" do
    expect([ rows.first.size, rows.size ]).to eq([ 32, 32 ])
  end

  it "is opaque, so it carries its own navy fill on any tab" do
    expect(rows.flatten(1).map(&:last).uniq).to eq([ 255 ])
  end
end
