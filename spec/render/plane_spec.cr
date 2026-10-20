# spec/render/plane_spec.cr
require "./support"

describe Asekii::Render::Plane do
  it "writes text and reports the columns it advanced" do
    stage = Engine.new
    plane = stage.plane(10, 2)
    plane.put(1, 0, "abc").should eq(3)
    plane[1, 0].text.should eq("a")
    plane[3, 0].text.should eq("c")
    plane[4, 0].inked?.should be_false
    plane.put(8, 0, "wxyz").should eq(2)
    plane.put(-2, 1, "abcd").should eq(4)
    plane[0, 1].text.should eq("c")
    plane.put(0, 5, "nope").should eq(0)
  end

  it "skips control characters and zero width clusters" do
    stage = Engine.new
    plane = stage.plane(10, 1)
    plane.put(0, 0, "a\tb\e\u0085c").should eq(3)
    plane[2, 0].text.should eq("c")
  end

  it "stores wide glyphs as a head and a continuation" do
    stage = Engine.new
    plane = stage.plane(6, 1)
    plane.put(0, 0, "日本").should eq(4)
    plane[0, 0].text.should eq("日")
    plane[0, 0].span.should eq(2_u8)
    plane[1, 0].cont?.should be_true
    plane[1, 0].dx.should eq(1_u8)
    plane[2, 0].text.should eq("本")
  end

  it "blanks the other half when a wide glyph is partly overwritten" do
    stage = Engine.new
    plane = stage.plane(6, 1)
    plane.put(0, 0, "日本", bg: 4)
    plane.put(1, 0, "x")
    plane[0, 0].inked?.should be_false
    plane[0, 0].bg.should eq(Asekii::Render::Paint.index(4))
    plane[1, 0].text.should eq("x")
    plane.put(2, 0, "y")
    plane[3, 0].inked?.should be_false
  end

  it "turns a wide glyph in the last column into a space" do
    stage = Engine.new
    plane = stage.plane(3, 1)
    plane.put(2, 0, "日")
    plane[2, 0].text.should eq(" ")
    plane[2, 0].span.should eq(1_u8)
  end

  it "paints onto the background a cell already has" do
    stage = Engine.new
    plane = stage.plane(8, 2)
    plane.fill(bg: 5)
    plane.put(1, 0, "ab")
    plane.put(4, 0, "日")
    plane[1, 0].bg.should eq(Asekii::Render::Paint.index(5))
    plane[5, 0].bg.should eq(Asekii::Render::Paint.index(5))
    plane.put(1, 0, "c", bg: 2)
    plane[1, 0].bg.should eq(Asekii::Render::Paint.index(2))
    plane.fill(0, 1, 2, 1, '#')
    plane[0, 1].bg.should eq(Asekii::Render::Paint.index(5))
    plane.put(6, 0, "z", bg: :none)
    plane[6, 0].bg.should eq(Asekii::Render::Paint.index(5))
    plane.erase(6, 0, 1, 1)
    plane[6, 0].bg.clear?.should be_true
    plane[6, 0].inked?.should be_false
  end

  it "mixes a translucent background into the one underneath" do
    stage = Engine.new
    plane = stage.plane(4, 1)
    plane.put(0, 0, "a", bg: {"#000000", 0.5})
    plane[0, 0].bg.should eq(Asekii::Render::Paint.rgb(0x000000_u32, 128_u8))
    plane.fill(1, 0, 2, 1, bg: "#ffffff")
    plane.put(1, 0, "b", bg: {"#000000", 0.5})
    plane[1, 0].bg.should eq(Asekii::Render::Paint.rgb(0xbbbbbb_u32))
    plane.fill(2, 0, 1, 1, bg: {"#ffffff", 0.5})
    plane.fill(3, 0, 1, 1, bg: {"#ffffff", 0.5})
    plane.fill(3, 0, 1, 1, bg: {"#ffffff", 0.5})
    plane[2, 0].bg.should eq(Asekii::Render::Paint.rgb(0xffffff_u32))
    plane[3, 0].bg.value.should eq(0xffffff_u32)
    plane[3, 0].bg.alpha.should be_close(192, 1)
    stage.plane(1, 1).fill(bg: 4)
    stage.planes_top.put(0, 0, "r", bg: {:accent, 0.5})
    stage.planes_top[0, 0].bg.kind.should eq(Asekii::Render::Paint::Kind::RGB)
  end

  it "fills, erases and keeps the base cell" do
    stage = Engine.new
    plane = stage.plane(4, 2)
    plane.base('.', fg: 2, bg: 0)
    plane.fill(1, 0, 2, 1, '#', bg: 5)
    plane[1, 0].text.should eq("#")
    plane[2, 0].bg.should eq(Asekii::Render::Paint.index(5))
    plane.erase(1, 0, 1, 1)
    plane[1, 0].inked?.should be_false
    plane[1, 0].bg.clear?.should be_true
    plane.erase
    plane[2, 0].inked?.should be_false
    plane.base_cell.text.should eq(".")
  end

  it "keeps contents on resize and cuts blocks at the new edge" do
    stage = Engine.new
    plane = stage.plane(4, 2)
    plane.put(0, 0, "ab")
    plane.put(2, 0, "日")
    plane.resize(3, 3)
    plane[1, 0].text.should eq("b")
    plane[2, 0].inked?.should be_false
    plane[0, 2].inked?.should be_false
    plane.resize(6, 1)
    plane[0, 0].text.should eq("a")
    plane.rows.should eq(1)
  end

  it "follows its parent and tells bound planes about a resize" do
    stage  = Engine.new
    parent = stage.plane(8, 3, 2, 1)
    child  = parent.plane(2, 1, 1, 1)
    child.abs_x.should eq(3)
    child.abs_y.should eq(2)
    parent.move(5, 0)
    child.abs_x.should eq(6)
    seen = [] of Int32
    child.on_resize { |plane| seen << plane.parent.not_nil!.cols }
    parent.resize(4, 3)
    seen.should eq([4])
    parent.visible = false
    child.shown?.should be_false
    parent.dispose
    child.disposed?.should be_true
    child.put(0, 0, "x").should eq(0)
    stage.compositor.pile.planes.size.should eq(1)
  end

  it "writes image placeholder cells that keep the id exact" do
    stage = Engine.new
    plane = stage.plane(4, 2)
    plane.image(0, 0, 0x01020304_u32, 2, 2)
    plane[1, 1].exact?.should be_true
    plane[1, 1].fg.should eq(Asekii::Render::Paint.rgb(0x020304_u32))
    plane[1, 1].text.should eq(built_placeholder(1, 1, 1))
    expect_raises(ArgumentError) { plane.image(0, 0, 1_u32, 999, 1) }
  end

  it "is released when it is disposed" do
    stage = Engine.new
    plane = stage.plane(2, 2)
    stage.compositor.pile.planes.size.should eq(2)
    plane.dispose
    plane.disposed?.should be_true
    stage.compositor.pile.planes.size.should eq(1)
  end
end

private def built_placeholder(row : Int32, col : Int32, high : Int32) : String
  Asekii::UnicodePlaceholder.cell(row, col, high)
end
