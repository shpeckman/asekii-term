# spec/render/compositor_spec.cr
require "./support"

private def rgb(tile : Asekii::Render::Tile, ink : Bool) : UInt32
  kind = ink ? tile.fg_kind : tile.bg_kind
  kind.should eq(Asekii::Render::Tile::Kind::RGB)
  ink ? tile.fg : tile.bg
end

describe Asekii::Render::Pile do
  it "takes the glyph from the topmost plane that has one" do
    stage = Engine.new
    low = stage.plane(10, 1)
    high = stage.plane(10, 1)
    low.put(0, 0, "lower")
    high.put(1, 0, "UP")
    stage.frame
    (0...5).map { |x| stage.at(x, 0).text }.join.should eq("lUPer")
  end

  it "clips a plane to its bounds and to the bounds of the plane above it" do
    stage = Engine.new
    low = stage.plane(10, 1)
    high = stage.plane(6, 1, 2, 0)
    inner = high.plane(6, 1)
    low.put(0, 0, "abcdefghij")
    high.put(0, 0, "UPPER!")
    stage.frame
    (0...10).map { |x| stage.at(x, 0).text }.join.should eq("abUPPER!ij")
    high.bounds = {3, 0, 6, 1}
    stage.frame
    (0...10).map { |x| stage.at(x, 0).text }.join.should eq("abcPPEghij")
    inner.put(0, 0, "xxxxxx")
    high.clip = true
    stage.frame
    (0...10).map { |x| stage.at(x, 0).text }.join.should eq("abcxxxghij")
    high.bounds = nil
    stage.frame
    (0...10).map { |x| stage.at(x, 0).text }.join.should eq("abxxxxxxij")
  end

  it "keeps defaults and palette indices when nothing is blended" do
    stage = Engine.new
    plane = stage.plane(10, 1)
    plane.put(0, 0, "a", fg: 5, bg: 2)
    plane.put(1, 0, "b")
    stage.frame
    stage.at(0, 0).fg_kind.should eq(Asekii::Render::Tile::Kind::Index)
    stage.at(0, 0).fg.should eq(5_u32)
    stage.at(0, 0).bg.should eq(2_u32)
    stage.at(1, 0).fg_kind.should eq(Asekii::Render::Tile::Kind::Default)
    stage.at(1, 0).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
    stage.at(5, 0).glyph.should eq(0_u32)
  end

  it "shows the base cell wherever a cell is empty" do
    stage = Engine.new
    plane = stage.plane(4, 1)
    plane.base('.', fg: 3, bg: 4)
    plane.put(1, 0, "x")
    stage.frame
    stage.at(0, 0).text.should eq(".")
    stage.at(0, 0).fg.should eq(3_u32)
    stage.at(1, 0).text.should eq("x")
    stage.at(1, 0).bg.should eq(4_u32)
  end

  it "hides glyphs under an opaque background" do
    stage = Engine.new
    low = stage.plane(4, 1)
    high = stage.plane(2, 1)
    low.put(0, 0, "abcd")
    high.fill(bg: 1)
    stage.frame
    stage.at(0, 0).glyph.should eq(0_u32)
    stage.at(0, 0).bg.should eq(1_u32)
    stage.at(2, 0).text.should eq("c")
  end

  it "tints the glyph and the background under a translucent overlay" do
    stage = Engine.new
    low = stage.plane(4, 1)
    scrim = stage.plane(2, 1)
    white = Asekii::Render::Paint.rgb(255_u8, 255_u8, 255_u8)
    low.put(0, 0, "ab", fg: white, bg: white)
    low.put(2, 0, "cd", fg: white, bg: white)
    scrim.fill(bg: Asekii::Render::Paint.rgb(0_u8, 0_u8, 0_u8, 0.5))
    stage.frame
    stage.at(0, 0).text.should eq("a")
    rgb(stage.at(0, 0), true).should eq(0xbbbbbb_u32)
    rgb(stage.at(0, 0), false).should eq(0xbbbbbb_u32)
    rgb(stage.at(2, 0), true).should eq(0xffffff_u32)
  end

  it "blends in the configured space" do
    stage = Engine.new
    stage.compositor.blend = Asekii::Render::BlendSpace::Lab
    low = stage.plane(2, 1)
    scrim = stage.plane(2, 1)
    low.fill(bg: "#ffffff")
    scrim.fill(bg: {"#000000", 0.5})
    stage.frame
    shade = rgb(stage.at(0, 0), false)
    ((shade & 0xFF).to_i - 0x77).abs.should be <= 2
  end

  it "recomposes when the blend space changes" do
    stage = Engine.new
    low = stage.plane(2, 1)
    scrim = stage.plane(2, 1)
    low.fill(bg: "#ffe000")
    scrim.fill(bg: {"#0000ff", 0.5})
    stage.frame
    linear = rgb(stage.at(0, 0), false)
    stage.compositor.blend = Asekii::Render::BlendSpace::Oklab
    stage.frame.should_not eq("")
    rgb(stage.at(0, 0), false).should_not eq(linear)
    stage.compositor.blend = Asekii::Render::BlendSpace::Oklab
    stage.frame.should eq("")
  end

  it "blends over the terminal default background" do
    stage = Engine.new
    plane = stage.plane(2, 1)
    stage.themes.palette.bg = 0xffffff_u32
    plane.fill(bg: {"#000000", 0.5})
    stage.frame
    rgb(stage.at(0, 0), false).should eq(0xbbbbbb_u32)
  end

  it "scales every channel by the plane opacity" do
    stage = Engine.new
    plane = stage.plane(2, 1)
    plane.put(0, 0, "x", fg: "#ffffff", bg: "#ffffff")
    plane.opacity = 0.5
    stage.frame
    rgb(stage.at(0, 0), false).should eq(0xbcbcbc_u32)
    plane.opacity = 0.0
    stage.frame
    stage.at(0, 0).glyph.should eq(0_u32)
    stage.at(0, 0).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
    plane.opacity = 1.0
    stage.frame
    rgb(stage.at(0, 0), false).should eq(0xffffff_u32)
  end

  it "multiplies opacity and visibility down the binding chain" do
    stage = Engine.new
    parent = stage.plane(4, 1)
    child = parent.plane(2, 1)
    child.fill(bg: "#ffffff")
    parent.opacity = 0.5
    stage.frame
    rgb(stage.at(0, 0), false).should eq(0xbcbcbc_u32)
    parent.visible = false
    stage.frame
    stage.at(0, 0).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
  end

  it "picks black or white ink for high contrast cells" do
    stage = Engine.new
    plane = stage.plane(2, 1)
    plane.put(0, 0, "a", bg: "#ffffff", attrs: Asekii::Render::Attr::HighContrast)
    plane.put(1, 0, "b", bg: "#101010", attrs: Asekii::Render::Attr::HighContrast)
    stage.frame
    rgb(stage.at(0, 0), true).should eq(0x000000_u32)
    rgb(stage.at(1, 0), true).should eq(0xffffff_u32)
    stage.at(0, 0).attrs.should eq(Asekii::Render::Attr::None)
  end

  it "resolves an adjust spec written to a plane" do
    stage = Engine.new(2, 1)
    accent = Asekii::Render::ColorSpace.oklch(stage.themes.palette[4])
    plane = stage.plane(2, 1)
    plane.fill(bg: Asekii::Render::Adjust.lighten(:accent, 0.1))
    stage.frame
    Asekii::Render::ColorSpace.oklch(rgb(stage.at(0, 0), false))[0].should be > accent[0]
  end

  it "follows the z order as planes are restacked" do
    stage = Engine.new
    one = stage.plane(1, 1)
    two = stage.plane(1, 1)
    one.put(0, 0, "1")
    two.put(0, 0, "2")
    stage.frame
    stage.at(0, 0).text.should eq("2")
    one.to_top
    stage.frame
    stage.at(0, 0).text.should eq("1")
    one.below(two)
    stage.frame
    stage.at(0, 0).text.should eq("2")
    two.to_bottom
    stage.frame
    stage.at(0, 0).text.should eq("1")
    two.above(one)
    one.lower_one
    one.raise_one
    two.z.should be > one.z
    stage.compositor.pile.top_at(0, 0).should eq(two)
  end

  it "repairs the footprint of a plane that moves, hides or goes away" do
    stage = Engine.new
    plane = stage.plane(2, 1, 1, 1)
    plane.put(0, 0, "ab")
    stage.frame
    stage.at(1, 1).text.should eq("a")
    plane.move(3, 2)
    stage.frame
    stage.at(1, 1).glyph.should eq(0_u32)
    stage.at(3, 2).text.should eq("a")
    plane.visible = false
    stage.frame
    stage.at(3, 2).glyph.should eq(0_u32)
    plane.visible = true
    stage.frame
    stage.at(3, 2).text.should eq("a")
    plane.dispose
    stage.frame
    stage.at(3, 2).glyph.should eq(0_u32)
  end

  it "clips planes that hang off the screen" do
    stage = Engine.new(4, 2)
    plane = stage.plane(4, 2, 2, 1)
    plane.put(0, 0, "abcd")
    stage.frame
    stage.at(2, 1).text.should eq("a")
    stage.at(3, 1).text.should eq("b")
    plane.move(-3, 0)
    stage.frame
    stage.at(0, 0).text.should eq("d")
  end

  it "blanks a wide glyph that another plane splits" do
    stage = Engine.new
    low = stage.plane(6, 1)
    high = stage.plane(1, 1, 1, 0)
    low.put(0, 0, "日本", bg: 4)
    stage.frame
    stage.at(0, 0).broken?.should be_false
    stage.at(1, 0).covered?.should be_true
    high.put(0, 0, "x")
    wire = stage.frame
    stage.at(0, 0).broken?.should be_true
    stage.at(1, 0).text.should eq("x")
    wire.should contain("\e[1;1H")
    high.dispose
    stage.frame
    stage.at(0, 0).broken?.should be_false
    stage.at(1, 0).covered?.should be_true
  end

  it "blanks a wide glyph cut by the screen edge" do
    stage = Engine.new(3, 1)
    plane = stage.plane(4, 1, 0, 0)
    plane.put(2, 0, "日")
    stage.frame
    stage.at(2, 0).broken?.should be_true
  end

  it "keeps the image id exact under a translucent overlay" do
    stage = Engine.new
    low = stage.plane(4, 1)
    scrim = stage.plane(4, 1)
    low.image(0, 0, 0x00a1b2c3_u32, 2, 1)
    scrim.fill(bg: {"#000000", 0.5})
    stage.frame
    rgb(stage.at(0, 0), true).should eq(0xa1b2c3_u32)
  end
end

describe Asekii::Render::Compositor do
  it "paints the whole frame once and nothing when idle" do
    stage = Engine.new(6, 2)
    plane = stage.plane(6, 2)
    plane.put(0, 0, "hello")
    first = stage.frame
    first.should start_with("\e[0m\e[1;1Hhello")
    first.should end_with("\e[0m")
    stage.frame.should eq("")
  end

  it "emits only the cells that changed" do
    stage = Engine.new(10, 3)
    plane = stage.plane(10, 3)
    plane.put(0, 0, "0123456789")
    plane.put(0, 1, "abcdefghij")
    stage.frame
    plane.put(4, 1, "X")
    stage.frame.should eq("\e[0m\e[2;5HX\e[0m")
    plane.put(4, 1, "X")
    stage.frame.should eq("")
  end

  it "bridges short gaps and skips long ones with a relative move" do
    stage = Engine.new(20, 1)
    plane = stage.plane(20, 1)
    plane.put(0, 0, "aaaaaaaaaaaaaaaaaaaa")
    stage.frame
    plane.put(1, 0, "X")
    plane.put(4, 0, "Y")
    stage.frame.should eq("\e[0m\e[1;2HXaaY\e[0m")
    plane.put(1, 0, "P")
    plane.put(12, 0, "Q")
    stage.frame.should eq("\e[0m\e[1;2HP\e[10CQ\e[0m")
  end

  it "writes colors in their shortest form" do
    stage = Engine.new(8, 1)
    plane = stage.plane(8, 1)
    plane.put(0, 0, "a", fg: 1, bg: 4)
    plane.put(1, 0, "b", fg: 9, bg: 12)
    plane.put(2, 0, "c", fg: 200, bg: 17)
    plane.put(3, 0, "d", fg: "#0a141e", bg: "#ffffff")
    plane.put(4, 0, "e")
    stage.frame.should start_with("\e[0m\e[1;1H\e[31;44ma\e[91;104mb\e[38;5;200;48;5;17mc\e[38;2;10;20;30;48;2;255;255;255md\e[39;49me")
  end

  it "switches attributes with the smallest change" do
    stage = Engine.new(8, 1)
    plane = stage.plane(8, 1)
    plane.put(0, 0, "a", attrs: Asekii::Render::Attr::Bold | Asekii::Render::Attr::Dim)
    plane.put(1, 0, "b", attrs: Asekii::Render::Attr::Dim | Asekii::Render::Attr::CurlyUnderline)
    plane.put(2, 0, "c", attrs: Asekii::Render::Attr::Italic)
    plane.put(3, 0, "d")
    stage.frame.should start_with("\e[0m\e[1;1H\e[1;2ma\e[22;2;4:3mb\e[22;24;3mc\e[23md")
  end

  it "erases a blank tail with one sequence" do
    stage = Engine.new(12, 1)
    plane = stage.plane(12, 1)
    plane.put(0, 0, "abcdefghijkl", bg: 4)
    stage.frame
    plane.fill(2, 0, 10, 1, bg: 1)
    stage.frame.should eq("\e[0m\e[1;3H\e[41m\e[K\e[0m")
    stage.frame.should eq("")
  end

  it "writes a wide glyph once and tracks the cursor past it" do
    stage = Engine.new(6, 1)
    plane = stage.plane(6, 1)
    plane.put(0, 0, "日本x")
    stage.frame.should start_with("\e[0m\e[1;1H日本x")
  end

  it "wraps the frame in synchronized output once the terminal reports it" do
    stage = Engine.new(4, 1)
    plane = stage.plane(4, 1)
    stage.compositor.sync = true
    plane.put(0, 0, "a")
    wire = stage.frame
    wire.should start_with("\e[?2026h\e[0m")
    wire.should end_with("\e[0m\e[?2026l")
  end

  it "writes transmitted graphics inside the next synchronized frame, before its cells" do
    stage = Engine.new(4, 1)
    plane = stage.plane(4, 1)
    stage.compositor.sync = true
    stage.frame
    notified = false
    stage.compositor.pile.notify = -> { notified = true; nil }
    stage.compositor.transmit("\e_Ga=f,i=9;AAAA\e\\")
    notified.should be_true
    plane.put(0, 0, "a")
    wire = stage.frame
    wire.should start_with("\e[?2026h\e[0m\e_Ga=f,i=9;AAAA\e\\")
    wire.should contain("a")
    wire.should end_with("\e[?2026l")
    stage.compositor.transmit("\e_Ga=a,i=9,c=2\e\\")
    stage.frame.should eq("\e[?2026h\e[0m\e_Ga=a,i=9,c=2\e\\\e[0m\e[?2026l")
    stage.frame.should eq("")
  end

  it "repaints everything after a resize or an invalidate" do
    stage = Engine.new(4, 1)
    plane = stage.plane(4, 1)
    plane.put(0, 0, "ab")
    stage.frame
    stage.compositor.invalidate
    stage.frame.should contain("ab")
    stage.compositor.resize(9, 3)
    stage.compositor.cols.should eq(9)
    stage.compositor.rows.should eq(3)
    stage.compositor.root.cols.should eq(9)
    stage.frame.should contain("ab")
  end

  it "runs paint callbacks before composing and drops them" do
    stage = Engine.new(4, 1)
    plane = stage.plane(4, 1)
    count = 0
    painter = ->(compositor : Asekii::Render::Compositor) do
      count += 1
      plane.put(0, 0, count.to_s)
      nil
    end
    stage.compositor.paint(painter)
    stage.frame.should contain("1")
    stage.frame.should contain("2")
    stage.compositor.drop_paint(painter)
    stage.frame.should eq("")
  end

  it "snaps blended colors to the palette on terminals without truecolor" do
    stage = Engine.new(2, 1)
    stage.themes.depth = Asekii::Render::ColorDepth::Indexed256
    plane = stage.plane(2, 1)
    plane.fill(bg: "#ff0000")
    stage.frame.should contain("\e[101m")
    stage.themes.depth = Asekii::Render::ColorDepth::Ansi16
    plane.fill(bg: 196)
    stage.frame
    stage.at(0, 0).bg.should eq(9_u32)
    stage.themes.depth = Asekii::Render::ColorDepth::TrueColor
    stage.themes.snap = true
    plane.fill(bg: "#ff0000")
    stage.frame
    stage.at(0, 0).bg_kind.should eq(Asekii::Render::Tile::Kind::Index)
  end

  it "keeps elevation roles distinct when quantized to 256 colours" do
    stage = Engine.new
    stage.themes.depth = Asekii::Render::ColorDepth::Indexed256
    hover = stage.themes.resolve(Asekii::Render::Roles::Core::Hover.value)
    overlay = stage.themes.resolve(Asekii::Render::Roles::Core::SurfaceOverlay.value)
    hover.should_not eq(overlay)
  end

  it "keeps hover distinct from surface at 16 colours" do
    stage = Engine.new
    stage.themes.depth = Asekii::Render::ColorDepth::Ansi16
    hover = stage.themes.resolve(Asekii::Render::Roles::Core::Hover.value)
    surface = stage.themes.resolve(Asekii::Render::Roles::Core::Surface.value)
    hover.should_not eq(surface)
  end

  it "maps a coloured surface to a non-grey index" do
    stage = Engine.new
    stage.themes.define(:solarized, base16: SOLARIZED_DARK16, fg: 0x93a1a1, bg: 0x002b36)
    stage.themes.use(:solarized)
    stage.themes.depth = Asekii::Render::ColorDepth::Indexed256
    surface = stage.themes.resolve(Asekii::Render::Roles::Core::Surface.value)
    surface.kind.should eq(Asekii::Render::Paint::Kind::Index)
    surface.value.should be < Asekii::Render::Palette::RAMP
  end

  it "orders elevation roles at 256 colours on a light palette" do
    stage = Engine.new
    stage.themes.define(:light, base16: LIGHT16, fg: 0x4c4f69, bg: 0xeff1f5)
    stage.themes.use(:light)
    stage.themes.depth = Asekii::Render::ColorDepth::Indexed256
    sunken = stage.themes.resolve(Asekii::Render::Roles::Core::SurfaceSunken.value).value
    surface = stage.themes.resolve(Asekii::Render::Roles::Core::Surface.value).value
    raised = stage.themes.resolve(Asekii::Render::Roles::Core::SurfaceRaised.value).value
    hover = stage.themes.resolve(Asekii::Render::Roles::Core::Hover.value).value
    sunken.should be < surface
    surface.should be <= raised
    raised.should be <= hover
  end
end
