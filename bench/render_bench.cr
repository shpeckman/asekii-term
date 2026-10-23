# bench/render_bench.cr
require "benchmark"
require "../src/asekii-term/render"

module Bench::Render
  extend self

  TEXT = "The quick brown fox jumps over the lazy dog — 日本語テスト"

  def run : Nil
    compositor = Asekii::Render::Compositor.new
    plane = compositor.plane(120, 40)
    buffer = Bytewire.new(64 * 1024)
    plane.fill(bg: :surface)
    plane.put(1, 1, "hello, world", fg: :text)
    compositor.render(buffer)

    puts "\nrender"

    Benchmark.ips(1.second, 200.milliseconds, false) do |job|
      job.report("TextLayout.wrap 80") { Asekii::Render::TextLayout.wrap(TEXT, 80) }
      job.report("TextLayout.width") { Asekii::Render::TextLayout.width(TEXT) }
      job.report("Plane.put 60 cols") { plane.put(0, 0, TEXT, fg: :text) }
      job.report("Plane.fill 120x40") { plane.fill(bg: :surface_raised) }
      job.report("Compositor.render dirty") do
        plane.put(1, 1, "hello", fg: :accent)
        buffer.reset
        compositor.render(buffer)
      end
      job.report("Compositor.render clean") do
        buffer.reset
        compositor.render(buffer)
      end
      job.report("ColorSpace.oklab") { Asekii::Render::ColorSpace.oklab(0x4a90d9_u32) }
      job.report("ColorSpace.from_oklab") do
        Asekii::Render::ColorSpace.from_oklab({0.6_f32, 0.1_f32, 0.2_f32})
      end
      job.report("ColorSpace.mix oklab") do
        Asekii::Render::ColorSpace.mix(0x112233_u32, 0xddccbb_u32, 0.5_f32, Asekii::Render::BlendSpace::Oklab)
      end
      palette = Asekii::Render::Palette.stock
      job.report("Palette.nearest") { palette.nearest(0x4a90d9_u32) }
      job.report("Palette.generate") do
        Asekii::Render::Palette.generate(palette.colors[0, 16], palette.fg, palette.bg)
      end
      stroke = Asekii::Render::Stroke.new(Asekii::Render::Stroke::Piece::TopLeft, round: true, width: 2)
      job.report("Stroke.mask 12x24") { stroke.mask(12, 24) }
    end
  end
end

Bench::Render.run
