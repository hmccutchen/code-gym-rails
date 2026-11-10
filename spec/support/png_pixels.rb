require "chunky_png"

module PngPixels
  module_function

  def inside_ico(path)
    ico = File.binread(path)
    Array.new(ico.byteslice(4, 2).unpack1("v")) do |index|
      size, offset = ico.byteslice(6 + (16 * index) + 8, 8).unpack("VV")
      ico.byteslice(offset, size)
    end
  end

  def rows(png)
    image = ChunkyPNG::Image.from_blob(png)
    image.height.times.map do |y|
      image.row(y).map { |pixel| ChunkyPNG::Color.to_truecolor_alpha_bytes(pixel) }
    end
  end
end
