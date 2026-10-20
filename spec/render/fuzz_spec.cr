# spec/render/fuzz_spec.cr
require "./support"

class Glass
  CONT = "\u0000"

  getter cells : Array(String)

  def initialize(@cols : Int32, @rows : Int32)
    @cells = Array.new(@cols * @rows, " ")
    @col = 0
    @row = 0
    @top = 0
    @bottom = @rows
  end

  def feed(wire : String) : Nil
    chars = wire.chars
    index = 0
    while index < chars.size
      char = chars[index]
      index += 1
      unless char == '\e'
        write(char.to_s)
        next
      end
      if chars[index] == ']'
        until chars[index] == '\\'
          index += 1
        end
        index += 1
        next
      end
      raise "unexpected escape" unless chars[index] == '['
      index += 1
      start = index
      until chars[index].ascii_letter?
        index += 1
      end
      control(chars[start...index].join, chars[index])
      index += 1
    end
  end

  private def control(params : String, final : Char) : Nil
    case final
    when 'H'
      row, col = params.split(';').map(&.to_i)
      @row = row - 1
      @col = col - 1
    when 'C'
      @col += params.to_i
    when 'K'
      (@col...@cols).each { |col| put(col, " ") }
    when 'r'
      @top, @bottom = params.empty? ? {0, @rows} : {params.split(';')[0].to_i - 1, params.split(';')[1].to_i}
      @col = 0
      @row = 0
    when 'S'
      roll(params.to_i)
    when 'T'
      roll(-params.to_i)
    end
  end

  private def roll(lines : Int32) : Nil
    rows = (@top...@bottom).map { |row| @cells[row * @cols, @cols] }
    lines.abs.times do
      if lines > 0
        rows.shift
        rows.push(Array.new(@cols, " "))
      else
        rows.pop
        rows.unshift(Array.new(@cols, " "))
      end
    end
    rows.each_with_index do |cells, offset|
      cells.each_with_index { |cell, col| @cells[(@top + offset) * @cols + col] = cell }
    end
  end

  private def write(text : String) : Nil
    wide = Asekii::Render::Graphemes.segmenter.measure(text) == 2
    put(@col, text)
    put(@col + 1, CONT) if wide
    @col += wide ? 2 : 1
  end

  private def put(col : Int32, text : String) : Nil
    index = @row * @cols + col
    if @cells[index] == CONT && text != CONT
      @cells[index - 1] = " "
    elsif col + 1 < @cols && @cells[index + 1] == CONT
      @cells[index + 1] = " " unless text == CONT
    end
    @cells[index] = text
  end
end

private def expected(stage : Engine, cols : Int32, rows : Int32) : Array(String)
  Array.new(cols * rows) do |index|
    tile = stage.at(index % cols, index // cols)
    if tile.covered?
      Glass::CONT
    elsif tile.broken? || tile.glyph == 0_u32
      " "
    else
      tile.text
    end
  end
end

describe Asekii::Render::Compositor do
  it "leaves the terminal matching the composed frame after random updates" do
    cols = 24
    rows = 8
    random = Random.new(20261003)
    words = ["ab", "日本", "x", "hello", "wide字", "  ", "Zz"]
    stage = Engine.new(cols, rows)
    screen = Glass.new(cols, rows)
    log = stage.plane(cols, 6, 0, 1)
    6.times { |row| log.put(0, row, "log line #{row}") }
    planes = Array.new(4) do
      stage.plane(random.rand(3..14), random.rand(1..5), random.rand(-3..20), random.rand(-2..7))
    end
    links = [nil, "https://a.example", "https://b.example"]
    shifts = 0
    600.times do
      plane = planes.sample(random)
      case random.rand(12)
      when 10
        lines = random.rand(-2..2)
        log.scroll(lines)
        log.put(0, lines > 0 ? 5 : 0, "entry #{random.rand(100)}", fg: random.rand(16))
      when 11
        plane.put(random.rand(0..10), random.rand(0..4), words.sample(random), link: links.sample(random),
          attrs: Asekii::Render::Attr::CurlyUnderline, line: random.rand(16))
      when 0 then plane.move(random.rand(-4..22), random.rand(-2..7))
      when 1 then plane.visible = random.rand(4) > 0
      when 2 then plane.opacity = random.rand(3) / 2.0
      when 3 then random.next_bool ? plane.to_top : plane.to_bottom
      when 4 then plane.fill(bg: {random.rand(16), random.rand(1..2) / 2.0})
      when 5 then plane.erase
      when 6 then plane.resize(random.rand(2..14), random.rand(1..5))
      when 7 then plane.base(random.next_bool ? '.' : nil, bg: random.rand(8))
      else
        plane.put(random.rand(-2..12), random.rand(0..4), words.sample(random),
          fg: random.rand(16), bg: random.next_bool ? random.rand(16) : nil)
      end
      wire = stage.frame
      shifts += 1 if wire.includes?("r\e[")
      screen.feed(wire)
      screen.cells.should eq(expected(stage, cols, rows))
    end
    shifts.should be > 0
    stage.compositor.invalidate
    again = Glass.new(cols, rows)
    again.feed(stage.frame)
    again.cells.should eq(screen.cells)
  end
end
