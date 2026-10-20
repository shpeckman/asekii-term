# spec/render/color_spec.cr
require "./support"

private def close(a : UInt32, b : UInt32, slack : Int32 = 1) : Bool
  {16, 8, 0}.all? { |shift| (((a >> shift) & 0xFF).to_i - ((b >> shift) & 0xFF).to_i).abs <= slack }
end

describe Asekii::Render::ColorSpace do
  it "round-trips every sRGB level through linear light" do
    256.times do |level|
      Asekii::Render::ColorSpace.encode(Asekii::Render::ColorSpace.decode(level.to_u8)).should eq(level.to_u8)
    end
  end

  it "round-trips colors through CIELAB and Oklab" do
    [0x000000_u32, 0xffffff_u32, 0x1e66f5_u32, 0xf38ba8_u32, 0x40a02b_u32, 0x808080_u32].each do |rgb|
      close(Asekii::Render::ColorSpace.from_lab(Asekii::Render::ColorSpace.lab(rgb)), rgb).should be_true
      close(Asekii::Render::ColorSpace.from_oklab(Asekii::Render::ColorSpace.oklab(rgb)), rgb).should be_true
    end
  end

  it "measures CIELAB lightness" do
    Asekii::Render::ColorSpace.lightness(0xffffff_u32).should be_close(100.0, 0.05)
    Asekii::Render::ColorSpace.lightness(0x000000_u32).should be_close(0.0, 0.05)
    Asekii::Render::ColorSpace.lightness(0x777777_u32).should be_close(50.0, 0.6)
  end

  it "mixes in the requested space" do
    Asekii::Render::ColorSpace.mix(0x000000_u32, 0xffffff_u32, 0.5_f32, Asekii::Render::BlendSpace::Linear).should eq(0xbcbcbc_u32)
    close(Asekii::Render::ColorSpace.mix(0x000000_u32, 0xffffff_u32, 0.5_f32, Asekii::Render::BlendSpace::Lab), 0x777777_u32).should be_true
    close(Asekii::Render::ColorSpace.mix(0x000000_u32, 0xffffff_u32, 0.5_f32, Asekii::Render::BlendSpace::Oklab), 0x777777_u32, 3).should be_true
    Asekii::Render::BlendSpace.each do |space|
      Asekii::Render::ColorSpace.mix(0x123456_u32, 0xfedcba_u32, 0.0_f32, space).should eq(0x123456_u32)
      Asekii::Render::ColorSpace.mix(0x123456_u32, 0xfedcba_u32, 1.0_f32, space).should eq(0xfedcba_u32)
    end
  end

  it "keeps a blue to white fade free of purple in Oklab" do
    middle = Asekii::Render::ColorSpace.mix(0x0000ff_u32, 0xffffff_u32, 0.5_f32, Asekii::Render::BlendSpace::Oklab)
    ((middle >> 16) & 0xFF).should be <= ((middle >> 8) & 0xFF) + 8
  end

  it "round-trips colors through Oklch" do
    [0x000000_u32, 0xffffff_u32, 0x1e66f5_u32, 0xf38ba8_u32, 0x40a02b_u32, 0x808080_u32].each do |rgb|
      close(Asekii::Render::ColorSpace.from_oklch(Asekii::Render::ColorSpace.oklch(rgb)), rgb).should be_true
    end
  end

  it "gamut maps saturated chroma without shifting hue" do
    [0xff0000_u32, 0x00ff00_u32, 0x0000ff_u32, 0xff00ff_u32].each do |rgb|
      l, c, h = Asekii::Render::ColorSpace.oklch(rgb)
      mapped = Asekii::Render::ColorSpace.from_oklch({l, c * 2.0_f32, h})
      _, _, mapped_h = Asekii::Render::ColorSpace.oklch(mapped)
      gap = (mapped_h - h).abs
      gap = (Math::PI * 2 - gap) if gap > Math::PI
      gap.should be < 0.02
    end
  end

  it "clamps out-of-range lightness instead of clipping channels" do
    Asekii::Render::ColorSpace.from_oklch({1.2_f32, 0.0_f32, 0.0_f32}).should eq(0xffffff_u32)
    Asekii::Render::ColorSpace.from_oklch({-0.2_f32, 0.0_f32, 0.0_f32}).should eq(0x000000_u32)
  end

  it "measures WCAG contrast" do
    Asekii::Render::ColorSpace.contrast(0x000000_u32, 0xffffff_u32).should be_close(21.0, 0.01)
    Asekii::Render::ColorSpace.contrast(0x808080_u32, 0x808080_u32).should be_close(1.0, 0.01)
  end

  it "measures APCA lightness contrast" do
    Asekii::Render::ColorSpace.apca(0x808080_u32, 0x808080_u32).should be_close(0.0, 0.01)
    Asekii::Render::ColorSpace.apca(0x000000_u32, 0xffffff_u32).should be > 90.0
  end

  it "bridges WCAG ratios to APCA Lc" do
    Asekii::Render::ColorSpace.wcag_to_apca(3.0_f32).should be_close(60.0, 0.5)
    Asekii::Render::ColorSpace.wcag_to_apca(4.5_f32).should be_close(75.0, 0.5)
    Asekii::Render::ColorSpace.wcag_to_apca(7.0_f32).should be_close(90.0, 0.5)
    Asekii::Render::ColorSpace.wcag_to_apca(21.0_f32).should be_close(106.0, 0.5)
  end
end

describe Asekii::Render::Palette do
  it "builds the stock xterm table" do
    stock = Asekii::Render::Palette.stock
    stock[16].should eq(0x000000_u32)
    stock[21].should eq(0x0000ff_u32)
    stock[196].should eq(0xff0000_u32)
    stock[231].should eq(0xffffff_u32)
    stock[232].should eq(0x080808_u32)
    stock[255].should eq(0xeeeeee_u32)
    stock.themed?.should be_false
  end

  it "generates the cube and ramp from base16 in each blend space" do
    base = DARK16.map(&.to_u32)
    {Asekii::Render::BlendSpace::Oklab, Asekii::Render::BlendSpace::Lab}.each do |space|
      palette = Asekii::Render::Palette.generate(base, 0xcdd6f4_u32, 0x1e1e2e_u32, space: space)
      16.times { |index| palette[index].should eq(base[index]) }
      close(palette[16], 0x1e1e2e_u32).should be_true
      close(palette[231], 0xcdd6f4_u32).should be_true
      close(palette[16 + 36 * 5], base[1]).should be_true
      close(palette[16 + 6 * 5], base[2]).should be_true
      close(palette[16 + 5], base[4]).should be_true
      palette.themed?.should be_true
      levels = (232..255).map { |index| Asekii::Render::ColorSpace.lightness(palette[index]) }
      levels.each_cons_pair { |low, high| high.should be > low }
      levels.first.should be > Asekii::Render::ColorSpace.lightness(0x1e1e2e_u32)
      levels.last.should be < Asekii::Render::ColorSpace.lightness(0xcdd6f4_u32)
    end
  end

  it "swaps the corners on light themes unless harmonious" do
    base = LIGHT16.map(&.to_u32)
    swapped = Asekii::Render::Palette.generate(base, 0x4c4f69_u32, 0xeff1f5_u32)
    close(swapped[16], 0x4c4f69_u32).should be_true
    close(swapped[231], 0xeff1f5_u32).should be_true
    swapped.light?.should be_true
    swapped.inverted?.should be_true
    swapped.ramp(0).should eq(255)
    kept = Asekii::Render::Palette.generate(base, 0x4c4f69_u32, 0xeff1f5_u32, harmonious: true)
    close(kept[16], 0xeff1f5_u32).should be_true
    kept.inverted?.should be_false
    kept.ramp(0).should eq(232)
  end

  it "finds the nearest entry and forgets it when a color changes" do
    palette = Asekii::Render::Palette.stock
    palette.nearest(0xff0000_u32).should eq(9_u8)
    palette.nearest(0x0000fe_u32).should eq(21_u8)
    palette.nearest(0x0000fe_u32, 16).should eq(4_u8)
    palette[21] = 0x00ff00_u32
    palette.nearest(0x0000fe_u32).should_not eq(21_u8)
  end

  it "keeps chromatic colours off the grey ramp in the chroma-aware nearest" do
    palette = Asekii::Render::Palette.stock
    palette.nearest_chroma(0x008080_u32).should be < Asekii::Render::Palette::RAMP
    palette.nearest_chroma(0x808080_u32).should be >= Asekii::Render::Palette::RAMP
  end

  it "interpolates whole palettes" do
    from = Asekii::Render::Palette.stock
    to = Asekii::Render::Palette.generate(DARK16.map(&.to_u32), 0xcdd6f4_u32, 0x1e1e2e_u32)
    Asekii::Render::Palette.mix(from, to, 0.0_f32, Asekii::Render::BlendSpace::Oklab).same?(from).should be_true
    Asekii::Render::Palette.mix(from, to, 1.0_f32, Asekii::Render::BlendSpace::Oklab).same?(to).should be_true
    half = Asekii::Render::Palette.mix(from, to, 0.5_f32, Asekii::Render::BlendSpace::Oklab)
    half.same?(from).should be_false
    half.same?(to).should be_false
  end

  it "rejects tables of the wrong size" do
    expect_raises(ArgumentError) { Asekii::Render::Palette.generate([0_u32], 0_u32, 0_u32) }
    expect_raises(ArgumentError) { Asekii::Render::Palette.new(Slice(UInt32).new(3, 0_u32), 0_u32, 0_u32) }
  end
end

describe Asekii::Render::Paint do
  it "converts the accepted color forms" do
    Asekii::Render::Paint.fg(:default).kind.should eq(Asekii::Render::Paint::Kind::Foreground)
    Asekii::Render::Paint.bg(:default).kind.should eq(Asekii::Render::Paint::Kind::Background)
    Asekii::Render::Paint.fg(:background).kind.should eq(Asekii::Render::Paint::Kind::Background)
    Asekii::Render::Paint.bg(4).should eq(Asekii::Render::Paint.index(4))
    Asekii::Render::Paint.fg("#ff8800").should eq(Asekii::Render::Paint.rgb(0xff8800_u32))
    Asekii::Render::Paint.fg(Asekii::Render::Paint.rgb(1_u8, 2_u8, 3_u8, 0.5)).should eq(Asekii::Render::Paint.rgb(0x010203_u32, 128_u8))
    Asekii::Render::Paint.bg({:surface, 0.5}).should eq(Asekii::Render::Paint.new(Asekii::Render::Paint::Kind::Role, 0_u32, 128_u8))
    Asekii::Render::Paint.fg(:none).clear?.should be_true
    Asekii::Render::Paint.fg(:accent).should eq(Asekii::Render::Paint.role(Asekii::Render::Roles::Core::Accent.value))
    Asekii::Render::Paint.fg("sidebar").value.should eq(Asekii::Render::Roles.slot("sidebar").to_u32)
    expect_raises(ArgumentError) { Asekii::Render::Paint.fg(300) }
    expect_raises(ArgumentError) { Asekii::Render::Paint.fg("#zz") }
  end

  it "accepts contrast specs as paints" do
    spec = Asekii::Render::Contrast.mix(:surface, 4.5, :foreground, :background, 1.0)
    Asekii::Render::Paint.bg(spec).kind.should eq(Asekii::Render::Paint::Kind::Spec)
  end

  it "interns multi-codepoint clusters and keeps single codepoints inline" do
    Asekii::Render::Graphemes.intern("a").should eq(97_u32)
    family = Asekii::Render::Graphemes.intern("👨‍👩‍👧")
    Asekii::Render::Graphemes.pooled?(family).should be_true
    Asekii::Render::Graphemes.intern("👨‍👩‍👧").should eq(family)
    Asekii::Render::Graphemes.text(family).should eq("👨‍👩‍👧")
  end
end
