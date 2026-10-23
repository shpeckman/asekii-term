# bench/render_bench.cr
require "benchmark"
require "../src/asekii-term/render"

module Bench::Render
  extend self

  TEXT = "The quick brown fox jumps over the lazy dog — 日本語テスト"

  def run : Int64
    compositor = Asekii::Render::Compositor.new
    plane = compositor.plane(120, 40)
    buffer = Bytewire.new(64 * 1024)
    plane.fill(bg: :surface)
    plane.put(1, 1, "hello, world", fg: :text)
    compositor.render(buffer)
    sink = 0_i64

    puts "\nrender"

    Benchmark.ips(1.second, 200.milliseconds, false) do |job|
      job.report("TextLayout.wrap 80") { sink += Asekii::Render::TextLayout.wrap(TEXT, 80).size }
      job.report("TextLayout.width") { sink += Asekii::Render::TextLayout.width(TEXT) }
      job.report("Plane.put 60 cols") { sink += plane.put(0, 0, TEXT, fg: :text) }
      job.report("Plane.fill 120x40") do
        plane.fill(bg: :surface_raised)
        sink += 1
      end
      job.report("Compositor.render dirty") do
        plane.put(1, 1, "hello", fg: :accent)
        buffer.reset
        compositor.render(buffer)
        sink += buffer.pos
      end
      job.report("Compositor.render clean") do
        buffer.reset
        compositor.render(buffer)
        sink += buffer.pos
      end
      job.report("ColorSpace.oklab") do
        oklab = Asekii::Render::ColorSpace.oklab(0x4a90d9_u32)
        sink += oklab[0].to_i64 + oklab[1].to_i64 + oklab[2].to_i64
      end
      job.report("ColorSpace.from_oklab") do
        sink += Asekii::Render::ColorSpace.from_oklab({0.6_f32, 0.1_f32, 0.2_f32})
      end
      job.report("ColorSpace.mix oklab") do
        sink += Asekii::Render::ColorSpace.mix(0x112233_u32, 0xddccbb_u32, 0.5_f32, Asekii::Render::BlendSpace::Oklab)
      end
      palette = Asekii::Render::Palette.stock
      job.report("Palette.nearest") { sink += palette.nearest(0x4a90d9_u32) }
      job.report("Palette.generate") do
        sink += Asekii::Render::Palette.generate(palette.colors[0, 16], palette.fg, palette.bg).colors[0]
      end
      stroke = Asekii::Render::Stroke.new(Asekii::Render::Stroke::Piece::TopLeft, round: true, width: 2)
      job.report("Stroke.mask 12x24") { sink += stroke.mask(12, 24).size }
    end

    sink
  end
end

puts "sink #{Bench::Render.run}"
