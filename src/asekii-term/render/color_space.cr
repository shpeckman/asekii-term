# src/asekii-term/render/color_space.cr
module Asekii::Render
  enum BlendSpace
    Linear
    Lab
    Oklab
  end

  module ColorSpace
    extend self

    alias Triple = Tuple(Float32, Float32, Float32)

    ENCODE_STEPS = 4095

    DECODE = Slice(Float32).new(256) do |index|
      value = index / 255.0
      (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4).to_f32
    end

    ENCODE = Slice(UInt8).new(ENCODE_STEPS + 1) do |index|
      value = index / ENCODE_STEPS.to_f
      coded = value <= 0.0031308 ? value * 12.92 : 1.055 * (value ** (1 / 2.4)) - 0.055
      (coded * 255).round.clamp(0.0, 255.0).to_u8
    end

    WHITE_X    =  0.95047_f32
    WHITE_Z    =  1.08883_f32
    LAB_EPS    = 0.008856_f32
    LAB_K      =    7.787_f32
    LAB_OFF    = (16.0 / 116.0).to_f32
    GAMUT_EPS  = 1e-4_f32
    MAX_CHROMA =  0.4_f32

    TOE_K1 = 0.206_f32
    TOE_K2 =  0.03_f32
    TOE_K3 = (1.0_f32 + TOE_K1) / (1.0_f32 + TOE_K2)

    @[AlwaysInline]
    def pack(r : UInt8, g : UInt8, b : UInt8) : UInt32
      (r.to_u32 << 16) | (g.to_u32 << 8) | b.to_u32
    end

    def parse(text : String) : Tuple(UInt32, UInt8)?
      parsed = ColorSyntax.parse(text) || return
      channels, opacity = parsed
      alpha = (opacity.clamp(0.0, 1.0) * 255).round.to_u8
      {pack((channels.red >> 8).to_u8!, (channels.green >> 8).to_u8!, (channels.blue >> 8).to_u8!), alpha}
    end

    @[AlwaysInline]
    def red(rgb : UInt32) : UInt8
      (rgb >> 16).to_u8!
    end

    @[AlwaysInline]
    def green(rgb : UInt32) : UInt8
      (rgb >> 8).to_u8!
    end

    @[AlwaysInline]
    def blue(rgb : UInt32) : UInt8
      rgb.to_u8!
    end

    @[AlwaysInline]
    def decode(byte : UInt8) : Float32
      DECODE.unsafe_fetch(byte)
    end

    @[AlwaysInline]
    def encode(value : Float32) : UInt8
      clamped = value > 0.0_f32 ? (value < 1.0_f32 ? value : 1.0_f32) : 0.0_f32
      ENCODE.unsafe_fetch((clamped * ENCODE_STEPS + 0.5_f32).to_i)
    end

    def linear(rgb : UInt32) : Triple
      {decode(red(rgb)), decode(green(rgb)), decode(blue(rgb))}
    end

    def from_linear(value : Triple) : UInt32
      pack(encode(value[0]), encode(value[1]), encode(value[2]))
    end

    def lab(rgb : UInt32) : Triple
      r, g, b = linear(rgb)
      fx = lab_forward((0.4124564_f32 * r + 0.3575761_f32 * g + 0.1804375_f32 * b) / WHITE_X)
      fy = lab_forward(0.2126729_f32 * r + 0.7151522_f32 * g + 0.0721750_f32 * b)
      fz = lab_forward((0.0193339_f32 * r + 0.1191920_f32 * g + 0.9503041_f32 * b) / WHITE_Z)
      {116.0_f32 * fy - 16.0_f32, 500.0_f32 * (fx - fy), 200.0_f32 * (fy - fz)}
    end

    def from_lab(value : Triple) : UInt32
      fy = (value[0] + 16.0_f32) / 116.0_f32
      x = lab_inverse(fy + value[1] / 500.0_f32) * WHITE_X
      y = lab_inverse(fy)
      z = lab_inverse(fy - value[2] / 200.0_f32) * WHITE_Z
      from_linear({
        3.2404542_f32 * x - 1.5371385_f32 * y - 0.4985314_f32 * z,
        -0.9692660_f32 * x + 1.8760108_f32 * y + 0.0415560_f32 * z,
        0.0556434_f32 * x - 0.2040259_f32 * y + 1.0572252_f32 * z,
      })
    end

    def oklab(rgb : UInt32) : Triple
      r, g, b = linear(rgb)
      l = Math.cbrt(0.4122214708_f32 * r + 0.5363325363_f32 * g + 0.0514459929_f32 * b)
      m = Math.cbrt(0.2119034982_f32 * r + 0.6806995451_f32 * g + 0.1073969566_f32 * b)
      s = Math.cbrt(0.0883024619_f32 * r + 0.2817188376_f32 * g + 0.6299787005_f32 * b)
      {
        toe(0.2104542553_f32 * l + 0.7936177850_f32 * m - 0.0040720468_f32 * s),
        1.9779984951_f32 * l - 2.4285922050_f32 * m + 0.4505937099_f32 * s,
        0.0259040371_f32 * l + 0.7827717662_f32 * m - 0.8086757660_f32 * s,
      }
    end

    def from_oklab(value : Triple) : UInt32
      linear = oklab_linear(value)
      return from_linear(linear) if in_gamut?(linear)
      lightness = value[0].clamp(0.0_f32, 1.0_f32)
      a = value[1]
      b = value[2]
      chroma = Math.sqrt(a * a + b * b)
      linear = oklab_linear({lightness, a, b})
      return from_linear(linear) if chroma <= 0.0_f32 || in_gamut?(linear)
      hue = Math.atan2(b, a)
      cap = max_chroma(lightness, hue)
      return from_linear(linear) if chroma <= cap
      scale = cap / chroma
      from_linear(oklab_linear({lightness, a * scale, b * scale}))
    end

    def oklch(rgb : UInt32) : Triple
      l, a, b = oklab(rgb)
      {l, Math.sqrt(a * a + b * b), Math.atan2(b, a)}
    end

    def from_oklch(value : Triple) : UInt32
      l, c, h = value
      from_oklab({l, c * Math.cos(h), c * Math.sin(h)})
    end

    def luminance(rgb : UInt32) : Float32
      r, g, b = linear(rgb)
      0.2126_f32 * r + 0.7152_f32 * g + 0.0722_f32 * b
    end

    def contrast(a : UInt32, b : UInt32) : Float32
      hi = Math.max(luminance(a), luminance(b))
      lo = Math.min(luminance(a), luminance(b))
      (hi + 0.05_f32) / (lo + 0.05_f32)
    end

    def apca(a : UInt32, b : UInt32) : Float32
      apca_lc(luminance(a), luminance(b))
    end

    def wcag_to_apca(ratio : Float32) : Float32
      anchors = [
        {1.0_f32, 0.0_f32},
        {3.0_f32, 60.0_f32},
        {4.5_f32, 75.0_f32},
        {7.0_f32, 90.0_f32},
        {21.0_f32, 106.0_f32},
      ]
      return anchors.last[1] if ratio >= anchors.last[0]
      (anchors.size - 1).times do |index|
        lo_r, lo_lc = anchors[index]
        hi_r, hi_lc = anchors[index + 1]
        next unless ratio <= hi_r
        amount = (ratio - lo_r) / (hi_r - lo_r)
        return lo_lc + (hi_lc - lo_lc) * amount
      end
      anchors.last[1]
    end

    def coords(rgb : UInt32, space : BlendSpace) : Triple
      case space
      in BlendSpace::Linear then linear(rgb)
      in BlendSpace::Lab    then lab(rgb)
      in BlendSpace::Oklab  then oklab(rgb)
      end
    end

    def rgb(value : Triple, space : BlendSpace) : UInt32
      case space
      in BlendSpace::Linear then from_linear(value)
      in BlendSpace::Lab    then from_lab(value)
      in BlendSpace::Oklab  then from_oklab(value)
      end
    end

    def lerp(a : Triple, b : Triple, amount : Float32) : Triple
      {a[0] + (b[0] - a[0]) * amount, a[1] + (b[1] - a[1]) * amount, a[2] + (b[2] - a[2]) * amount}
    end

    def mix(a : UInt32, b : UInt32, amount : Float32, space : BlendSpace) : UInt32
      return a if amount <= 0.0_f32 || a == b
      return b if amount >= 1.0_f32
      rgb(lerp(coords(a, space), coords(b, space), amount), space)
    end

    def lightness(rgb : UInt32) : Float32
      r, g, b = linear(rgb)
      116.0_f32 * lab_forward(0.2126729_f32 * r + 0.7151522_f32 * g + 0.0721750_f32 * b) - 16.0_f32
    end

    def distance(a : Triple, b : Triple) : Float32
      d0 = a[0] - b[0]
      d1 = a[1] - b[1]
      d2 = a[2] - b[2]
      d0 * d0 + d1 * d1 + d2 * d2
    end

    @[AlwaysInline]
    private def lab_forward(value : Float32) : Float32
      value > LAB_EPS ? Math.cbrt(value) : LAB_K * value + LAB_OFF
    end

    @[AlwaysInline]
    private def lab_inverse(value : Float32) : Float32
      cube = value * value * value
      cube > LAB_EPS ? cube : (value - LAB_OFF) / LAB_K
    end

    @[AlwaysInline]
    private def toe(value : Float32) : Float32
      shifted = TOE_K3 * value - TOE_K1
      0.5_f32 * (shifted + Math.sqrt(shifted * shifted + 4.0_f32 * TOE_K2 * TOE_K3 * value))
    end

    @[AlwaysInline]
    private def toe_inverse(value : Float32) : Float32
      (value * value + TOE_K1 * value) / (TOE_K3 * (value + TOE_K2))
    end

    @[AlwaysInline]
    private def oklab_linear(value : Triple) : Triple
      lightness = toe_inverse(value[0])
      l = lightness + 0.3963377774_f32 * value[1] + 0.2158037573_f32 * value[2]
      m = lightness - 0.1055613458_f32 * value[1] - 0.0638541728_f32 * value[2]
      s = lightness - 0.0894841775_f32 * value[1] - 1.2914855480_f32 * value[2]
      l = l * l * l
      m = m * m * m
      s = s * s * s
      {
        4.0767416621_f32 * l - 3.3077115913_f32 * m + 0.2309699292_f32 * s,
        -1.2684380046_f32 * l + 2.6097574011_f32 * m - 0.3413193965_f32 * s,
        -0.0041960863_f32 * l - 0.7034186147_f32 * m + 1.7076147010_f32 * s,
      }
    end

    @[AlwaysInline]
    private def in_gamut?(value : Triple) : Bool
      value[0] >= -GAMUT_EPS && value[0] <= 1.0_f32 + GAMUT_EPS &&
        value[1] >= -GAMUT_EPS && value[1] <= 1.0_f32 + GAMUT_EPS &&
        value[2] >= -GAMUT_EPS && value[2] <= 1.0_f32 + GAMUT_EPS
    end

    private def apca_lc(text : Float32, bg : Float32) : Float32
      black = 0.022_f32
      clamp_p = 1.414_f32
      soft_text = text > black ? text : text + (black - text) ** clamp_p
      soft_bg = bg > black ? bg : bg + (black - bg) ** clamp_p
      return 0.0_f32 if (soft_bg - soft_text).abs < 0.0005_f32
      value =
        if soft_bg > soft_text
          (soft_bg ** 0.56_f32 - soft_text ** 0.57_f32) * 1.14_f32 - 0.027_f32
        else
          (soft_bg ** 0.65_f32 - soft_text ** 0.62_f32) * 1.14_f32 + 0.027_f32
        end
      value.abs * 100.0_f32
    end

    private def max_chroma(lightness : Float32, hue : Float32) : Float32
      lo = 0.0_f32
      hi = MAX_CHROMA
      24.times do
        mid = (lo + hi) / 2.0_f32
        a = mid * Math.cos(hue)
        b = mid * Math.sin(hue)
        if in_gamut?(oklab_linear({lightness, a, b}))
          lo = mid
        else
          hi = mid
        end
      end
      lo
    end
  end
end
