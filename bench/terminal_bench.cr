# bench/terminal_bench.cr
require "benchmark"
require "../src/asekii-term/terminal"

module Bench::Terminal
  extend self

  def run : Nil
    puts "\nterminal"

    Benchmark.ips(1.second, 200.milliseconds, false) do |job|
      job.report("ColorSyntax.parse #hex") { Asekii::ColorSyntax.parse("#4a90d9") }
      job.report("ColorSyntax.parse rgb:") { Asekii::ColorSyntax.parse("rgb:12/34/56") }
      job.report("ColorSyntax.parse rgbi:") { Asekii::ColorSyntax.parse("rgbi:0.5/0.2/0.8") }
      job.report("Shortcut.parse") { Asekii::Event::Shortcut.parse("ctrl+shift+a") }
      job.report("KittyGraphics.place") do
        wire = Bytewire.new(128)
        Asekii::KittyGraphics.place(wire, id: 5_u32, x: 10, y: 20, columns: 8, rows: 4)
      end
      job.report("KittyGraphics.delete") do
        wire = Bytewire.new(128)
        Asekii::KittyGraphics.delete(wire, 'a', id: 5_u32)
      end
      job.report("Terminal.place_code") do
        Asekii::Terminal.place_code(id: 5_u32, placement: Asekii::Terminal::Placement.new(id: 1_u32, x: 10, y: 20, width: 8, height: 4))
      end
      job.report("Terminal.placeholder") { Asekii::Terminal.placeholder(5_u32, 8, 4) }
      shortcut = Asekii::Event::Shortcut.parse("ctrl+shift+a")
      key = Asekii::Event::Key.new('a'.ord, Asekii::Event::Key::Action::Press,
        Asekii::Event::Mods::Ctrl | Asekii::Event::Mods::Shift, nil, nil, "a")
      job.report("Shortcut.matches?") { shortcut.matches?(key) }
    end
  end
end

Bench::Terminal.run
