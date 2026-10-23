# spec/render/stroke_spec.cr
require "./support"
require "compress/zlib"
require "base64"

private alias Stroke = Asekii::Render::Stroke
private alias Space = Asekii::Render::ColorSpace

private def payloads(wire : String) : Hash(UInt32, Bytes)
  images = {} of UInt32 => Bytes
  id = 0_u32
  data = IO::Memory.new
  wire.scan(/\e_G([^;\e]*);([^\e]*)\e\\/) do |match|
    keys = match[1].split(',').to_h { |pair| {pair[0, 1], pair[2..]} }
    if keys["a"]? == "T"
      id = keys["i"].to_u32
      data = IO::Memory.new
    end
    data.write(Base64.decode(match[2]))
    if keys["m"]?.nil? || keys["m"] == "0"
      packed = IO::Memory.new(data.to_slice)
      images[id] = Compress::Zlib::Reader.open(packed, &.getb_to_end)
    end
  end
  images
end

private def pixel(data : Bytes, width : Int32, x : Int32, y : Int32) : UInt32
  index = (y * width + x) * 3
  Space.pack(data[index], data[index + 1], data[index + 2])
end

private def rgba(data : Bytes, width : Int32, x : Int32, y : Int32) : UInt32
  index = (y * width + x) * 4
  (data[index].to_u32 << 24) | (data[index + 1].to_u32 << 16) | (data[index + 2].to_u32 << 8) | data[index + 3].to_u32
end

private def linear(rgb : UInt32) : Space::Triple
  Space.coords(rgb, Asekii::Render::BlendSpace::Linear)
end

private def shown(value : Space::Triple) : UInt32
  Space.rgb(value, Asekii::Render::BlendSpace::Linear)
end

private def coverage(mask : Bytes, width : Int32, x : Int32, y : Int32) : Tuple(UInt8, UInt8)
  index = (y * width + x) * 2
  {mask[index], mask[index + 1]}
end

describe Asekii::Render::Stroke do
  it "centres a horizontal line and fills the inside below it" do
    mask = Stroke.new(Stroke::Piece::Top, width: 2, fill: Stroke::Fill::Inside).mask(8, 16)
    coverage(mask, 8, 3, 6).should eq({0_u8, 0_u8})
    coverage(mask, 8, 3, 7).should eq({255_u8, 0_u8})
    coverage(mask, 8, 3, 8).should eq({255_u8, 255_u8})
    coverage(mask, 8, 3, 15).should eq({0_u8, 255_u8})
  end

  it "mirrors the inside for the bottom edge" do
    mask = Stroke.new(Stroke::Piece::Bottom, width: 2, fill: Stroke::Fill::Inside).mask(8, 16)
    coverage(mask, 8, 0, 0).should eq({0_u8, 255_u8})
    coverage(mask, 8, 0, 8).should eq({255_u8, 0_u8})
    coverage(mask, 8, 0, 15).should eq({0_u8, 0_u8})
  end

  it "moves the line to the outer edge at position zero and the inner edge at one" do
    outer = Stroke.new(Stroke::Piece::Left, width: 2, position: 0.0).mask(8, 16)
    coverage(outer, 8, 0, 5)[0].should eq(255_u8)
    coverage(outer, 8, 1, 5)[0].should eq(255_u8)
    coverage(outer, 8, 2, 5)[0].should eq(0_u8)
    inner = Stroke.new(Stroke::Piece::Left, width: 2, position: 1.0).mask(8, 16)
    coverage(inner, 8, 7, 5)[0].should eq(255_u8)
    coverage(inner, 8, 5, 5)[0].should eq(0_u8)
  end

  it "fills the outside and nothing as asked" do
    outside = Stroke.new(Stroke::Piece::Top, width: 2, fill: Stroke::Fill::Outside).mask(8, 16)
    coverage(outside, 8, 0, 0)[1].should eq(255_u8)
    coverage(outside, 8, 0, 12)[1].should eq(0_u8)
    none = Stroke.new(Stroke::Piece::Top, width: 2, fill: Stroke::Fill::None).mask(8, 16)
    coverage(none, 8, 0, 0)[1].should eq(0_u8)
    whole = Stroke.new(Stroke::Piece::Top, width: 2).mask(8, 16)
    coverage(whole, 8, 0, 0)[1].should eq(255_u8)
  end

  it "joins a sharp corner with square ends and keeps the outer quadrant empty" do
    mask = Stroke.new(Stroke::Piece::TopLeft, width: 2, fill: Stroke::Fill::Inside).mask(8, 16)
    coverage(mask, 8, 0, 0).should eq({0_u8, 0_u8})
    coverage(mask, 8, 3, 7)[0].should eq(255_u8)
    coverage(mask, 8, 7, 7)[0].should eq(255_u8)
    coverage(mask, 8, 3, 15)[0].should eq(255_u8)
    coverage(mask, 8, 6, 12).should eq({0_u8, 255_u8})
  end

  it "rounds a corner with the largest radius the cell allows" do
    sharp = Stroke.new(Stroke::Piece::TopLeft, width: 2, fill: Stroke::Fill::Inside).mask(8, 16)
    round = Stroke.new(Stroke::Piece::TopLeft, round: true, width: 2, fill: Stroke::Fill::Inside).mask(8, 16)
    coverage(sharp, 8, 3, 7)[0].should eq(255_u8)
    coverage(round, 8, 3, 7)[0].should eq(0_u8)
    coverage(round, 8, 7, 7)[0].should eq(255_u8)
    coverage(round, 8, 3, 11)[0].should eq(255_u8)
    coverage(round, 8, 4, 8)[1].should eq(0_u8)
    coverage(round, 8, 7, 15)[1].should eq(255_u8)
  end

  it "mirrors corners and keeps the stroke continuous with the edges" do
    edge = Stroke.new(Stroke::Piece::Top, width: 3).mask(9, 18)
    side = Stroke.new(Stroke::Piece::Left, width: 3).mask(9, 18)
    sharp = Stroke.new(Stroke::Piece::TopRight, width: 3).mask(9, 18)
    left = Stroke.new(Stroke::Piece::TopLeft, round: true, width: 3).mask(9, 18)
    right = Stroke.new(Stroke::Piece::TopRight, round: true, width: 3).mask(9, 18)
    18.times do |y|
      coverage(sharp, 9, 0, y)[0].should eq(coverage(edge, 9, 0, y)[0])
      (coverage(left, 9, 8, y)[0].to_i - coverage(edge, 9, 8, y)[0].to_i).abs.should be <= 32
      (coverage(right, 9, 0, y)[0].to_i - coverage(edge, 9, 0, y)[0].to_i).abs.should be <= 32
    end
    9.times do |x|
      (coverage(left, 9, x, 17)[0].to_i - coverage(side, 9, x, 17)[0].to_i).abs.should be <= 32
    end
  end

  it "interns equal strokes to one id and knows its fallback glyph" do
    a = Asekii::Render::Strokes.intern(Stroke.new(Stroke::Piece::BottomRight, round: true))
    b = Asekii::Render::Strokes.intern(Stroke.new(Stroke::Piece::BottomRight, round: true))
    a.should eq(b)
    Asekii::Render::Strokes[a].glyph.should eq('╯')
    Stroke.new(Stroke::Piece::BottomRight).glyph.should eq('┘')
  end

  it "builds a distinct shape for every codepoint of the branch range and nothing outside it" do
    shapes = (0xF5D0..0xF60D).map { |code| Stroke.branch(code.chr).not_nil! }
    shapes.size.should eq(62)
    shapes.uniq.size.should eq(62)
    Stroke.branch('\u{F5CF}').should be_nil
    Stroke.branch('\u{F60E}').should be_nil
    Stroke.branch('─').should be_nil
    Stroke.branch('\u{F5EE}', width: 3).not_nil!.width.should eq(3_u8)
  end

  it "letters branch shapes with their nearest box-drawing glyph" do
    Stroke.branch('\u{F5D0}').not_nil!.glyph.should eq('─')
    Stroke.branch('\u{F5D2}').not_nil!.glyph.should eq('─')
    Stroke.branch('\u{F5D6}').not_nil!.glyph.should eq('╭')
    Stroke.branch('\u{F5D9}').not_nil!.glyph.should eq('╯')
    Stroke.branch('\u{F5DA}').not_nil!.glyph.should eq('├')
    Stroke.branch('\u{F5E2}').not_nil!.glyph.should eq('┬')
    Stroke.branch('\u{F5EE}').not_nil!.glyph.should eq('●')
    Stroke.branch('\u{F5FD}').not_nil!.glyph.should eq('○')
    Stroke.new(arms: Stroke::Arm::East).glyph.should eq('╶')
    Stroke.new(arms: Stroke::Arm::All).glyph.should eq('┼')
  end

  it "joins straight arms at the junction for tees and crosses" do
    tee = Stroke.new(arms: Stroke::VERTICAL | Stroke::Arm::East, width: 2).mask(8, 16)
    coverage(tee, 8, 3, 0)[0].should eq(255_u8)
    coverage(tee, 8, 4, 15)[0].should eq(255_u8)
    coverage(tee, 8, 7, 7)[0].should eq(255_u8)
    coverage(tee, 8, 0, 7)[0].should eq(0_u8)
    coverage(tee, 8, 7, 0)[0].should eq(0_u8)
    cross = Stroke.new(arms: Stroke::Arm::All, width: 2).mask(8, 16)
    coverage(cross, 8, 0, 8)[0].should eq(255_u8)
    coverage(cross, 8, 4, 15)[0].should eq(255_u8)
    coverage(cross, 8, 0, 0)[0].should eq(0_u8)
  end

  it "draws a filled node as a disc and a hollow node as a ring the arms stop at" do
    filled = Stroke.new(node: Stroke::Node::Filled, width: 2).mask(8, 16)
    coverage(filled, 8, 4, 8)[0].should eq(255_u8)
    coverage(filled, 8, 1, 8)[0].should eq(255_u8)
    coverage(filled, 8, 4, 1)[0].should eq(0_u8)
    hollow = Stroke.new(arms: Stroke::VERTICAL, node: Stroke::Node::Hollow, width: 2).mask(8, 16)
    coverage(hollow, 8, 4, 8)[0].should eq(0_u8)
    coverage(hollow, 8, 1, 8)[0].should eq(255_u8)
    coverage(hollow, 8, 3, 0)[0].should eq(255_u8)
  end

  it "fades a line out across the whole cell toward its fade side" do
    mask = Stroke.branch('\u{F5D2}', width: 2).not_nil!.mask(8, 16)
    coverage(mask, 8, 0, 7)[0].should be > 200_u8
    coverage(mask, 8, 7, 7)[0].should be < 40_u8
    coverage(mask, 8, 7, 7)[0].should be > 0_u8
    coverage(mask, 8, 0, 0)[0].should eq(0_u8)
    rising = Stroke.branch('\u{F5D5}', width: 2).not_nil!.mask(8, 16)
    coverage(rising, 8, 3, 15)[0].should be > coverage(rising, 8, 3, 0)[0]
  end

  it "curves two arcs out of one edge as mirror images" do
    mask = Stroke.branch('\u{F5E2}', width: 2).not_nil!.mask(8, 16)
    coverage(mask, 8, 4, 0)[0].should eq(0_u8)
    coverage(mask, 8, 3, 15)[0].should eq(255_u8)
    coverage(mask, 8, 0, 8)[0].should be > 0_u8
    coverage(mask, 8, 7, 8)[0].should be > 0_u8
    16.times do |y|
      8.times do |x|
        (coverage(mask, 8, x, y)[0].to_i - coverage(mask, 8, 7 - x, y)[0].to_i).abs.should be <= 32
      end
    end
  end

  it "mirrors arms and corners and drops positions a shape does not use" do
    Stroke.turn(Stroke::Arm::North | Stroke::Arm::East, true, false).should eq(Stroke::Arm::North | Stroke::Arm::West)
    Stroke.turn(Stroke::Arm::North | Stroke::Arm::East, false, true).should eq(Stroke::Arm::South | Stroke::Arm::East)
    Stroke.turn(Stroke::Corner::SouthEast, true, true).should eq(Stroke::Corner::NorthWest)
    Stroke.turn(Stroke::Corner::NorthWest | Stroke::Corner::SouthWest, true, false)
      .should eq(Stroke::Corner::NorthEast | Stroke::Corner::SouthEast)
    Stroke.new(arms: Stroke::HORIZONTAL, x: 0.0, mirror: Stroke::Mirror::X).should eq(Stroke.new(arms: Stroke::HORIZONTAL))
    Stroke.new(arms: Stroke::Arm::East, x: 0.0).should_not eq(Stroke.new(arms: Stroke::Arm::East))
    Stroke.corner(Stroke::Arm::North | Stroke::Arm::West).should eq(Stroke::Corner::NorthWest)
    Stroke.corner(Stroke::VERTICAL).should eq(Stroke::Corner::None)
  end

  it "breaks a dashed line into marks measured from the centre" do
    mask = Stroke.new(arms: Stroke::HORIZONTAL, width: 2, line: Stroke::Line::Dashed).mask(24, 16)
    solid = Stroke.new(arms: Stroke::HORIZONTAL, width: 2).mask(24, 16)
    coverage(mask, 24, 11, 7)[0].should eq(255_u8)
    coverage(mask, 24, 6, 7)[0].should eq(255_u8)
    coverage(mask, 24, 0, 7)[0].should eq(255_u8)
    coverage(mask, 24, 23, 7)[0].should eq(255_u8)
    coverage(mask, 24, 2, 7)[0].should eq(0_u8)
    coverage(mask, 24, 5, 7)[0].should eq(0_u8)
    coverage(mask, 24, 18, 7)[0].should eq(0_u8)
    coverage(solid, 24, 2, 7)[0].should eq(255_u8)
    coverage(mask, 24, 11, 6)[0].should eq(0_u8)
  end

  it "dots a dotted line with shorter marks" do
    mask = Stroke.new(arms: Stroke::VERTICAL, width: 2, line: Stroke::Line::Dotted).mask(24, 16)
    coverage(mask, 24, 11, 8)[0].should eq(255_u8)
    coverage(mask, 24, 11, 6)[0].should eq(255_u8)
    coverage(mask, 24, 11, 1)[0].should eq(255_u8)
    coverage(mask, 24, 11, 5)[0].should eq(0_u8)
    coverage(mask, 24, 11, 3)[0].should eq(0_u8)
  end

  it "letters dashed and dotted lines with dash glyphs and junctions with light ones" do
    Stroke.new(arms: Stroke::HORIZONTAL, line: Stroke::Line::Dashed).glyph.should eq('┄')
    Stroke.new(arms: Stroke::VERTICAL, line: Stroke::Line::Dashed).glyph.should eq('┆')
    Stroke.new(arms: Stroke::HORIZONTAL, line: Stroke::Line::Dotted).glyph.should eq('┈')
    Stroke.new(arms: Stroke::VERTICAL, line: Stroke::Line::Dotted).glyph.should eq('┊')
    Stroke.new(arms: Stroke::VERTICAL | Stroke::Arm::East, line: Stroke::Line::Dashed).glyph.should eq('├')
  end

  it "draws square and diamond nodes filled or as rings" do
    square = Stroke.new(node: Stroke::Node::SquareFilled, width: 2).mask(8, 16)
    coverage(square, 8, 4, 8)[0].should eq(255_u8)
    coverage(square, 8, 0, 4)[0].should be > 0_u8
    coverage(square, 8, 0, 3)[0].should eq(0_u8)
    disc = Stroke.new(node: Stroke::Node::Filled, width: 2).mask(8, 16)
    coverage(disc, 8, 0, 4)[0].should eq(0_u8)
    hollow = Stroke.new(node: Stroke::Node::SquareHollow, width: 2).mask(8, 16)
    coverage(hollow, 8, 4, 8)[0].should eq(0_u8)
    coverage(hollow, 8, 1, 8)[0].should eq(255_u8)
    diamond = Stroke.new(node: Stroke::Node::DiamondFilled, width: 2).mask(8, 16)
    coverage(diamond, 8, 4, 8)[0].should eq(255_u8)
    coverage(diamond, 8, 1, 8)[0].should eq(255_u8)
    coverage(diamond, 8, 0, 8)[0].should be < 255_u8
    coverage(diamond, 8, 0, 4)[0].should eq(0_u8)
    ring = Stroke.new(node: Stroke::Node::DiamondHollow, width: 2).mask(8, 16)
    coverage(ring, 8, 4, 8)[0].should eq(0_u8)
    coverage(ring, 8, 1, 8)[0].should eq(255_u8)
  end

  it "letters node shapes with their nearest glyph" do
    Stroke.new(node: Stroke::Node::SquareFilled).glyph.should eq('■')
    Stroke.new(node: Stroke::Node::SquareHollow).glyph.should eq('□')
    Stroke.new(node: Stroke::Node::DiamondFilled).glyph.should eq('◆')
    Stroke.new(node: Stroke::Node::DiamondHollow).glyph.should eq('◇')
  end

  it "rounds the end of a capped arm while a butt cap stays flush" do
    butt = Stroke.new(arms: Stroke::Arm::East, width: 2, caps: Stroke::Arm::East).mask(8, 16)
    coverage(butt, 8, 7, 7)[0].should eq(255_u8)
    round = Stroke.new(arms: Stroke::Arm::East, width: 2, caps: Stroke::Arm::East, cap: Stroke::Cap::Round).mask(8, 16)
    coverage(round, 8, 5, 7)[0].should eq(255_u8)
    coverage(round, 8, 7, 7)[0].should be > 0_u8
    coverage(round, 8, 7, 7)[0].should be < 255_u8
    coverage(round, 8, 7, 5)[0].should eq(0_u8)
  end
end

describe Asekii::Render::StrokeImages do
  it "draws the fallback glyph while the cell size is unknown" do
    stage = Engine.new(3, 1)
    plane = stage.plane(3, 1)
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::TopLeft, round: true), "#ff0000")
    wire = stage.frame
    wire.should contain("╭")
    wire.should_not contain("\e_G")
    stage.at(0, 0).text.should eq("╭")
    plane[0, 0].text.should eq("╭")
  end

  it "tiles a branch shape like any other stroke and letters it until the cell size is known" do
    stage = Engine.new(2, 1)
    plane = stage.plane(2, 1)
    node = Stroke.branch('\u{F5FC}').not_nil!
    plane.stroke(0, 0, node, "#ffffff")
    stage.frame.should contain("●")
    stage.compositor.cell_pixels(8, 16)
    plane.stroke(1, 0, node, "#ffffff")
    wire = stage.frame
    wire.should contain("\e_Ga=T,U=1,q=2,o=z,f=32,s=8,v=16,")
    stage.at(0, 0).glyph.should eq(Asekii::Render::StrokeImages::GLYPH)
    stage.at(0, 0).fg.should eq(stage.at(1, 0).fg)
  end

  it "uploads a transparent tile inline over the backdrop and writes its placeholder" do
    stage = Engine.new(3, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(3, 1)
    plane.stroke(1, 0, Stroke.new(Stroke::Piece::Top, width: 2), "#ff0000", "#0000ff")
    wire = stage.frame
    first = Asekii::Render::StrokeImages::FIRST
    wire.should contain("\e_Ga=T,U=1,q=2,o=z,f=32,s=4,v=8,i=#{first},c=1,r=1;")
    wire.should_not contain("N=1")
    tile = stage.at(1, 0)
    tile.glyph.should eq(Asekii::Render::StrokeImages::GLYPH)
    tile.fg.should eq(first)
    tile.fg_kind.should eq(Asekii::Render::Tile::Kind::RGB)
    tile.bg.should eq(0x000000_u32)
    wire.index("\e_Ga=T").not_nil!.should be < wire.index("\u{10EEEE}").not_nil!
    data = payloads(wire)[first]
    rgba(data, 4, 0, 0).should eq(0x0000ffff_u32)
    rgba(data, 4, 0, 3).should eq(0xff0000ff_u32)
    rgba(data, 4, 0, 4).should eq(0xff0000ff_u32)
    rgba(data, 4, 0, 7).should eq(0x0000ffff_u32)
  end

  it "uploads a palette-indexed tile when the terminal takes indexed pixels" do
    stage = Engine.new(3, 1)
    stage.compositor.cell_pixels(4, 8)
    stage.compositor.indexed_tiles = true
    plane = stage.plane(3, 1)
    plane.stroke(1, 0, Stroke.new(Stroke::Piece::Top, width: 2), 3, "#0000ff")
    wire = stage.frame
    first = Asekii::Render::StrokeImages::FIRST
    wire.should contain("\e_Ga=T,U=1,q=2,o=z,f=16,s=4,v=8,i=#{first},c=1,r=1;")
    tile = stage.at(1, 0)
    tile.glyph.should eq(Asekii::Render::StrokeImages::GLYPH)
    tile.bg.should eq(0x0000ff_u32)
    data = payloads(wire)[first]
    data.size.should eq(4 * 8 * 2)
    {data[0], data[1]}.should eq({3_u8, 0_u8})
    {data[3 * 4 * 2], data[3 * 4 * 2 + 1]}.should eq({3_u8, 255_u8})
  end

  it "maps the default foreground to its indexed slot and shares the tile across fills" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    stage.compositor.indexed_tiles = true
    plane = stage.plane(2, 1)
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top), :foreground, "#000000")
    plane.stroke(1, 0, Stroke.new(Stroke::Piece::Top), :foreground, "#336699")
    wire = stage.frame
    wire.scan("a=T").size.should eq(1)
    payloads(wire)[Asekii::Render::StrokeImages::FIRST][0].should eq(249_u8)
    stage.at(1, 0).bg.should eq(0x336699_u32)
  end

  it "keeps RGBA tiles for colours and fills the palette cannot express" do
    stage = Engine.new(3, 1)
    stage.compositor.cell_pixels(4, 8)
    stage.compositor.indexed_tiles = true
    plane = stage.plane(3, 1)
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top), "#ff0000")
    plane.stroke(1, 0, Stroke.new(Stroke::Piece::TopLeft, round: true, fill: Stroke::Fill::Inside), 3, "#0000ff")
    plane.stroke(2, 0, Stroke.new(Stroke::Piece::Top), 250)
    wire = stage.frame
    wire.scan("f=32").size.should eq(3)
    wire.should_not contain("f=16")
  end

  it "reuses a transparent tile over different backdrops" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    low = stage.plane(2, 1)
    low.fill(0, 0, 1, 1, bg: "#000000")
    low.fill(1, 0, 1, 1, bg: "#336699")
    high = stage.plane(2, 1)
    2.times { |col| high.stroke(col, 0, Stroke.new(Stroke::Piece::Top, fill: Stroke::Fill::None), "#ffffff") }
    wire = stage.frame
    wire.scan("a=T").size.should eq(1)
    stage.at(0, 0).fg.should eq(stage.at(1, 0).fg)
    stage.at(0, 0).bg.should eq(0x000000_u32)
    stage.at(1, 0).bg.should eq(0x336699_u32)
  end

  it "shares one tile across cell backgrounds when the stroke fills nothing" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(2, 1)
    empty = Stroke.new(arms: Stroke::VERTICAL, fill: Stroke::Corner::None)
    plane.stroke(0, 0, empty, "#ffffff", "#000000")
    plane.stroke(1, 0, empty, "#ffffff", "#336699")
    wire = stage.frame
    wire.scan("a=T").size.should eq(1)
    stage.at(0, 0).fg.should eq(stage.at(1, 0).fg)
  end

  it "marks a tile transient while its opacity is partial" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(1, 1)
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top), "#ffffff")
    plane.opacity = 0.5
    stage.frame.should contain("N=1")
  end

  it "shows the box-drawing glyph until an offloaded tile lands" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(4, 8)
    jobs = [] of {Proc(Bytes), Proc(Bytes, Nil)}
    stage.compositor.offload = ->(work : Proc(Bytes), done : Proc(Bytes, Nil)) { jobs << {work, done}; nil }
    plane = stage.plane(1, 1)
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top), "#ffffff")
    first = stage.frame
    first.should contain("─")
    first.should_not contain("a=T")
    jobs.size.should eq(1)
    work, done = jobs.first
    done.call(work.call)
    second = stage.frame
    second.should contain("a=T")
    stage.at(0, 0).glyph.should eq(Asekii::Render::StrokeImages::GLYPH)
  end

  it "reuses one image for every cell with the same look" do
    stage = Engine.new(6, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(6, 1)
    6.times { |col| plane.stroke(col, 0, Stroke.new(Stroke::Piece::Top), "#ffffff", "#000000") }
    wire = stage.frame
    wire.scan("a=T").size.should eq(1)
    stage.compositor.pile.stroke_images.size.should eq(1)
    stage.frame.should_not contain("a=T")
  end

  it "blends the fill, the stroke and the backdrop exactly under plane opacity" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    low = stage.plane(2, 1)
    low.fill(bg: "#000000")
    high = stage.plane(2, 1)
    high.stroke(0, 0, Stroke.new(Stroke::Piece::Left, width: 2, fill: Stroke::Fill::Inside), "#ff0000", "#ffffff")
    high.opacity = 0.5
    stage.compositor.exact_borders = true
    wire = stage.frame
    data = payloads(wire)[stage.at(0, 0).fg]
    level = 128 / 255.0_f32
    black = linear(0x000000_u32)
    fill = Space.lerp(black, linear(0xffffff_u32), level)
    red = linear(0xff0000_u32)
    pixel(data, 4, 0, 2).should eq(0x000000_u32)
    pixel(data, 4, 3, 2).should eq(shown(fill))
    stage.at(0, 0).bg.should eq(0x000000_u32)
    pixel(data, 4, 1, 2).should eq(shown(Space.lerp(black, red, level)))
    pixel(data, 4, 2, 2).should eq(shown(Space.lerp(fill, red, level)))
  end

  it "shows the colour a stroke was painted over on its own plane outside the fill" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(4, 8)
    stage.compositor.exact_borders = true
    low = stage.plane(1, 1)
    low.fill(bg: "#000000")
    plane = stage.plane(1, 1)
    plane.fill(bg: "#336699")
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Left, width: 2, fill: Stroke::Fill::Inside), "#ff0000", "#ffffff")
    wire = stage.frame
    data = payloads(wire)[stage.at(0, 0).fg]
    pixel(data, 4, 0, 2).should eq(0x336699_u32)
    pixel(data, 4, 3, 2).should eq(0xffffff_u32)
    stage.at(0, 0).bg.should eq(0x336699_u32)
  end

  it "keeps the painted-over colour behind a transparent tile" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(1, 1)
    plane.fill(bg: "#336699")
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::TopLeft, round: true, fill: Stroke::Fill::Inside), "#ff0000", "#ffffff")
    stage.frame
    stage.at(0, 0).bg.should eq(0x336699_u32)
  end

  it "keeps the first painted-over colour when a stroke is drawn over a stroke" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(1, 1)
    plane.fill(bg: "#336699")
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top, fill: Stroke::Fill::Inside), "#ff0000", "#ffffff")
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::TopLeft, fill: Stroke::Fill::Inside), "#00ff00")
    stage.frame
    stage.at(0, 0).bg.should eq(0x336699_u32)
  end

  it "falls back to the plane's base colour outside the fill" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(1, 1)
    plane.base(bg: "#336699")
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top, fill: Stroke::Fill::Inside), "#ff0000", "#ffffff")
    stage.frame
    stage.at(0, 0).bg.should eq(0x336699_u32)
  end

  it "tints the whole tile under a translucent plane above it" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    low = stage.plane(2, 1)
    low.fill(bg: "#000000")
    mid = stage.plane(2, 1)
    mid.stroke(0, 0, Stroke.new(Stroke::Piece::Left, width: 2, fill: Stroke::Fill::None), "#ffffff")
    scrim = stage.plane(2, 1)
    scrim.fill(bg: {"#0000ff", 0.5})
    wire = stage.frame
    data = payloads(wire)[stage.at(0, 0).fg]
    level = 128 / 255.0_f32
    blue = linear(0x0000ff_u32)
    keep = 1.0_f32 - level
    tint = ->(color : UInt32) {
      base = linear(color)
      shown({level * blue[0] + keep * base[0], level * blue[1] + keep * base[1], level * blue[2] + keep * base[2]})
    }
    pixel(data, 4, 0, 0).should eq(tint.call(0x000000_u32))
    pixel(data, 4, 1, 0).should eq(tint.call(0xffffff_u32))
    stage.at(0, 0).bg.should eq(tint.call(0x000000_u32))
  end

  it "hides the stroke under an opaque plane and shows text above it" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    low = stage.plane(2, 1)
    low.stroke(0, 0, Stroke.new(Stroke::Piece::Top), "#ffffff")
    low.stroke(1, 0, Stroke.new(Stroke::Piece::Top), "#ffffff")
    high = stage.plane(2, 1)
    high.fill(0, 0, 1, 1, bg: "#00ff00")
    high.put(1, 0, "x")
    stage.frame.should_not contain("a=T")
    stage.at(0, 0).text.should eq("")
    stage.at(1, 0).text.should eq("x")
  end

  it "drops a stale tile once nothing on screen shows it after the cell size changes" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(2, 1)
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top), "#ffffff")
    stage.frame
    old = stage.at(0, 0).fg
    stage.compositor.cell_pixels(5, 10)
    wire = stage.frame
    wire.should contain("s=5,v=10")
    wire.should contain("\e_Ga=d,d=I,q=2,i=#{old}\e\\")
    stage.at(0, 0).fg.should_not eq(old)
    stage.compositor.pile.stroke_images.size.should eq(1)
  end

  it "rebuilds the tile when the blend space changes" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(1, 1)
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top, width: 3), {"#ff0000", 0.5}, "#0000ff")
    stage.frame
    first = stage.at(0, 0).fg
    stage.compositor.blend = Asekii::Render::BlendSpace::Oklab
    stage.frame.should contain("a=T")
    stage.at(0, 0).fg.should_not eq(first)
  end

  it "keeps the cache bounded through a long animation and only frees tiles off screen" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(2, 4)
    plane = stage.plane(1, 1)
    limit = Asekii::Render::StrokeImages::LIMIT
    freed = 0
    (limit + 40).times do |step|
      plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top), Asekii::Render::Paint.rgb(step.to_u32 * 97_u32))
      wire = stage.frame
      freed += wire.scan(/a=d,d=[IR]/).size
      wire.should_not contain("i=#{stage.at(0, 0).fg}\e\\") if wire.includes?("a=d")
    end
    freed.should be > 0
    stage.compositor.pile.stroke_images.size.should be <= limit + 1
  end

  it "deletes every tile when the compositor leaves" do
    stage = Engine.new(1, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(1, 1)
    plane.stroke(0, 0, Stroke.new(Stroke::Piece::Top), "#ffffff")
    stage.frame
    id = stage.at(0, 0).fg
    wire = Bytewire.new
    stage.compositor.leave(wire)
    id.should eq(Asekii::Render::StrokeImages::FIRST)
    String.new(wire.written).should contain("\e_Ga=d,d=R,q=2,x=#{Asekii::Render::StrokeImages::FIRST},y=#{Asekii::Render::StrokeImages::LAST}\e\\")
    stage.compositor.pile.stroke_images.size.should eq(0)
  end
end
describe "Asekii::Render::Stroke tones" do
  it "strips its tones to the shape it shares a mask with" do
    tones = Stroke::Tones.sides(Asekii::Render::Paint.rgb(0xff0000_u32), Asekii::Render::Paint.rgb(0x0000ff_u32))
    plain = Stroke.new(arms: Stroke::VERTICAL)
    tinted = Stroke.new(arms: Stroke::VERTICAL, tones: tones)
    plain.tinted?.should be_false
    tinted.tinted?.should be_true
    tinted.shape.should eq(plain)
    Asekii::Render::Strokes.intern(tinted).should_not eq(Asekii::Render::Strokes.intern(plain))
    tinted.mask(4, 8).should eq(plain.mask(4, 8))
  end

  it "reports how much of each pixel falls in each filled quarter" do
    tones = Stroke::Tones.new(Asekii::Render::Paint.rgb(1_u32), Asekii::Render::Paint.rgb(2_u32),
      Asekii::Render::Paint.rgb(3_u32), Asekii::Render::Paint.rgb(4_u32))
    stroke = Stroke.new(arms: Stroke::HORIZONTAL, width: 2, fill: Stroke::Corner::SouthWest | Stroke::Corner::SouthEast, tones: tones)
    cover = stroke.quarters(4, 8)
    mask = stroke.mask(4, 8)
    top = 0
    bottom = (7 * 4 + 0) * 5
    cover[top + 1, 4].to_a.should eq([0_u8, 0_u8, 0_u8, 0_u8])
    cover[bottom + 1, 4].to_a.should eq([0_u8, 0_u8, 255_u8, 0_u8])
    cover[(7 * 4 + 3) * 5 + 4].should eq(255_u8)
    32.times do |pixel|
      cover[pixel * 5].should eq(mask[pixel * 2])
      (cover[pixel * 5 + 1].to_i + cover[pixel * 5 + 2] + cover[pixel * 5 + 3] + cover[pixel * 5 + 4]).should be_close(mask[pixel * 2 + 1].to_i, 2)
    end
  end

  it "fills each side of a divider with its own colour over the backdrop" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(2, 1)
    tones = Stroke::Tones.sides(Asekii::Render::Paint.rgb(0xff0000_u32), Asekii::Render::Paint.rgb(0x0000ff_u32))
    plane.stroke(0, 0, Stroke.new(arms: Stroke::VERTICAL, width: 2, tones: tones), "#ffffff", "#00ff00")
    wire = stage.frame
    wire.should contain("f=32,s=4,v=8,")
    tile = stage.at(0, 0)
    tile.glyph.should eq(Asekii::Render::StrokeImages::GLYPH)
    tile.bg.should eq(0x000000_u32)
    data = payloads(wire)[tile.fg]
    rgba(data, 4, 0, 4).should eq(0xff0000ff_u32)
    rgba(data, 4, 1, 4).should eq(0xffffffff_u32)
    rgba(data, 4, 2, 4).should eq(0xffffffff_u32)
    rgba(data, 4, 3, 4).should eq(0x0000ffff_u32)
  end

  it "fills a quarter without a tone with the cell background" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(2, 1)
    tones = Stroke::Tones.sides(Asekii::Render::Paint.rgb(0xff0000_u32), Asekii::Render::Paint::NONE)
    plane.stroke(0, 0, Stroke.new(arms: Stroke::VERTICAL, width: 2, tones: tones), "#ffffff", "#00ff00")
    data = payloads(stage.frame)[stage.at(0, 0).fg]
    rgba(data, 4, 0, 0).should eq(0xff0000ff_u32)
    rgba(data, 4, 3, 0).should eq(0x00ff00ff_u32)
  end

  it "shares one tile between cells with the same tones" do
    stage = Engine.new(3, 1)
    stage.compositor.cell_pixels(4, 8)
    plane = stage.plane(3, 1)
    tones = Stroke::Tones.sides(Asekii::Render::Paint.rgb(0xff0000_u32), Asekii::Render::Paint.rgb(0x0000ff_u32))
    3.times { |x| plane.stroke(x, 0, Stroke.new(arms: Stroke::VERTICAL, tones: tones), "#ffffff") }
    stage.frame.scan("a=T").size.should eq(1)
    stage.at(0, 0).fg.should eq(stage.at(2, 0).fg)
  end

  it "blends the tones exactly when borders are exact" do
    stage = Engine.new(2, 1)
    stage.compositor.cell_pixels(4, 8)
    stage.compositor.exact_borders = true
    low = stage.plane(2, 1)
    low.fill(bg: "#000000")
    high = stage.plane(2, 1)
    tones = Stroke::Tones.sides(Asekii::Render::Paint.rgb(0xff0000_u32), Asekii::Render::Paint.rgb(0x0000ff_u32))
    high.stroke(0, 0, Stroke.new(arms: Stroke::VERTICAL, width: 2, tones: tones), "#ffffff")
    high.opacity = 0.5
    wire = stage.frame
    wire.should contain("f=24,s=4,v=8,")
    data = payloads(wire)[stage.at(0, 0).fg]
    level = 128 / 255.0_f32
    black = linear(0x000000_u32)
    pixel(data, 4, 0, 4).should eq(shown(Space.lerp(black, linear(0xff0000_u32), level)))
    pixel(data, 4, 3, 4).should eq(shown(Space.lerp(black, linear(0x0000ff_u32), level)))
    red = Space.lerp(black, linear(0xff0000_u32), level)
    pixel(data, 4, 1, 4).should eq(shown(Space.lerp(red, linear(0xffffff_u32), level)))
  end

  it "draws a heavy line at twice the width and falls back to heavy box drawing" do
    heavy = Stroke.new(arms: Stroke::HORIZONTAL, line: Stroke::Line::Heavy)
    light = Stroke.new(arms: Stroke::HORIZONTAL, width: 2)
    heavy.mask(10, 20).should eq(light.mask(10, 20))
    (heavy == light).should be_false
    heavy.glyph.should eq('━')
    Stroke.new(arms: Stroke::VERTICAL | Stroke::Arm::East, line: Stroke::Line::Heavy).glyph.should eq('┣')
    Stroke.new(bends: Stroke::Corner::SouthEast, line: Stroke::Line::Heavy).glyph.should eq('┏')
  end

  it "draws a double line as two crisp rails that meet at corners and junctions" do
    corner = Stroke.new(arms: Stroke::Arm::East | Stroke::Arm::South, line: Stroke::Line::Double)
    corner.glyph.should eq('╔')
    mask = corner.mask(10, 20)
    inked = ->(x : Int32, y : Int32) { mask[(y * 10 + x) * 2] == 255_u8 }
    (0...200).all? { |index| mask[index * 2] == 0_u8 || mask[index * 2] == 255_u8 }.should be_true
    {inked.call(3, 8), inked.call(9, 8), inked.call(3, 19), inked.call(7, 12), inked.call(9, 12), inked.call(7, 19)}.all?.should be_true
    {inked.call(2, 8), inked.call(5, 10), inked.call(7, 10), inked.call(5, 5)}.any?.should be_false
    cross = Stroke.new(arms: Stroke::Arm::All, line: Stroke::Line::Double)
    cross.glyph.should eq('╬')
    cross.mask(10, 20)[(10 * 10 + 5) * 2].should eq(0_u8)
  end

  it "draws only the fill for a fill-only line and letters it as quarter blocks" do
    card = Stroke.new(bends: Stroke::Corner::SouthEast, fill: Stroke::Corner::SouthEast, line: Stroke::Line::None)
    card.blank?.should be_true
    card.glyph.should eq('▗')
    mask = card.mask(10, 20)
    (0...200).all? { |index| mask[index * 2] == 0_u8 }.should be_true
    mask[(19 * 10 + 9) * 2 + 1].should eq(255_u8)
    mask[1].should eq(0_u8)
    Stroke.new(arms: Stroke::HORIZONTAL, fill: Stroke::Corner::SouthWest | Stroke::Corner::SouthEast,
      line: Stroke::Line::None).glyph.should eq('▄')
  end
end
