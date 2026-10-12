require "zlib"

module PngPixels
  CHANNELS = { 2 => 3, 6 => 4 }.freeze

  module_function

  def inside_ico(path)
    ico = File.binread(path)
    Array.new(ico.byteslice(4, 2).unpack1("v")) do |index|
      size, offset = ico.byteslice(6 + (16 * index) + 8, 8).unpack("VV")
      ico.byteslice(offset, size)
    end
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

  def unfilter(filter, row, previous, bytes_per_pixel)
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

  def rows(png)
    header = chunks(png).find { |type, _| type == "IHDR" }.last
    width, height, depth, color_type = header.unpack("NNCC")
    bytes_per_pixel = CHANNELS[color_type]
    raise "expected 8-bit RGB or RGBA, got depth #{depth} color type #{color_type}" unless depth == 8 && bytes_per_pixel

    stride = width * bytes_per_pixel
    data = Zlib::Inflate.inflate(chunks(png).select { |type, _| type == "IDAT" }.map(&:last).join).bytes
    previous = Array.new(stride, 0)
    Array.new(height) do |y|
      filter, *row = data[y * (stride + 1), stride + 1]
      unfilter(filter, row, previous, bytes_per_pixel)
      previous = row
      row.each_slice(bytes_per_pixel).to_a
    end
  end
end
