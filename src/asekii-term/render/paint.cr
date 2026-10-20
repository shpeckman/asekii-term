# src/asekii/render/paint.cr
require "termwidth"

module Asekii::Render
  @[Flags]
  enum Attr : UInt16
    Bold
    Dim
    Italic
    Underline
    DoubleUnderline
    CurlyUnderline
    DottedUnderline
    DashedUnderline
    Blink
    Reverse
    Conceal
    Strike
    Overline
    HighContrast
  end

  module Roles
    extend self

    enum Core
      Surface
      Text
      SurfaceRaised
      TextMuted
      Border
      Accent
      Selection
      Error
      Warning
      Success
      SurfaceSunken
      SurfaceOverlay
      Hover
      Focus
      OnAccent
      Info
      Shadow
    end

    @@slots = {} of String => Int32
    @@names = [] of String

    Core.each do |role|
      name = role.to_s.underscore
      @@slots[name] = role.value
      @@names << name
    end

    def slot(name : String | Symbol) : Int32
      key = name.to_s
      @@slots[key] ||= begin
        @@names << key
        @@names.size - 1
      end
    end

    def slot?(name : String | Symbol) : Int32?
      @@slots[name.to_s]?
    end

    def name(slot : Int32) : String
      @@names[slot]
    end

    def count : Int32
      @@names.size
    end
  end

  struct Paint
    enum Kind : UInt8
      Foreground
      Background
      Index
      RGB
      Role
      Spec
    end

    getter kind : Kind
    getter value : UInt32
    getter alpha : UInt8

    def initialize(@kind : Kind, @value : UInt32 = 0_u32, @alpha : UInt8 = 255_u8)
    end

    NONE = new(Kind::Background, 0_u32, 0_u8)

    FIXED = {
      "foreground"  => new(Kind::Foreground),
      "background"  => new(Kind::Background),
      "none"        => NONE,
      "transparent" => NONE,
    }

    def self.foreground : Paint
      new(Kind::Foreground)
    end

    def self.background : Paint
      new(Kind::Background)
    end

    def self.index(index : Int) : Paint
      raise ArgumentError.new("palette index #{index} is outside 0..255") unless 0 <= index <= 255
      new(Kind::Index, index.to_u32)
    end

    def self.rgb(rgb : UInt32, alpha : UInt8 = 255_u8) : Paint
      new(Kind::RGB, rgb & 0xFFFFFF_u32, alpha)
    end

    def self.rgb(r : UInt8, g : UInt8, b : UInt8, alpha : Float64 = 1.0) : Paint
      new(Kind::RGB, ColorSpace.pack(r, g, b), (alpha.clamp(0.0, 1.0) * 255).round.to_u8)
    end

    def self.role(slot : Int32) : Paint
      new(Kind::Role, slot.to_u32)
    end

    def self.role(name : String | Symbol) : Paint
      role(Roles.slot(name))
    end

    def self.spec(spec : RoleSpec) : Paint
      new(Kind::Spec, Specs.intern(spec))
    end

    def self.fg(value) : Paint
      of(value, Kind::Foreground)
    end

    def self.bg(value) : Paint
      of(value, Kind::Background)
    end

    def self.of(value : Paint, default : Kind) : Paint
      value
    end

    def self.of(value : Blend, default : Kind) : Paint
      spec(value)
    end

    def self.of(value : Adjust, default : Kind) : Paint
      spec(value)
    end

    def self.of(value : Contrast, default : Kind) : Paint
      spec(value)
    end

    def self.of(value : Int, default : Kind) : Paint
      index(value)
    end

    def self.of(value : Symbol | String, default : Kind) : Paint
      name = value.to_s
      return new(default) if name == "default"
      if fixed = FIXED[name]?
        return fixed
      end
      if name.starts_with?('#') || name.starts_with?("rgb")
        rgb, alpha = ColorSpace.parse(name) || raise ArgumentError.new("invalid color #{name.inspect}")
        return rgb(rgb, alpha)
      end
      role(name)
    end

    def self.of(value : Tuple(T, Float64), default : Kind) : Paint forall T
      of(value[0], default).fade(value[1])
    end

    def fade(amount : Float64) : Paint
      Paint.new(@kind, @value, (@alpha * amount.clamp(0.0, 1.0)).round.to_u8)
    end

    def opaque : Paint
      Paint.new(@kind, @value)
    end

    @[AlwaysInline]
    def clear? : Bool
      @alpha == 0_u8
    end

    @[AlwaysInline]
    def role? : Bool
      @kind.role?
    end

    @[AlwaysInline]
    def spec? : Bool
      @kind.spec?
    end

    def resolve(themes : Themes, theme : Theme?, palette : Palette, depth : Int32) : Paint
      themes.resolve_paint(self, theme, palette, depth)
    end

    def_equals_and_hash kind, value, alpha
  end

  module Graphemes
    extend self

    FLAG = 0x8000_0000_u32

    @@segmenter : TermWidth::Segmenter = TermWidth::Segmenter::NARROW
    @@pool = Interner(Bytes).new

    def segmenter : TermWidth::Segmenter
      @@segmenter
    end

    def profile : TermWidth::WidthProfile
      @@segmenter.profile
    end

    def profile=(profile : TermWidth::WidthProfile) : TermWidth::WidthProfile
      @@segmenter = TermWidth::Segmenter.new(profile)
      profile
    end

    def each(text : String, & : Bytes, UInt8 -> Nil) : Nil
      @@segmenter.each(text) { |cluster, width| yield cluster, width }
    end

    def split(text : String) : Array(Bytes)
      result = [] of Bytes
      each(text) { |cluster, _| result << cluster }
      result
    end

    def intern(cluster : Bytes) : UInt32
      point, length = TermWidth::Utf8.decode(cluster, 0)
      return point if length == cluster.size
      FLAG | @@pool.intern(cluster, &.dup).to_u32
    end

    def intern(text : String) : UInt32
      intern(text.to_slice)
    end

    @[AlwaysInline]
    def pooled?(glyph : UInt32) : Bool
      glyph & FLAG != 0_u32
    end

    def bytes(glyph : UInt32) : Bytes
      @@pool[(glyph & ~FLAG).to_i32]
    end

    def text(glyph : UInt32) : String
      return "" if glyph == 0_u32
      pooled?(glyph) ? String.new(bytes(glyph)) : glyph.unsafe_chr.to_s
    end
  end

  module Links
    extend self

    @@pool = Interner(String).new

    def intern(uri : String) : UInt32
      raise ArgumentError.new("a link cannot contain control characters") if uri.each_byte.any? { |byte| byte < 0x20_u8 || byte == 0x7F_u8 }
      @@pool.intern(uri).to_u32 + 1_u32
    end

    def uri(id : UInt32) : String
      @@pool[(id - 1).to_i32]
    end
  end

  struct Cell
    CONT   = 1_u8
    EXACT  = 2_u8
    STROKE = 4_u8

    getter glyph : UInt32
    getter fg : Paint
    getter bg : Paint
    getter line : Paint
    getter link : UInt32
    getter attrs : Attr
    getter span : UInt8
    getter dx : UInt8
    getter flags : UInt8

    def initialize(@glyph : UInt32 = 0_u32, @fg : Paint = Paint::NONE, @bg : Paint = Paint::NONE,
                   @attrs : Attr = Attr::None, @span : UInt8 = 1_u8, @dx : UInt8 = 0_u8,
                   @flags : UInt8 = 0_u8, @line : Paint = Paint::NONE, @link : UInt32 = 0_u32)
    end

    EMPTY = new

    @[AlwaysInline]
    def cont? : Bool
      @flags & CONT != 0_u8
    end

    @[AlwaysInline]
    def exact? : Bool
      @flags & EXACT != 0_u8
    end

    @[AlwaysInline]
    def stroke? : Bool
      @flags & STROKE != 0_u8
    end

    @[AlwaysInline]
    def block? : Bool
      @span > 1_u8
    end

    @[AlwaysInline]
    def inked? : Bool
      @glyph != 0_u32 || cont?
    end

    def text : String
      stroke? ? Strokes[@glyph].glyph.to_s : Graphemes.text(@glyph)
    end

    def lettered : Cell
      shape = Strokes[@glyph]
      return Cell.new(shape.glyph.ord.to_u32, @bg, Paint::NONE, @attrs, line: @line, link: @link) if shape.blank?
      Cell.new(shape.glyph.ord.to_u32, @fg, @bg, @attrs, line: @line, link: @link)
    end

    def blanked : Cell
      Cell.new(0_u32, @fg, @bg, @attrs, line: @line, link: @link)
    end
  end

  struct Tile
    enum Kind : UInt8
      Default
      Index
      RGB
    end

    CONT   = 1_u8
    BROKEN = 2_u8
    EXACT  = 4_u8
    LINES  = Attr::Underline | Attr::DoubleUnderline | Attr::CurlyUnderline | Attr::DottedUnderline |
             Attr::DashedUnderline | Attr::Reverse | Attr::Strike | Attr::Overline

    getter glyph : UInt32
    getter fg : UInt32
    getter bg : UInt32
    getter line : UInt32
    getter link : UInt32
    getter attrs : Attr
    getter fg_kind : Kind
    getter bg_kind : Kind
    getter line_kind : Kind
    getter span : UInt8
    getter dx : UInt8
    getter flags : UInt8
    getter owner : UInt32

    def initialize(@glyph : UInt32 = 0_u32, @fg : UInt32 = 0_u32, @bg : UInt32 = 0_u32,
                   @attrs : Attr = Attr::None, @fg_kind : Kind = Kind::Default,
                   @bg_kind : Kind = Kind::Default, @span : UInt8 = 1_u8, @dx : UInt8 = 0_u8,
                   @flags : UInt8 = 0_u8, @owner : UInt32 = 0_u32, @line : UInt32 = 0_u32,
                   @line_kind : Kind = Kind::Default, @link : UInt32 = 0_u32)
    end

    BLANK = new
    VOID  = new(glyph: UInt32::MAX)

    @[AlwaysInline]
    def cont? : Bool
      @flags & CONT != 0_u8
    end

    @[AlwaysInline]
    def broken? : Bool
      @flags & BROKEN != 0_u8
    end

    @[AlwaysInline]
    def exact? : Bool
      @flags & EXACT != 0_u8
    end

    @[AlwaysInline]
    def block? : Bool
      @span > 1_u8
    end

    @[AlwaysInline]
    def inked? : Bool
      @glyph != 0_u32 || cont?
    end

    @[AlwaysInline]
    def covered? : Bool
      @flags == CONT
    end

    @[AlwaysInline]
    def void? : Bool
      @glyph == UInt32::MAX
    end

    @[AlwaysInline]
    def blank? : Bool
      return false unless @link == 0_u32
      broken? || (!cont? && !block? && (@glyph == 0_u32 || @glyph == 0x20_u32) && (@attrs & LINES).none?)
    end

    @[AlwaysInline]
    def same?(other : Tile) : Bool
      @glyph == other.glyph && @fg == other.fg && @bg == other.bg && @attrs == other.attrs &&
        @fg_kind == other.fg_kind && @bg_kind == other.bg_kind && @span == other.span &&
        @dx == other.dx && @flags == other.flags &&
        @line == other.line && @line_kind == other.line_kind && @link == other.link
    end

    @[AlwaysInline]
    def styled?(other : Tile) : Bool
      @attrs == other.attrs && @fg_kind == other.fg_kind && @fg == other.fg &&
        @bg_kind == other.bg_kind && @bg == other.bg && @line_kind == other.line_kind &&
        @line == other.line && @link == other.link
    end

    def text : String
      Graphemes.text(@glyph)
    end

    def with_broken(broken : Bool) : Tile
      flags = broken ? @flags | BROKEN : @flags & ~BROKEN
      Tile.new(@glyph, @fg, @bg, @attrs, @fg_kind, @bg_kind, @span, @dx, flags, @owner,
        @line, @line_kind, @link)
    end
  end
end
