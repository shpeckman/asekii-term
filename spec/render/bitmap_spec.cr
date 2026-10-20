# spec/render/bitmap_spec.cr
require "./support"

private def canvas(marks : Array({Int32, Int32}), width : Int32 = 128, height : Int32 = 96) : Asekii::Render::Bitmap
  bitmap = Asekii::Render::Bitmap.new(width, height)
  marks.each { |x, y| bitmap[x, y] = 0xFF0000FF_u32 }
  bitmap
end

private def rect(x : Int32, y : Int32, width : Int32, height : Int32) : Asekii::Render::Bitmap::Rect
  Asekii::Render::Bitmap::Rect.new(x, y, width, height)
end

describe Asekii::Render::Bitmap do
  it "bounds every change in one rectangle" do
    canvas([{5, 6}, {40, 50}]).changes(canvas([] of {Int32, Int32})).should eq(rect(5, 6, 36, 45))
    canvas([{5, 6}]).changes(canvas([{5, 6}])).should be_nil
  end

  it "splits scattered changes into separate regions" do
    regions = canvas([{2, 3}, {120, 90}]).regions(canvas([] of {Int32, Int32}))
    regions.should eq([rect(2, 3, 1, 1), rect(120, 90, 1, 1)])
  end

  it "joins changed tiles that line up into one region" do
    fresh   = canvas([{4, 4}, {35, 4}, {4, 40}, {35, 40}, {100, 80}])
    regions = fresh.regions(canvas([] of {Int32, Int32}))
    regions.should eq([rect(4, 4, 32, 37), rect(100, 80, 1, 1)])
  end

  it "falls back to the bounding rectangle when regions would save little" do
    marks = [] of {Int32, Int32}
    (0...128).step(8) { |x| (0...96).step(8) { |y| marks << {x, y} } }
    canvas(marks).regions(canvas([] of {Int32, Int32})).should eq([rect(0, 0, 121, 89)])
  end

  it "returns no regions when nothing changed and the whole bitmap when the size did" do
    canvas([{1, 1}]).regions(canvas([{1, 1}])).should be_empty
    canvas([] of {Int32, Int32}, 8, 8).regions(canvas([] of {Int32, Int32})).should eq([rect(0, 0, 8, 8)])
  end

  it "diffs and crops raw pixels with any channel count" do
    fresh = Bytes[0, 0, 0, 9, 9, 9, 0, 0, 0, 0, 0, 0]
    stale = Bytes.new(12)
    Asekii::Render::Bitmap.regions(fresh, stale, 2, 2, 3).should eq([rect(1, 0, 1, 1)])
    Asekii::Render::Bitmap.crop(fresh, 2, rect(1, 0, 1, 1), 3).should eq(Bytes[9, 9, 9])
  end
end
