require "spec_helper"
require "zlib"

# script/generate_icons.py needs Pillow, which CI lacks, so this checks the favicon it wrote.
RSpec.describe "public/favicon.ico" do
  let(:bytes_per_pixel) { 4 }

  def png_inside_ico(path)
    ico = File.binread(path)
    size, offset = ico.byteslice(6 + 8, 8).unpack("VV")
    ico.byteslice(offset, size)
  end

  def chunks(png)
    position = 8
    Enumerator.new do |yielder|
      while position < png.bytesize
        length, type = png.byteslice(position, 8).unpack("Na4")
        yielder << [ type, png.byteslice(position + 8, length) ]
        position += 12 + length
      end
    end
  end

  def paeth(left, up, up_left)
    estimate = left + up - up_left
    [ left, up, up_left ].min_by.with_index { |value, index| [ (estimate - value).abs, index ] }
  end

  def unfilter(filter, row, previous)
    row.each_index do |i|
      left = i >= bytes_per_pixel ? row[i - bytes_per_pixel] : 0
      up_left = i >= bytes_per_pixel ? previous[i - bytes_per_pixel] : 0
      predictor = case filter
      when 0 then 0
      when 1 then left
      when 2 then previous[i]
      when 3 then (left + previous[i]) / 2
      when 4 then paeth(left, previous[i], up_left)
      end
      row[i] = (row[i] + predictor) & 0xFF
    end
  end

  def alpha_rows(png)
    header = chunks(png).find { |type, _| type == "IHDR" }.last
    width, height, depth, color_type = header.unpack("NNCC")
    raise "expected 8-bit RGBA, got depth #{depth} color type #{color_type}" unless [ depth, color_type ] == [ 8, 6 ]

    stride = width * bytes_per_pixel
    data = Zlib::Inflate.inflate(chunks(png).select { |type, _| type == "IDAT" }.map(&:last).join).bytes
    previous = Array.new(stride, 0)
    Array.new(height) do |y|
      filter, *row = data[y * (stride + 1), stride + 1]
      unfilter(filter, row, previous)
      previous = row
      row.each_slice(bytes_per_pixel).map(&:last)
    end
  end

  let(:rows) { alpha_rows(png_inside_ico(File.expand_path("../../public/favicon.ico", __dir__))) }

  it "is 32 by 32" do
    expect([ rows.first.size, rows.size ]).to eq([ 32, 32 ])
  end

  it "is cropped so the artwork fills nearly the full height of the tab icon" do
    occupied = rows.each_index.select { |y| rows[y].any?(&:positive?) }

    expect(occupied.last - occupied.first + 1).to be >= 29
  end
end
