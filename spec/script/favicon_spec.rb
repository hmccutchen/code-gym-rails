require "spec_helper"
require_relative "../support/png_pixels"

# script/generate_icons.py needs Pillow, which CI lacks, so this checks the favicons it wrote.
RSpec.describe "public favicons" do
  def public_file(name) = File.expand_path("../../public/#{name}", __dir__)
  def size_of(rows) = [ rows.first.size, rows.size ]
  def opaque?(rows) = rows.flatten(1).map { |pixel| pixel[3] || 255 }.uniq == [ 255 ]

  let(:ico_frames) { PngPixels.inside_ico(public_file("favicon.ico")).map { |png| PngPixels.rows(png) } }
  let(:png_rows) { PngPixels.rows(File.binread(public_file("favicon-96.png"))) }

  it "carries 16, 32 and 48 pixel frames in favicon.ico, so no browser enlarges a smaller one" do
    expect(ico_frames.map { |rows| size_of(rows) }).to eq([ [ 16, 16 ], [ 32, 32 ], [ 48, 48 ] ])
  end

  it "has a 96 pixel PNG for high-density screens" do
    expect(size_of(png_rows)).to eq([ 96, 96 ])
  end

  it "keeps every frame opaque, so each carries its own navy fill on any tab" do
    expect(ico_frames + [ png_rows ]).to all(satisfy { |rows| opaque?(rows) })
  end
end
