# src/asekii-term/render/role_spec.cr
module Asekii::Render
  struct Blend
    getter from : Paint
    getter to : Paint
    getter amount : Float32

    def initialize(@from : Paint, @to : Paint, @amount : Float32)
    end

    def_equals_and_hash from, to, amount

    def resolve(themes : Themes, theme : Theme?, palette : Palette, depth : Int32) : Paint
      from = Pile.rgb(themes.resolve_paint(self.from, theme, palette, depth), palette)
      to = Pile.rgb(themes.resolve_paint(self.to, theme, palette, depth), palette)
      Paint.rgb(ColorSpace.mix(from, to, amount, themes.space))
    end
  end

  struct Adjust
    enum Op
      Lighten
      Darken
      Saturate
      Desaturate
      Rotate
      Fade
    end

    getter source : Paint
    getter op : Op
    getter amount : Float32

    def initialize(@source : Paint, @op : Op, @amount : Float32)
    end

    def_equals_and_hash source, op, amount

    def self.lighten(source, amount : Float64) : Adjust
      new(Paint.fg(source), Op::Lighten, amount.to_f32)
    end

    def self.darken(source, amount : Float64) : Adjust
      new(Paint.fg(source), Op::Darken, amount.to_f32)
    end

    def self.saturate(source, amount : Float64) : Adjust
      new(Paint.fg(source), Op::Saturate, amount.to_f32)
    end

    def self.desaturate(source, amount : Float64) : Adjust
      new(Paint.fg(source), Op::Desaturate, amount.to_f32)
    end

    def self.rotate(source, amount : Float64) : Adjust
      new(Paint.fg(source), Op::Rotate, amount.to_f32)
    end

    def self.fade(source, amount : Float64) : Adjust
      new(Paint.fg(source), Op::Fade, amount.to_f32)
    end

    def resolve(themes : Themes, theme : Theme?, palette : Palette, depth : Int32) : Paint
      source = themes.resolve_paint(self.source, theme, palette, depth)
      rgb = Pile.rgb(source, palette)
      if op.fade?
        alpha = (source.alpha.to_f32 * amount).round.to_i.clamp(0, 255).to_u8
        return Paint.rgb(rgb, alpha)
      end
      l, c, h = ColorSpace.oklch(rgb)
      case op
      in Op::Lighten    then l += amount
      in Op::Darken     then l -= amount
      in Op::Saturate   then c *= 1.0_f32 + amount
      in Op::Desaturate then c *= 1.0_f32 - amount
      in Op::Rotate     then h += amount
      in Op::Fade       then nil
      end
      Paint.rgb(ColorSpace.from_oklch({l, Math.max(c, 0.0_f32), h}))
    end
  end

  struct Contrast
    getter against : Paint
    getter target : Float32
    getter from : Paint
    getter to : Paint
    getter amount : Float32
    getter picks : Array(Paint)
    getter floor : Bool

    def initialize(@against : Paint, @target : Float32, @from : Paint, @to : Paint,
                   @amount : Float32, @picks : Array(Paint), @floor : Bool)
    end

    def_equals_and_hash against, target, from, to, amount, picks, floor

    def self.best(against, target : Float64, picks : Array(Paint)) : Contrast
      new(Paint.fg(against), target.to_f32, Paint.foreground, Paint.foreground,
        0.0_f32, picks, false)
    end

    def self.mix(against, target : Float64, from, to, amount : Float64, floor : Bool = false) : Contrast
      new(Paint.fg(against), target.to_f32, Paint.fg(from), Paint.fg(to),
        amount.clamp(0.0, 1.0).to_f32, [] of Paint, floor)
    end

    def resolve(themes : Themes, theme : Theme?, palette : Palette, depth : Int32) : Paint
      goal = themes.contrast_target(target)
      against = Pile.rgb(themes.resolve_paint(self.against, theme, palette, depth), palette)
      unless picks.empty?
        best = picks[0]
        best_ratio = -Float32::MAX
        picks.each do |pick|
          rgb = Pile.rgb(themes.resolve_paint(pick, theme, palette, depth), palette)
          ratio = themes.contrast(rgb, against)
          return Paint.rgb(rgb) if ratio >= goal
          if ratio > best_ratio
            best_ratio = ratio
            best = pick
          end
        end
        return Paint.rgb(Pile.rgb(themes.resolve_paint(best, theme, palette, depth), palette))
      end
      from = Pile.rgb(themes.resolve_paint(self.from, theme, palette, depth), palette)
      to = Pile.rgb(themes.resolve_paint(self.to, theme, palette, depth), palette)
      if floor
        return Paint.rgb(to) unless themes.contrast(to, against) >= goal
        Paint.rgb(ColorSpace.mix(from, to, floor_amount(themes, from, to, against, goal), themes.space))
      else
        return endpoint(themes, from, to, against) unless themes.contrast(from, against) >= goal
        Paint.rgb(ColorSpace.mix(from, to, cap_amount(themes, from, to, against, goal), themes.space))
      end
    end

    private def cap_amount(themes : Themes, from : UInt32, to : UInt32, against : UInt32, goal : Float32) : Float32
      if themes.contrast(ColorSpace.mix(from, to, amount, themes.space), against) >= goal
        return amount
      end
      lo = 0.0_f32
      hi = amount
      16.times do
        mid = (lo + hi) / 2.0_f32
        if themes.contrast(ColorSpace.mix(from, to, mid, themes.space), against) >= goal
          lo = mid
        else
          hi = mid
        end
      end
      lo
    end

    private def floor_amount(themes : Themes, from : UInt32, to : UInt32, against : UInt32, goal : Float32) : Float32
      if themes.contrast(ColorSpace.mix(from, to, amount, themes.space), against) >= goal
        return amount
      end
      lo = amount
      hi = 1.0_f32
      16.times do
        mid = (lo + hi) / 2.0_f32
        if themes.contrast(ColorSpace.mix(from, to, mid, themes.space), against) >= goal
          hi = mid
        else
          lo = mid
        end
      end
      hi
    end

    private def endpoint(themes : Themes, from : UInt32, to : UInt32, against : UInt32) : Paint
      from_ratio = themes.contrast(from, against)
      to_ratio = themes.contrast(to, against)
      Paint.rgb(from_ratio >= to_ratio ? from : to)
    end
  end

  struct Layered
    getter under : Paint
    getter over : Paint

    def initialize(@under : Paint, @over : Paint)
    end

    def_equals_and_hash under, over

    def resolve(themes : Themes, theme : Theme?, palette : Palette, depth : Int32) : Paint
      below = ground(themes, theme, palette, depth, @under)
      above = ground(themes, theme, palette, depth, @over)
      Pile.fuse(below, above, palette, themes.space)
    end

    private def ground(themes : Themes, theme : Theme?, palette : Palette, depth : Int32, paint : Paint) : Paint
      if paint.role?
        found = themes.resolve_paint(paint, theme, palette, depth)
        Paint.new(found.kind, found.value, paint.alpha)
      elsif paint.spec?
        found = themes.resolve_spec(Specs[paint.value], palette, depth)
        Paint.new(found.kind, found.value, paint.alpha)
      else
        paint
      end
    end
  end

  alias RoleSpec = Paint | Blend | Adjust | Contrast | Layered

  module Specs
    extend self

    @@pool = Interner(RoleSpec).new

    def intern(spec : RoleSpec) : UInt32
      @@pool.intern(spec).to_u32
    end

    def [](id : UInt32) : RoleSpec
      @@pool[id.to_i32]
    end
  end

  module Roles
    DEFAULTS = [
      Paint.background,
      Paint.foreground,
      Blend.new(Paint.background, Paint.rgb(0xFFFFFF_u32), 0.08_f32),
      Contrast.mix(Paint.role(Core::Surface.value), 4.5, Paint.foreground, Paint.background, 1.0),
      Contrast.mix(Paint.role(Core::Surface.value), 1.5, Paint.background, Paint.foreground, 0.25, floor: true),
      Paint.index(4),
      Contrast.mix(Paint.role(Core::Text.value), 4.5, Paint.background, Paint.role(Core::Accent.value), 0.35),
      Paint.index(1),
      Paint.index(3),
      Paint.index(2),
      Blend.new(Paint.background, Paint.rgb(0x000000_u32), 0.12_f32),
      Blend.new(Paint.background, Paint.rgb(0xFFFFFF_u32), 0.12_f32),
      Blend.new(Paint.background, Paint.rgb(0xFFFFFF_u32), 0.16_f32),
      Paint.role(Core::Accent.value),
      Contrast.best(Paint.role(Core::Accent.value), 3.0, [Paint.background, Paint.foreground]),
      Paint.index(6),
      Blend.new(Paint.background, Paint.rgb(0x000000_u32), 0.6_f32),
    ] of RoleSpec

    def default(slot : Int32) : RoleSpec
      DEFAULTS[slot]? || Paint.foreground
    end
  end
end
