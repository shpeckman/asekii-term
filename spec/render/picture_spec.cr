# spec/render/picture_spec.cr
require "./support"

PICTURE_INTERLACED = "iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAAH6aBZzAAAAW0lEQVR4nBWLoRWAQAxDo9Fo9OnqDoFGd4hOcpohOkTH6QYhqLz/kwBAoAECA/a8FItibmWCkYudApPe/9ryjJ1O2CzuSV0dND8YrsYvti/JQlhdjHLueqIr+QEanC10osB+vQAAAABJRU5ErkJggg=="
PICTURE_PALETTED   = "iVBORw0KGgoAAAANSUhEUgAAAAUAAAACAgMAAADtBP7OAAAADFBMVEX/AAAA/wAAAP8JCQlccX6GAAAABHRSTlP/gAD/oaGUZgAAAA5JREFUeJxjkGZgeOIAAAKVAUALFNHhAAAAAElFTkSuQmCC"
PICTURE_GRAY16     = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACEAAAAADoj+WFAAAAFklEQVR4nGNgYGhg+P+fkZGBkYGPAQAWqgKQf9JmewAAAABJRU5ErkJggg=="
PICTURE_TRUECOLOR  = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNkZGJmZmZmYOfg/PX7DwAHCQMausmz/gAAAABJRU5ErkJggg=="

private def decode(text : String) : Asekii::Raster
  Asekii::Raster.png(Base64.decode(text)).not_nil!
end

private def pixel(raster : Asekii::Raster, x : Int32, y : Int32) : Tuple(UInt8, UInt8, UInt8, UInt8)
  at = (y * raster.width + x) * 4
  {raster.data[at], raster.data[at + 1], raster.data[at + 2], raster.data[at + 3]}
end

private def solid(width : Int32, height : Int32, rgba : Tuple(UInt8, UInt8, UInt8, UInt8)) : Asekii::Raster
  data = Bytes.new(width * height * 4)
  (width * height).times do |index|
    data[index * 4] = rgba[0]
    data[index * 4 + 1] = rgba[1]
    data[index * 4 + 2] = rgba[2]
    data[index * 4 + 3] = rgba[3]
  end
  Asekii::Raster.rgba(data, width, height).not_nil!
end

private def inline(protocol : Asekii::ImageProtocol) : Engine
  engine = Engine.new(20, 6)
  engine.compositor.cell_pixels(4, 8)
  engine.compositor.images = protocol
  engine.frame
  engine
end

describe Asekii::Raster do
  it "decodes true colour, palette, sixteen-bit grey and interlaced PNG" do
    truecolor = decode(PICTURE_TRUECOLOR)
    {truecolor.width, truecolor.height}.should eq({2, 2})
    pixel(truecolor, 1, 1).should eq({250_u8, 251_u8, 252_u8, 255_u8})

    paletted = decode(PICTURE_PALETTED)
    pixel(paletted, 1, 0).should eq({0_u8, 255_u8, 0_u8, 128_u8})
    pixel(paletted, 2, 0).should eq({0_u8, 0_u8, 255_u8, 0_u8})
    pixel(paletted, 0, 1).should eq({9_u8, 9_u8, 9_u8, 255_u8})

    gray = decode(PICTURE_GRAY16)
    pixel(gray, 1, 0).should eq({128_u8, 128_u8, 128_u8, 255_u8})
    pixel(gray, 2, 1).should eq({16_u8, 16_u8, 16_u8, 255_u8})

    interlaced = decode(PICTURE_INTERLACED)
    pixel(interlaced, 3, 4).should eq({150_u8, 240_u8, 120_u8, 255_u8})
    pixel(interlaced, 4, 1).should eq({200_u8, 60_u8, 40_u8, 255_u8})
    pixel(interlaced, 2, 1).should eq({100_u8, 60_u8, 20_u8, 100_u8})
  end

  it "rejects data that is not a PNG or is cut short" do
    Asekii::Raster.png(Bytes[1, 2, 3]).should be_nil
    Asekii::Raster.png(Base64.decode(PICTURE_TRUECOLOR)[0, 40]).should be_nil
    Asekii::Raster.rgba(Bytes.new(3), 1, 1).should be_nil
  end

  it "round-trips through its own PNG encoder" do
    data = Bytes.new(7 * 5 * 4) { |index| (index * 37 % 256).to_u8 }
    raster = Asekii::Raster.rgba(data, 7, 5).not_nil!
    back = Asekii::Raster.png(raster.to_png).not_nil!
    back.data.should eq(raster.data)
  end

  it "widens RGB to opaque RGBA, crops and scales" do
    raster = Asekii::Raster.rgb(Bytes[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], 2, 2).not_nil!
    pixel(raster, 1, 1).should eq({10_u8, 11_u8, 12_u8, 255_u8})
    piece = raster.crop(1, 0, 5, 5)
    {piece.width, piece.height}.should eq({1, 2})
    pixel(piece, 0, 1).should eq({10_u8, 11_u8, 12_u8, 255_u8})
    grown = solid(2, 2, {200_u8, 100_u8, 50_u8, 255_u8}).scale(6, 4)
    {grown.width, grown.height}.should eq({6, 4})
    pixel(grown, 5, 3).should eq({200_u8, 100_u8, 50_u8, 255_u8})
  end

  it "encodes a solid band as one run of one colour" do
    solid(10, 6, {255_u8, 0_u8, 0_u8, 255_u8}).to_sixel.should eq("\eP0;1;0q\"1;1;10;6#0;2;100;0;0#0!10~\e\\")
  end

  it "leaves transparent pixels unpainted and keeps to the colour limit" do
    clear = solid(4, 6, {9_u8, 9_u8, 9_u8, 0_u8}).to_sixel
    clear.should eq("\eP0;1;0q\"1;1;4;6\e\\")
    data = Bytes.new(64 * 64 * 4) { |index| index % 4 == 3 ? 255_u8 : (index * 13 % 256).to_u8 }
    sixel = Asekii::Raster.rgba(data, 64, 64).not_nil!.to_sixel
    sixel.scan(/#(\d+);2;/).size.should be <= 255
    sixel.count('-').should eq(10)
  end

  it "encodes an iTerm2 inline image" do
    Asekii::Raster.iterm(Bytes[1, 2, 3], 4, 2).should eq("\e]1337;File=inline=1;size=3;width=4;height=2;preserveAspectRatio=0;doNotMoveCursor=1:AQID\a")
    Asekii::Raster.iterm(Bytes[1], 0, 0).should contain("width=auto;height=auto")
  end
end

describe "inline pictures" do
  it "draws a Sixel picture once at its cell, scaled to the cell box" do
    engine = inline(Asekii::ImageProtocol::Sixel)
    engine.compositor.root.picture(solid(2, 2, {0_u8, 0_u8, 255_u8, 255_u8}), 2, 1, 2, 1)
    engine.frame.should contain("\e[2;3H\eP0;1;0q\"1;1;8;8")
    engine.frame.should_not contain("\eP")
  end

  it "waits while something covers the picture and redraws it once uncovered" do
    engine = inline(Asekii::ImageProtocol::Sixel)
    engine.compositor.root.picture(solid(2, 2, {0_u8, 0_u8, 255_u8, 255_u8}), 2, 1, 2, 1)
    engine.frame
    cover = engine.plane(4, 1, 1, 1)
    cover.put(0, 0, "abcd")
    engine.frame.should_not contain("\eP")
    cover.visible = false
    engine.frame.should contain("\e[2;3H\eP0;1;0q")
  end

  it "erases the old cells and draws again when the picture moves or changes" do
    engine = inline(Asekii::ImageProtocol::Sixel)
    sprite = engine.compositor.root.picture(solid(2, 2, {0_u8, 0_u8, 255_u8, 255_u8}), 2, 1, 2, 1)
    engine.frame
    sprite.move(6, 2)
    frame = engine.frame
    frame.should contain("\e[3;7H\eP0;1;0q")
    frame.index("\e[2;3H").not_nil!.should be < frame.index("\eP").not_nil!
    sprite.picture = solid(2, 2, {255_u8, 0_u8, 0_u8, 255_u8})
    engine.frame.should contain("#0;2;100;0;0")
    sprite.dispose
    engine.frame.should_not contain("\eP")
  end

  it "crops to its clip and never touches the last row" do
    engine = inline(Asekii::ImageProtocol::Sixel)
    sprite = engine.compositor.root.picture(solid(4, 2, {0_u8, 255_u8, 0_u8, 255_u8}), 2, 1, 4, 1)
    sprite.clip = {2, 0, 4, 6}
    engine.frame.should contain("\"1;1;8;8")
    low = engine.compositor.root.picture(solid(2, 2, {0_u8, 255_u8, 0_u8, 255_u8}), 0, 5, 2, 1)
    engine.frame
    low.live.should be_nil
  end

  it "redraws when an erase to the end of the line wipes it" do
    engine = inline(Asekii::ImageProtocol::Sixel)
    engine.compositor.root.picture(solid(2, 2, {0_u8, 0_u8, 255_u8, 255_u8}), 14, 1, 2, 1)
    engine.frame
    engine.compositor.root.put(0, 1, "x")
    engine.frame
    engine.compositor.root.put(0, 1, " ")
    frame = engine.frame
    frame.should contain("\e[K")
    frame.should contain("\eP0;1;0q")
  end

  it "sends iTerm2 images sized in cells, and ignores pictures under the kitty protocol" do
    engine = inline(Asekii::ImageProtocol::Iterm)
    engine.compositor.root.picture(solid(2, 2, {0_u8, 0_u8, 255_u8, 255_u8}), 2, 1, 3, 2)
    engine.frame.should contain("\e[2;3H\e]1337;File=inline=1;size=")
    kitty = inline(Asekii::ImageProtocol::Kitty)
    kitty.compositor.root.picture(solid(2, 2, {0_u8, 0_u8, 255_u8, 255_u8}), 2, 1, 3, 2)
    frame = kitty.frame
    frame.should_not contain("\eP")
    frame.should_not contain("1337")
  end
end
