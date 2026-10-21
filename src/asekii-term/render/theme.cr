# src/asekii-term/render/theme.cr
require "./theme_enums"

module Asekii::Render
  class Theme
    getter name : String
    getter source : PaletteSource
    getter harmonious : Bool

    @fg : UInt32?
    @bg : UInt32?

    def initialize(@name : String, @source : PaletteSource, @colors : Array(UInt32),
                   @fg : UInt32?, @bg : UInt32?, @harmonious : Bool)
      @roles = {} of Int32 => RoleSpec
    end

    def self.rgb(value : Paint) : UInt32
      raise ArgumentError.new("expected RGB paint, got #{value.kind}") unless value.kind.rgb?
      value.value
    end

    def self.rgb(value : Int) : UInt32
      raise ArgumentError.new("color #{value} is outside 0x000000..0xFFFFFF") unless 0 <= value <= 0xFFFFFF
      value.to_u32
    end

    def self.rgb(value : String) : UInt32
      rgb, _ = ColorSpace.parse(value) || raise ArgumentError.new("invalid color #{value.inspect}")
      rgb
    end

    def role(name : String | Symbol, value : Blend) : Nil
      @roles[Roles.slot(name)] = value
    end

    def role(name : String | Symbol, value : Adjust) : Nil
      @roles[Roles.slot(name)] = value
    end

    def role(name : String | Symbol, value : Contrast) : Nil
      @roles[Roles.slot(name)] = value
    end

    def role(name : String | Symbol, value) : Nil
      @roles[Roles.slot(name)] = Paint.fg(value)
    end

    def mix(from, to, amount : Float64) : Blend
      Blend.new(Paint.fg(from), Paint.fg(to), amount.clamp(0.0, 1.0).to_f32)
    end

    def lighten(source, amount : Float64) : Adjust
      Adjust.lighten(source, amount)
    end

    def darken(source, amount : Float64) : Adjust
      Adjust.darken(source, amount)
    end

    def saturate(source, amount : Float64) : Adjust
      Adjust.saturate(source, amount)
    end

    def desaturate(source, amount : Float64) : Adjust
      Adjust.desaturate(source, amount)
    end

    def rotate(source, amount : Float64) : Adjust
      Adjust.rotate(source, amount)
    end

    def fade(source, amount : Float64) : Adjust
      Adjust.fade(source, amount)
    end

    def spec(slot : Int32) : RoleSpec
      @roles[slot]? || Roles.default(slot)
    end

    def palette(terminal : Palette, space : BlendSpace) : Palette
      case @source
      in PaletteSource::Terminal
        terminal.dup
      in PaletteSource::Generated
        Palette.generate(@colors, @fg || @colors[7], @bg || @colors[0], @harmonious, space)
      in PaletteSource::Explicit
        Palette.new(Slice(UInt32).new(Palette::SIZE) { |index| @colors[index] },
          @fg || @colors[7], @bg || @colors[0])
      end
    end
  end

  class Themes
    alias Survey = Hash(String, UInt32?)

    STEP       = 16.milliseconds
    RESET      = "\e]104\e\\\e]110\e\\\e]111\e\\"
    PUSH       = "\e]30001\e\\"
    POP        = "\e]30101\e\\"
    ROLE_DEPTH = 8

    ELEVATION = [
      Roles::Core::SurfaceSunken,
      Roles::Core::Surface,
      Roles::Core::SurfaceRaised,
      Roles::Core::SurfaceOverlay,
      Roles::Core::Hover,
    ]

    getter palette : Palette
    getter terminal : Palette
    getter queried : Palette
    getter current : Theme?
    getter mode : ThemeMode
    getter delivery : ThemeDelivery
    getter depth : ColorDepth
    getter? snap : Bool
    getter? indexed : Bool
    getter? known : Bool
    getter? querying : Bool

    property duration : Time::Span
    property easing : Easing
    property space : BlendSpace
    property contrast_model : ContrastModel
    property? extend_palette : Bool

    property output : Proc(Bytewire) = -> : Bytewire { raise "Themes#output is not wired" }
    property running : Proc(Bool) = -> { false }
    property querier : Proc(Proc(Survey?, Nil), Nil) = ->(done : Proc(Survey?, Nil)) { done.call(nil) }
    property ticker : Proc(Time::Span, Proc(Nil), Proc(Nil)) = ->(span : Time::Span, tick : Proc(Nil)) { -> { nil } }
    property now : Proc(Time::Instant) = -> { Time.instant }
    property on_theme : Proc(String?, Nil) = ->(name : String?) { nil }
    property on_palette : Proc(Nil) = -> { nil }

    @dark : String?
    @light : String?
    @system_dark : Bool?
    @animation : (-> Nil)?
    @quantized : Array(Paint)?

    def initialize
      @queried = Palette.stock
      @terminal = Palette.stock
      @palette = Palette.stock
      @themes = {} of String => Theme
      @roles = [] of Paint
      @current = nil
      @mode = ThemeMode::Auto
      @delivery = ThemeDelivery::Auto
      @depth = ColorDepth.detect
      @depth_fixed = false
      @snap = false
      @indexed = true
      @known = false
      @querying = false
      @pushed = false
      @stacked = false
      @query = 0
      @duration = 250.milliseconds
      @easing = Easing::InOut
      @space = BlendSpace::Oklab
      @contrast_model = ContrastModel::Wcag
      @extend_palette = true
      @dark = nil
      @light = nil
      @system_dark = nil
      @animation = nil
      @quantized = nil
      @roles = settle(nil, @palette)
    end

    def open : Nil
      refresh_palette
      show(@palette, @roles)
    end

    def close : Nil
      halt
      @query += 1
      @querying = false
      restore
    end

    def system_dark=(dark : Bool?) : Bool?
      @system_dark = dark
      follow(@duration) if @mode.auto?
      dark
    end

    def define(name : String | Symbol, *, base16 : Indexable? = nil, palette : Indexable? = nil,
               fg = nil, bg = nil, harmonious : Bool = false) : Theme
      source = PaletteSource::Terminal
      colors = [] of UInt32
      if entries = palette
        raise ArgumentError.new("palette needs #{Palette::SIZE} colors") unless entries.size == Palette::SIZE
        source = PaletteSource::Explicit
        colors = entries.map { |entry| Theme.rgb(entry) }.to_a
      elsif entries = base16
        raise ArgumentError.new("base16 needs 16 colors") unless entries.size == 16
        source = PaletteSource::Generated
        colors = entries.map { |entry| Theme.rgb(entry) }.to_a
      end
      theme = Theme.new(name.to_s, source, colors, fg.try { |value| Theme.rgb(value) },
        bg.try { |value| Theme.rgb(value) }, harmonious)
      replaced = @current.try(&.name) == theme.name
      @themes[theme.name] = theme
      if replaced
        @current = theme
        rebuild unless transitioning?
      end
      theme
    end

    def define(name : String | Symbol, *, base16 : Indexable? = nil, palette : Indexable? = nil,
               fg = nil, bg = nil, harmonious : Bool = false, & : Theme ->) : Theme
      theme = define(name, base16: base16, palette: palette, fg: fg, bg: bg, harmonious: harmonious)
      yield theme
      rebuild if @current.same?(theme) && !transitioning?
      theme
    end

    def [](name : String | Symbol) : Theme
      @themes[name.to_s]? || raise ArgumentError.new("unknown theme #{name.to_s.inspect}")
    end

    def pair(dark : String | Symbol, light : String | Symbol, mode : ThemeMode = ThemeMode::Auto) : Nil
      @dark = self[dark].name
      @light = self[light].name
      @mode = mode
      follow(Time::Span.zero)
    end

    def mode=(mode : ThemeMode) : ThemeMode
      @mode = mode
      follow(@duration)
      mode
    end

    def toggle : Nil
      self.mode = dark? ? ThemeMode::Light : ThemeMode::Dark
    end

    def dark? : Bool
      case @mode
      in ThemeMode::Dark  then true
      in ThemeMode::Light then false
      in ThemeMode::Auto
        system = @system_dark
        system.nil? ? !@queried.light? : system
      end
    end

    def use(name : String | Symbol | Nil) : Nil
      go(name.try { |key| self[key] }, Time::Span.zero, @easing)
    end

    def transition(to : String | Symbol | Nil, duration : Time::Span = @duration,
                   easing : Easing = @easing) : Nil
      go(to.try { |key| self[key] }, duration, easing)
    end

    def transitioning? : Bool
      !@animation.nil?
    end

    def delivery=(delivery : ThemeDelivery) : ThemeDelivery
      @delivery = delivery
      restore
      rebuild unless transitioning?
      delivery
    end

    def depth=(depth : ColorDepth) : ColorDepth
      @depth_fixed = true
      apply_depth(depth)
    end

    def recognize(name : String) : Nil
      return if @depth_fixed
      found = ColorDepth.recognize(name) || return
      apply_depth(found) if found > @depth
    end

    private def apply_depth(depth : ColorDepth) : ColorDepth
      @depth = depth
      @quantized = depth.true_color? ? nil : quantize(@roles, @palette)
      on_palette.call
      depth
    end

    def snap=(snap : Bool) : Bool
      @snap = snap
      on_palette.call
      snap
    end

    def themed_palette? : Bool
      @queried.themed?
    end

    def role(name : String | Symbol) : Paint
      Paint.role(name)
    end

    @[AlwaysInline]
    def resolve(slot : Int32) : Paint
      @roles = settle(@current, @palette) if slot >= @roles.size
      if quantized = @quantized
        return quantized.unsafe_fetch(slot) if slot < quantized.size
      end
      @roles.unsafe_fetch(slot)
    end

    def refresh_palette : Nil
      return unless running.call
      restore
      @querying = true
      serial = (@query += 1)
      querier.call(->(found : Survey?) { learn(found) if serial == @query })
    end

    def learn(found : Survey?) : Nil
      return unless @querying
      if found
        Palette::SIZE.times do |index|
          color = found[index.to_s]? || next
          @queried[index] = Theme.rgb(color)
          @known = true
        end
        found["foreground"]?.try { |color| @queried.fg = Theme.rgb(color) }
        found["background"]?.try { |color| @queried.bg = Theme.rgb(color) }
      end
      finish_query
    end

    private def finish_query : Nil
      return unless @querying
      @querying = false
      @terminal.copy(@queried)
      return if transitioning?
      wanted = @mode.auto? ? (dark? ? @dark : @light) : nil
      if wanted && wanted != @current.try(&.name)
        follow(Time::Span.zero)
      else
        rebuild
      end
    end

    private def rebuild : Nil
      goal = target(@current)
      show(goal, settle(@current, goal))
    end

    private def follow(duration : Time::Span) : Nil
      name = (dark? ? @dark : @light) || return
      go(@themes[name]?, duration, @easing)
    end

    private def pushing? : Bool
      return false if @querying || !running.call
      @delivery.push? || (@delivery.auto? && @known)
    end

    private def target(theme : Theme?) : Palette
      if theme.nil? || theme.source.terminal?
        if @extend_palette && @known && !@delivery.local? && !@queried.themed?
          Palette.generate(@queried.colors[0, 16], @queried.fg, @queried.bg, space: @space)
        else
          @queried.dup
        end
      else
        theme.palette(@queried, @space)
      end
    end

    private def go(theme : Theme?, duration : Time::Span, easing : Easing) : Nil
      halt
      before = @current
      goal = target(theme)
      roles = settle(theme, goal)
      @current = theme
      native = (before.nil? || before.source.terminal?) && (theme.nil? || theme.source.terminal?)
      reduced = !pushing? && !@depth.true_color?
      if duration <= Time::Span.zero || !running.call || native || reduced
        show(goal, roles)
        on_theme.call(theme.try(&.name))
        return
      end
      origin = @palette.dup
      started = now.call
      shades = @roles.map { |paint| Pile.rgb(paint, origin) }
      paints = @roles.dup
      @animation = ticker.call(STEP, -> {
        amount = ((now.call - started) / duration).clamp(0.0, 1.0)
        if amount >= 1.0
          halt
          show(goal, roles)
          on_theme.call(theme.try(&.name))
        else
          eased = easing.apply(amount).to_f32
          show(Palette.mix(origin, goal, eased, @space), blend(paints, shades, roles, goal, eased))
        end
      })
    end

    private def halt : Nil
      @animation.try(&.call)
      @animation = nil
    end

    private def blend(paints : Array(Paint), shades : Array(UInt32), roles : Array(Paint),
                      goal : Palette, amount : Float32) : Array(Paint)
      Array(Paint).new(roles.size) do |slot|
        final = roles[slot]
        start = paints[slot]? || final
        if start == final && !final.kind.rgb?
          final
        else
          Paint.rgb(ColorSpace.mix(shades[slot]? || Pile.rgb(final, goal), Pile.rgb(final, goal), amount, @space))
        end
      end
    end

    private def settle(theme : Theme?, palette : Palette) : Array(Paint)
      Array(Paint).new(Roles.count) { |slot| flatten(theme, slot, palette, 0) }
    end

    private def flatten(theme : Theme?, slot : Int32, palette : Palette, depth : Int32) : Paint
      spec = theme ? theme.spec(slot) : Roles.default(slot)
      spec.resolve(self, theme, palette, depth)
    end

    def resolve_paint(paint : Paint, theme : Theme?, palette : Palette, depth : Int32) : Paint
      return paint unless paint.role?
      return Paint.foreground if depth >= ROLE_DEPTH
      flatten(theme, paint.value.to_i32!, palette, depth + 1)
    end

    def resolve_spec(spec : RoleSpec, palette : Palette, depth : Int32 = 0) : Paint
      spec.resolve(self, @current, palette, depth)
    end

    def contrast(a : UInt32, b : UInt32) : Float32
      @contrast_model.apca? ? ColorSpace.apca(a, b) : ColorSpace.contrast(a, b)
    end

    def contrast_target(ratio : Float32) : Float32
      @contrast_model.apca? ? ColorSpace.wcag_to_apca(ratio) : ratio
    end

    private def show(palette : Palette, roles : Array(Paint)) : Nil
      @palette = palette
      @roles = roles
      if pushing?
        push(palette)
        @indexed = true
      else
        @indexed = palette.same?(@terminal)
      end
      @quantized = @depth.true_color? ? nil : quantize(roles, palette)
      on_palette.call
    end

    private def quantize(roles : Array(Paint), palette : Palette) : Array(Paint)
      table = Array(Paint).new(roles.size, Paint.foreground)
      @depth.ansi16? ? quantize_ansi16(roles, palette, table) : quantize_indexed(roles, palette, table)
      table
    end

    private def quantize_indexed(roles : Array(Paint), palette : Palette, table : Array(Paint)) : Nil
      roles.size.times do |slot|
        rgb = Pile.rgb(roles.unsafe_fetch(slot), palette)
        table[slot] = Paint.index(palette.nearest_chroma(rgb).to_u32)
      end
      entries = ELEVATION.map do |role|
        rgb = Pile.rgb(roles.unsafe_fetch(role.value), palette)
        {role, ColorSpace.oklab(rgb)[0]}
      end.sort_by!(&.[1])
      prev = -1
      entries.each do |(role, _)|
        slot = role.value
        index = table[slot].value.to_i
        index = prev + 1 if index <= prev
        index = Palette::SIZE - 1 if index >= Palette::SIZE
        table[slot] = Paint.index(index)
        prev = index
      end
    end

    private def quantize_ansi16(roles : Array(Paint), palette : Palette, table : Array(Paint)) : Nil
      bg = @terminal.nearest(palette.bg, Palette::CUBE).to_i
      raised = bg == 0 ? 8 : 0
      roles.size.times do |slot|
        rgb = Pile.rgb(roles.unsafe_fetch(slot), palette)
        table[slot] = Paint.index(@terminal.nearest(rgb, Palette::CUBE).to_u32)
      end
      table[Roles::Core::Surface.value] = Paint.background
      table[Roles::Core::SurfaceRaised.value] = Paint.index(raised)
      table[Roles::Core::SurfaceOverlay.value] = Paint.index(raised)
      table[Roles::Core::Hover.value] = Paint.index(8)
      table[Roles::Core::Selection.value] = Paint.index(4)
      table[Roles::Core::OnAccent.value] = Paint.index(palette.light? ? 0 : 15)
      table[Roles::Core::TextMuted.value] = Paint.index(8)
      table[Roles::Core::Border.value] = Paint.index(8)
    end

    private def push(palette : Palette) : Nil
      return if palette.same?(@terminal)
      target = output.call
      unless @pushed
        @pushed = true
        @stacked = @known
        target.str(PUSH) if @stacked
      end
      Palette::SIZE.times do |index|
        next if palette[index] == @terminal[index]
        target.osc(4).int(index).semi.color_rgb(palette[index]).st
      end
      target.osc(10).color_rgb(palette.fg).st unless palette.fg == @terminal.fg
      target.osc(11).color_rgb(palette.bg).st unless palette.bg == @terminal.bg
      @terminal.copy(palette)
    end

    private def restore : Nil
      return unless @pushed
      output.call.str(@stacked ? POP : RESET)
      @pushed = false
      @stacked = false
      @terminal.copy(@queried)
    end
  end
end
