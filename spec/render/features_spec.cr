# spec/render/features_spec.cr
require "./support"

private def local(stage : Engine) : Nil
  stage.themes.define(:dark, base16: DARK16, fg: 0xcdd6f4, bg: 0x1e1e2e)
  stage.themes.use(:dark)
end

describe "SGR output" do
  it "writes every attribute a modern terminal understands" do
    stage = Engine.new(12, 1)
    plane = stage.plane(12, 1)
    plane.put(0, 0, "a", attrs: Asekii::Render::Attr::Bold | Asekii::Render::Attr::Italic | Asekii::Render::Attr::Blink)
    plane.put(1, 0, "b", attrs: Asekii::Render::Attr::Conceal | Asekii::Render::Attr::Overline)
    plane.put(2, 0, "c", attrs: Asekii::Render::Attr::Reverse | Asekii::Render::Attr::Strike | Asekii::Render::Attr::Overline)
    plane.put(3, 0, "d", attrs: Asekii::Render::Attr::DoubleUnderline)
    plane.put(4, 0, "e", attrs: Asekii::Render::Attr::DottedUnderline)
    plane.put(5, 0, "f", attrs: Asekii::Render::Attr::DashedUnderline | Asekii::Render::Attr::Dim)
    plane.put(6, 0, "g", attrs: Asekii::Render::Attr::Underline)
    plane.put(7, 0, "h")
    stage.frame.should start_with("\e[0m\e[1;1H\e[1;3;5ma\e[22;23;25;8;53mb\e[28;7;9mc\e[27;29;55;4:2md\e[24;4:4me\e[24;2;4:5mf\e[22;24;4mg\e[24mh")
  end

  it "sets and resets the underline color" do
    stage = Engine.new(8, 1)
    plane = stage.plane(8, 1)
    plane.put(0, 0, "a", attrs: Asekii::Render::Attr::CurlyUnderline, line: "#ff0000")
    plane.put(1, 0, "b", attrs: Asekii::Render::Attr::CurlyUnderline, line: 9)
    plane.put(2, 0, "c", attrs: Asekii::Render::Attr::CurlyUnderline)
    plane.put(3, 0, "d", attrs: Asekii::Render::Attr::CurlyUnderline, line: :accent)
    stage.frame.should start_with("\e[0m\e[1;1H\e[4:3;58:2::255:0:0ma\e[58:5:9mb\e[59mc\e[58:5:4md")
    stage.at(0, 0).line_kind.should eq(Asekii::Render::Tile::Kind::RGB)
    stage.at(2, 0).line_kind.should eq(Asekii::Render::Tile::Kind::Default)
  end

  it "tints the underline color under a translucent overlay and drops it on blank cells" do
    stage = Engine.new(4, 1)
    low   = stage.plane(4, 1)
    scrim = stage.plane(1, 1)
    low.put(0, 0, "ab", attrs: Asekii::Render::Attr::Underline, line: "#ffffff", bg: "#ffffff")
    low.put(2, 0, " ", line: "#ffffff")
    scrim.fill(bg: {"#000000", 0.5})
    stage.frame
    stage.at(0, 0).line.should eq(0xbbbbbb_u32)
    stage.at(1, 0).line.should eq(0xffffff_u32)
    stage.at(2, 0).line_kind.should eq(Asekii::Render::Tile::Kind::Default)
  end

  it "snaps the underline color on terminals without truecolor" do
    stage = Engine.new(2, 1)
    stage.themes.depth = Asekii::Render::ColorDepth::Indexed256
    plane = stage.plane(2, 1)
    plane.put(0, 0, "a", attrs: Asekii::Render::Attr::Underline, line: "#ff0000")
    stage.frame.should contain("58:5:9")
  end
end

describe "hyperlinks" do
  it "opens a link once for a run of cells and closes it" do
    stage = Engine.new(12, 1)
    plane = stage.plane(12, 1)
    plane.put(0, 0, "see ")
    plane.put(4, 0, "docs", link: "https://example.org/docs")
    plane.put(8, 0, " x")
    id = Asekii::Render::Links.intern("https://example.org/docs")
    stage.frame.should start_with("\e[0m\e[1;1Hsee \e]8;id=#{id};https://example.org/docs\e\\docs\e]8;;\e\\ x")
    stage.at(4, 0).link.should eq(id)
  end

  it "switches between links and closes an open link at the end of the frame" do
    stage = Engine.new(4, 1)
    plane = stage.plane(4, 1)
    plane.put(0, 0, "ab", link: "https://a.example")
    plane.put(2, 0, "cd", link: "https://b.example")
    one = Asekii::Render::Links.intern("https://a.example")
    two = Asekii::Render::Links.intern("https://b.example")
    stage.frame.should eq("\e[0m\e[1;1H\e]8;id=#{one};https://a.example\e\\ab\e]8;id=#{two};https://b.example\e\\cd\e]8;;\e\\\e[0m")
    plane.put(0, 0, "ab")
    stage.frame.should eq("\e[0m\e[1;1Hab\e[0m")
  end

  it "links the text under a glyphless overlay, keeps linked blanks, and rejects control characters" do
    stage = Engine.new(8, 1)
    plane = stage.plane(8, 1)
    zone  = stage.plane(2, 1, 6, 0)
    plane.put(5, 0, "abc", link: "https://b.example")
    zone.fill(link: "https://a.example")
    plane.fill(0, 0, 5, 1, link: "https://a.example")
    wire = stage.frame
    wire.should_not contain("\e[K")
    stage.at(0, 0).link.should eq(Asekii::Render::Links.intern("https://a.example"))
    stage.at(5, 0).link.should eq(Asekii::Render::Links.intern("https://b.example"))
    stage.at(6, 0).link.should eq(Asekii::Render::Links.intern("https://a.example"))
    stage.at(6, 0).text.should eq("b")
    expect_raises(ArgumentError) { plane.put(0, 0, "x", link: "bad\e]8;;") }
  end
end

describe "cursor" do
  it "shows the terminal cursor at a plane position after the frame" do
    stage = Engine.new(10, 3)
    plane = stage.plane(6, 1, 2, 1)
    plane.put(0, 0, "name")
    plane.cursor(4, 0)
    stage.frame.should end_with("\e[0m\e[2;7H\e[?25h")
    stage.frame.should eq("")
    plane.cursor(2, 0)
    stage.frame.should eq("\e[2;5H")
    plane.move(3, 2)
    stage.frame.should end_with("\e[0m\e[3;6H\e[?25h")
  end

  it "hides the cursor while drawing, when covered, and when released" do
    stage = Engine.new(10, 3)
    plane = stage.plane(6, 1)
    cover = stage.plane(2, 1, 4, 0)
    plane.cursor(1, 0)
    stage.frame.should contain("\e[1;2H\e[?25h")
    plane.put(0, 0, "x")
    stage.frame.should eq("\e[?25l\e[0m\e[1;1Hx\e[0m\e[1;2H\e[?25h")
    plane.cursor(4, 0)
    stage.frame.should eq("\e[1;5H")
    cover.fill(bg: 1)
    stage.frame.should end_with("\e[?25l\e[0m\e[1;5H\e[41m  \e[0m")
    cover.visible = false
    stage.frame.should end_with("\e[1;5H\e[?25h")
    plane.cursor(9, 0)
    stage.frame.should eq("\e[?25l")
    plane.cursor(1, 0)
    stage.frame
    plane.hide_cursor
    stage.frame.should eq("\e[?25l")
    plane.cursor(1, 0)
    stage.frame
    plane.dispose
    stage.frame.should contain("\e[?25l")
  end

  it "sets the cursor shape and restores it at stop" do
    stage = Engine.new(4, 1)
    plane = stage.plane(4, 1)
    plane.cursor(0, 0)
    stage.compositor.cursor_shape = Asekii::Render::CursorShape::Bar
    stage.frame.should end_with("\e[1;1H\e[5 q\e[?25h")
    stage.compositor.cursor_blink = false
    stage.frame.should eq("\e[1;1H\e[6 q")
    stage.compositor.cursor_shape = Asekii::Render::CursorShape::Block
    stage.frame.should eq("\e[1;1H\e[2 q")
    fresh = Engine.new(4, 1)
    field = fresh.plane(4, 1)
    field.cursor(1, 0)
    fresh.compositor.cursor_shape = Asekii::Render::CursorShape::Underline
    fresh.frame.should end_with("\e[1;2H\e[3 q\e[?25h")
    buf = Bytewire.new
    fresh.compositor.enter(buf)
    fresh.compositor.leave(buf)
    String.new(buf.written).should end_with("\e[0m\e[0 q\e[?25h")
  end
end

describe "image placeholders" do
  it "encodes the placement id in the underline color" do
    stage = Engine.new(6, 2)
    plane = stage.plane(6, 2)
    plane.image(0, 0, 0x00010203_u32, 2, 1, placement: 0x0a0b0c_u32)
    plane[0, 0].line.should eq(Asekii::Render::Paint.rgb(0x0a0b0c_u32))
    stage.frame.should contain("\e[38;2;1;2;3;58:2::10:11:12m")
    stage.at(0, 0).line.should eq(0x0a0b0c_u32)
    expect_raises(ArgumentError) { plane.image(0, 0, 1_u32, 1, 1, placement: 0x1000000_u32) }
  end

  it "lets placeholders after the first of a row inherit their row and column" do
    stage = Engine.new(6, 2)
    plane = stage.plane(6, 2)
    plane.image(0, 0, 0x00010203_u32, 3, 2)
    wire = stage.frame
    wire.should contain("#{PH}#{D0}#{D0}#{PH}#{PH}")
    wire.should contain("#{PH}#{D1}#{D0}#{PH}#{PH}")
    wire.should_not contain("#{PH}#{D0}#{D1}")
  end

  it "keeps full diacritics where the cell to the left is not the previous column" do
    stage = Engine.new(6, 1)
    plane = stage.plane(6, 1)
    plane.image(0, 0, 0x00010203_u32, 1, 1)
    plane.image(1, 0, 0x00010203_u32, 1, 1)
    plane.image(2, 0, 0x00040506_u32, 2, 1)
    wire = stage.frame
    wire.should contain("#{PH}#{D0}#{D0}#{PH}#{D0}#{D0}")
    wire.should contain("#{PH}#{D0}#{D0}#{PH}\e")
  end

  it "rewrites an inheriting placeholder in full when its left neighbour changes" do
    stage = Engine.new(6, 1)
    plane = stage.plane(6, 1)
    plane.image(0, 0, 0x00010203_u32, 3, 1)
    stage.frame
    cover = stage.plane(1, 1)
    cover.put(0, 0, "x")
    wire = stage.frame
    wire.should contain("x")
    wire.should contain("#{PH}#{D0}#{D1}")
    wire.should_not contain("#{D2}")
    cover.dispose
    wire = stage.frame
    wire.should contain("#{PH}#{D0}#{D0}")
  end

  it "writes the first visible column of a clipped image in full" do
    stage = Engine.new(4, 1)
    plane = stage.plane(6, 1, -2, 0)
    plane.image(0, 0, 0x00010203_u32, 4, 1)
    wire = stage.frame
    wire.should contain("#{PH}#{D0}#{D2}#{PH}\e")
  end

  it "decodes the row, column and high byte of a placeholder glyph" do
    glyph = Asekii::Render::Plane.placeholder(2, 1, 3)
    found = Asekii::Render::Placeholder.of(glyph).not_nil!
    {found.row, found.col, found.high}.should eq({2, 1, 3})
    Asekii::Render::Placeholder.of(Asekii::Render::Graphemes.intern("é")).should be_nil
  end
end

private PH = '\u{10EEEE}'
private D0 = Asekii::UnicodePlaceholder.mark(0)
private D1 = Asekii::UnicodePlaceholder.mark(1)
private D2 = Asekii::UnicodePlaceholder.mark(2)

describe Asekii::Render::Sprite do
  it "places an image under the cells and opens the background over it" do
    stage = Engine.new(20, 6)
    local(stage)
    plane = stage.plane(10, 4, 2, 1)
    plane.put(0, 0, "under")
    image = plane.sprite(77_u32, 1, 0, 4, 2)
    wire  = stage.frame
    under = Asekii::Render::Sprite::BELOW_CELLS - 0
    wire.should contain("\e[2;4H\e_Ga=p,i=77,q=1,p=#{image.placement_id},c=4,r=2,z=#{under},C=1\e\\")
    stage.at(2, 1).text.should eq("u")
    stage.at(2, 1).bg_kind.should eq(Asekii::Render::Tile::Kind::RGB)
    stage.at(3, 1).glyph.should eq(0_u32)
    stage.at(3, 1).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
    stage.at(6, 2).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
    stage.at(7, 1).bg_kind.should eq(Asekii::Render::Tile::Kind::RGB)
    stage.frame.should eq("")
  end

  it "lets text above show over the image and a background above hide it" do
    stage = Engine.new(20, 6)
    local(stage)
    plane = stage.plane(10, 4)
    image = plane.sprite(5_u32, 0, 0, 4, 2)
    label = stage.plane(2, 1)
    cover = stage.plane(1, 2, 3, 0)
    label.put(0, 0, "ok")
    cover.fill(bg: 1)
    stage.frame
    stage.at(0, 0).text.should eq("o")
    stage.at(0, 0).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
    stage.at(3, 0).bg_kind.should eq(Asekii::Render::Tile::Kind::RGB)
    stage.at(2, 1).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
    image.disposed?.should be_false
  end

  it "moves, crops at the edges, and removes its placement" do
    stage = Engine.new(10, 4)
    plane = stage.plane(10, 4)
    image = plane.sprite(9_u32, 0, 0, 4, 2, width: 40, height: 20)
    stage.frame
    image.move(8, 3)
    wire = stage.frame
    wire.should contain("\e[4;9H\e_Ga=p,i=9,q=1,p=#{image.placement_id},w=20,h=10,c=2,r=1,z=#{Asekii::Render::Sprite::BELOW_CELLS},C=1\e\\")
    image.move(-2, 0)
    stage.frame.should contain("x=20,w=20,h=20,c=2,r=2,z=#{Asekii::Render::Sprite::BELOW_CELLS},C=1")
    plane.visible = false
    stage.frame.should contain("\e_Ga=d,d=i,i=9,p=#{image.placement_id}\e\\")
    plane.visible = true
    stage.frame.should contain("\e_Ga=p,i=9,q=1,p=#{image.placement_id}")
    image.dispose
    stage.frame.should contain("\e_Ga=d,d=i,i=9,p=#{image.placement_id}\e\\")
    stage.compositor.pile.sprites.should be_empty
    stage.at(0, 0).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
  end

  it "hides a clipped image whose pixel size is unknown and orders stacked images" do
    stage = Engine.new(10, 4)
    low   = stage.plane(10, 4)
    high  = stage.plane(10, 4)
    one   = low.sprite(1_u32, 0, 0, 2, 2)
    two   = high.sprite(2_u32, 1, 0, 2, 2)
    wire  = stage.frame
    wire.should contain("i=2,q=1,p=#{two.placement_id},c=2,r=2,z=#{Asekii::Render::Sprite::BELOW_CELLS},C=1")
    wire.should contain("i=1,q=1,p=#{one.placement_id},c=2,r=2,z=#{Asekii::Render::Sprite::BELOW_CELLS - 1},C=1")
    two.move(9, 0)
    stage.frame.should contain("\e_Ga=d,d=i,i=2,p=#{two.placement_id}\e\\")
    two.live.should be_nil
  end

  it "re-places images after an invalidate and deletes them when it leaves" do
    stage = Engine.new(10, 4)
    plane = stage.plane(10, 4)
    image = plane.sprite(3_u32, 0, 0, 2, 2)
    stage.frame.should contain("\e_Ga=p,i=3,q=1,p=#{image.placement_id},c=2,r=2")
    stage.compositor.invalidate
    stage.frame.should contain("\e_Ga=p,i=3,q=1,p=#{image.placement_id},c=2,r=2")
    buf = Bytewire.new
    stage.compositor.leave(buf)
    String.new(buf.written).should contain("\e_Ga=d,d=i,i=3,p=#{image.placement_id}\e\\")
    image.placed.should be_nil
  end
end

describe "scrolling" do
  it "shifts plane contents and clears what scrolls in" do
    stage = Engine.new(6, 4)
    plane = stage.plane(6, 4)
    4.times { |row| plane.put(0, row, "row#{row}") }
    plane.scroll(1)
    plane[3, 0].text.should eq("1")
    plane[3, 2].text.should eq("3")
    plane[0, 3].inked?.should be_false
    plane.scroll(-2)
    plane[3, 2].text.should eq("1")
    plane[0, 0].inked?.should be_false
    plane.scroll(9)
    plane[3, 2].inked?.should be_false
  end

  it "scrolls the terminal region and paints only the new line" do
    stage = Engine.new(8, 6)
    title = stage.plane(8, 1)
    log   = stage.plane(8, 4, 0, 1)
    title.put(0, 0, "title")
    4.times { |row| log.put(0, row, "line #{row}") }
    stage.frame
    log.scroll(1)
    log.put(0, 3, "line 4")
    stage.frame.should eq("\e[0m\e[2;5r\e[1S\e[r\e[5;1Hline 4\e[0m")
    stage.at(0, 1).text.should eq("l")
    stage.at(5, 1).text.should eq("1")
    log.scroll(-1)
    stage.frame.should eq("\e[0m\e[2;5r\e[1T\e[r\e[0m")
    stage.at(5, 2).text.should eq("1")
  end

  it "repaints instead when the plane is narrower than the screen or mostly different" do
    stage = Engine.new(8, 5)
    side  = stage.plane(4, 5)
    5.times { |row| side.put(0, row, "r#{row}") }
    stage.frame
    side.scroll(1)
    stage.frame.should_not contain("S\e[r")
    full = stage.plane(8, 5)
    5.times { |row| full.put(0, row, "same") }
    stage.frame
    full.scroll(1)
    5.times { |row| full.put(0, row, "new#{row * 7}") }
    stage.frame.should_not contain("S\e[r")
  end
end
