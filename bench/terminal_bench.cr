# bench/terminal_bench.cr
require "benchmark"
require "../src/asekii-term/terminal"

module Bench::Terminal
  extend self

  def run : Int64
    sink = 0_i64

    puts "\nterminal"

    Benchmark.ips(1.second, 200.milliseconds, false) do |job|
      job.report("ColorSyntax.parse #hex") do
        if parsed = Asekii::ColorSyntax.parse("#4a90d9")
          sink += parsed[0].red
        end
      end
      job.report("ColorSyntax.parse rgb:") do
        if parsed = Asekii::ColorSyntax.parse("rgb:12/34/56")
          sink += parsed[0].red
        end
      end
      job.report("ColorSyntax.parse rgbi:") do
        if parsed = Asekii::ColorSyntax.parse("rgbi:0.5/0.2/0.8")
          sink += parsed[0].red
        end
      end
      job.report("Shortcut.parse") { sink += Asekii::Event::Shortcut.parse("ctrl+shift+a").code }
      job.report("KittyGraphics.place") do
        wire = Bytewire.new(128)
        Asekii::KittyGraphics.place(wire, id: 5_u32, x: 10, y: 20, columns: 8, rows: 4)
        sink += wire.pos
      end
      job.report("KittyGraphics.delete") do
        wire = Bytewire.new(128)
        Asekii::KittyGraphics.delete(wire, 'a', id: 5_u32)
        sink += wire.pos
      end
      job.report("Terminal.place_code") do
        sink += Asekii::Terminal.place_code(id: 5_u32, placement: Asekii::Terminal::Placement.new(id: 1_u32, x: 10, y: 20, width: 8, height: 4)).size
      end
      job.report("Terminal.placeholder") { sink += Asekii::Terminal.placeholder(5_u32, 8, 4).size }
      shortcut = Asekii::Event::Shortcut.parse("ctrl+shift+a")
      key = Asekii::Event::Key.new('a'.ord, Asekii::Event::Key::Action::Press,
        Asekii::Event::Mods::Ctrl | Asekii::Event::Mods::Shift, nil, nil, "a")
      job.report("Shortcut.matches?") { sink += shortcut.matches?(key) ? 1 : 0 }
    end

    sink
  end
end

puts "sink #{Bench::Terminal.run}"
