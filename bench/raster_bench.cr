# bench/raster_bench.cr
require "benchmark"
require "../src/asekii-term/common/raster"

module Bench::Raster
  extend self

  def build : Asekii::Raster
    width = 64
    height = 64
    data = Bytes.new(width * height * 4)
    (width * height).times do |index|
      x = index % width
      y = index // width
      data[index * 4] = (x * 4).to_u8
      data[index * 4 + 1] = (y * 4).to_u8
      data[index * 4 + 2] = ((x + y) * 2).to_u8
      data[index * 4 + 3] = 255_u8
    end
    Asekii::Raster.rgba(data, width, height).not_nil!
  end

  def run : Nil
    raster = build
    png = raster.to_png

    puts "\nraster"

    Benchmark.ips(1.second, 200.milliseconds, false) do |job|
      job.report("Raster.to_png 64x64") { raster.to_png }
      job.report("Raster.png decode 64x64") { Asekii::Raster.png(png) }
      job.report("Raster.scale 64->32") { raster.scale(32, 32) }
      job.report("Raster.to_sixel 64x64") { raster.to_sixel }
      job.report("Raster.rgba wrap") { Asekii::Raster.rgba(raster.data, 64, 64) }
    end
  end
end

Bench::Raster.run
