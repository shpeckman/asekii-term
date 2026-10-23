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

  def run : Int64
    raster = build
    png = raster.to_png
    sink = 0_i64

    puts "\nraster"

    Benchmark.ips(1.second, 200.milliseconds, false) do |job|
      job.report("Raster.to_png 64x64") { sink += raster.to_png.size }
      job.report("Raster.png decode 64x64") { sink += Asekii::Raster.png(png).try(&.width) || 0 }
      job.report("Raster.scale 64->32") { sink += raster.scale(32, 32).width }
      job.report("Raster.to_sixel 64x64") { sink += raster.to_sixel.size }
      job.report("Raster.rgba wrap") { sink += Asekii::Raster.rgba(raster.data, 64, 64).try(&.data.size) || 0 }
    end

    sink
  end
end

puts "sink #{Bench::Raster.run}"
