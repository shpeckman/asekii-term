# src/asekii-term/render/palette.cr
module Asekii::Render
  class Palette
    SIZE       =  256
    CUBE       =   16
    RAMP       =  232
    RAMP_STEPS =   24
    CACHE_MAX  = 4096

    ANSI = [
      0x000000_u32, 0xcd0000_u32, 0x00cd00_u32, 0xcdcd00_u32,
      0x0000ee_u32, 0xcd00cd_u32, 0x00cdcd_u32, 0xe5e5e5_u32,
      0x7f7f7f_u32, 0xff0000_u32, 0x00ff00_u32, 0xffff00_u32,
      0x5c5cff_u32, 0xff00ff_u32, 0x00ffff_u32, 0xffffff_u32,
    ]

    LEVELS = [0_u32, 95_u32, 135_u32, 175_u32, 215_u32, 255_u32]

    CHROMA_MIN = 0.02_f32
    HUE_WEIGHT =  4.0_f32

    STOCK = Slice(UInt32).new(SIZE) do |index|
      if index < CUBE
        ANSI[index]
      elsif index < RAMP
        cell = index - CUBE
        (LEVELS[cell // 36] << 16) | (LEVELS[cell // 6 % 6] << 8) | LEVELS[cell % 6]
      else
        level = (8 + 10 * (index - RAMP)).to_u32
        (level << 16) | (level << 8) | level
      end
    end

    STOCK_FG = 0xe5e5e5_u32
    STOCK_BG = 0x000000_u32

    getter colors : Slice(UInt32)
    property fg : UInt32
    property bg : UInt32

    @coords : Slice(ColorSpace::Triple)?

    def initialize(@colors : Slice(UInt32), @fg : UInt32, @bg : UInt32)
      raise ArgumentError.new("a palette holds #{SIZE} colors") unless @colors.size == SIZE
      @coords = nil
      @near = {} of UInt32 => UInt8
      @near16 = {} of UInt32 => UInt8
    end

    def self.stock : Palette
      new(STOCK.dup, STOCK_FG, STOCK_BG)
    end

    def self.generate(base16 : Indexable(UInt32), fg : UInt32, bg : UInt32, harmonious : Bool = false,
                      space : BlendSpace = BlendSpace::Oklab) : Palette
      raise ArgumentError.new("base16 needs 16 colors") unless base16.size == 16
      corners = StaticArray(ColorSpace::Triple, 8).new do |index|
        ColorSpace.coords(index == 0 ? bg : (index == 7 ? fg : base16[index]), space)
      end
      if corners[7][0] < corners[0][0] && !harmonious
        dark = corners[7]
        corners[7] = corners[0]
        corners[0] = dark
      end
      colors = Slice(UInt32).new(SIZE, 0_u32)
      16.times { |index| colors[index] = base16[index] }
      6.times do |r|
        along = r / 5.0_f32
        c0 = ColorSpace.lerp(corners[0], corners[1], along)
        c1 = ColorSpace.lerp(corners[2], corners[3], along)
        c2 = ColorSpace.lerp(corners[4], corners[5], along)
        c3 = ColorSpace.lerp(corners[6], corners[7], along)
        6.times do |g|
          across = g / 5.0_f32
          c4 = ColorSpace.lerp(c0, c1, across)
          c5 = ColorSpace.lerp(c2, c3, across)
          6.times do |b|
            colors[CUBE + 36 * r + 6 * g + b] = ColorSpace.rgb(ColorSpace.lerp(c4, c5, b / 5.0_f32), space)
          end
        end
      end
      RAMP_STEPS.times do |index|
        colors[RAMP + index] = ColorSpace.rgb(ColorSpace.lerp(corners[0], corners[7], (index + 1) / 25.0_f32), space)
      end
      new(colors, fg, bg)
    end

    def self.mix(from : Palette, to : Palette, amount : Float32, space : BlendSpace) : Palette
      colors = Slice(UInt32).new(SIZE) do |index|
        ColorSpace.mix(from.colors.unsafe_fetch(index), to.colors.unsafe_fetch(index), amount, space)
      end
      new(colors, ColorSpace.mix(from.fg, to.fg, amount, space), ColorSpace.mix(from.bg, to.bg, amount, space))
    end

    def dup : Palette
      Palette.new(@colors.dup, @fg, @bg)
    end

    def copy(other : Palette) : Nil
      other.colors.copy_to(@colors)
      @fg = other.fg
      @bg = other.bg
      forget
    end

    @[AlwaysInline]
    def [](index : Int) : UInt32
      @colors.unsafe_fetch(index & 0xFF)
    end

    def []=(index : Int, rgb : UInt32) : UInt32
      @colors[index] = rgb
      forget
      rgb
    end

    def same?(other : Palette) : Bool
      @fg == other.fg && @bg == other.bg && @colors == other.colors
    end

    def themed? : Bool
      index = CUBE
      while index < SIZE
        return true unless @colors.unsafe_fetch(index) == STOCK.unsafe_fetch(index)
        index += 1
      end
      false
    end

    def light? : Bool
      ColorSpace.lightness(@bg) > ColorSpace.lightness(@fg)
    end

    def inverted? : Bool
      toward = ColorSpace.oklab(@bg)
      ColorSpace.distance(ColorSpace.oklab(@colors[SIZE - 1]), toward) <
        ColorSpace.distance(ColorSpace.oklab(@colors[RAMP]), toward)
    end

    def ramp(step : Int32) : Int32
      offset = step.clamp(0, RAMP_STEPS - 1)
      inverted? ? SIZE - 1 - offset : RAMP + offset
    end

    def nearest(rgb : UInt32, limit : Int32 = SIZE) : UInt8
      cache = limit <= CUBE ? @near16 : @near
      if found = cache[rgb]?
        return found
      end
      table = coords
      target = ColorSpace.oklab(rgb)
      best = 0
      least = Float32::MAX
      index = 0
      count = Math.min(limit, SIZE)
      while index < count
        gap = ColorSpace.distance(table.unsafe_fetch(index), target)
        if gap < least
          least = gap
          best = index
        end
        index += 1
      end
      cache.clear if cache.size >= CACHE_MAX
      cache[rgb] = best.to_u8
    end

    def nearest_chroma(rgb : UInt32, limit : Int32 = SIZE) : UInt8
      table = coords
      target = ColorSpace.oklab(rgb)
      tl, ta, tb = target
      chroma = Math.sqrt(ta * ta + tb * tb)
      best = 0
      least = Float32::MAX
      if chroma < CHROMA_MIN
        {0, 7, 8, 15}.each do |index|
          next unless index < limit
          gap = ColorSpace.distance(table.unsafe_fetch(index), target)
          if gap < least
            least = gap
            best = index
          end
        end
        index = RAMP
        count = Math.min(limit, SIZE)
        while index < count
          gap = ColorSpace.distance(table.unsafe_fetch(index), target)
          if gap < least
            least = gap
            best = index
          end
          index += 1
        end
      else
        index = 0
        count = Math.min(limit, SIZE)
        while index < count
          candidate = table.unsafe_fetch(index)
          dl = candidate[0] - tl
          da = candidate[1] - ta
          db = candidate[2] - tb
          gap = dl * dl + HUE_WEIGHT * (da * da + db * db)
          if gap < least
            least = gap
            best = index
          end
          index += 1
        end
      end
      best.to_u8
    end

    private def coords : Slice(ColorSpace::Triple)
      @coords ||= Slice(ColorSpace::Triple).new(SIZE) { |index| ColorSpace.oklab(@colors.unsafe_fetch(index)) }
    end

    private def forget : Nil
      @coords = nil
      @near.clear
      @near16.clear
    end
  end
end
