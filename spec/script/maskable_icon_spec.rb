require "spec_helper"
require_relative "../support/png_pixels"

# CI lacks Pillow, so this repeats the script's safe-zone check on the icon it wrote, reading its limits from the script.
RSpec.describe "public/icon-maskable-512.png" do
  let(:script) { File.read(File.expand_path("../../script/generate_icons.py", __dir__)) }
  let(:safe_radius) { script[/^MASKABLE_SAFE_RADIUS = ([\d.]+)$/, 1].to_f }
  let(:fill_tolerance) { script[/^FILL_TOLERANCE = (\d+)$/, 1].to_i }
  let(:rows) { PngPixels.rows(File.binread(File.expand_path("../../public/icon-maskable-512.png", __dir__))) }

  def farthest_mark_reach(rows, tolerance)
    fill = rows.first.first
    center = rows.size / 2.0
    rows.each_with_index.flat_map do |row, y|
      row.each_with_index.filter_map do |pixel, x|
        next unless pixel.zip(fill).any? { |channel, fill_channel| (channel - fill_channel).abs > tolerance }

        Math.hypot(x + 0.5 - center, y + 0.5 - center)
      end
    end.max
  end

  it "keeps the mark inside the 80% safe-zone circle every platform mask keeps" do
    expect(safe_radius).to be_positive
    expect(farthest_mark_reach(rows, fill_tolerance)).to be <= safe_radius * rows.size
  end
end
