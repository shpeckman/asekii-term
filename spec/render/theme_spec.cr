# spec/render/theme_spec.cr
require "./support"

private def themed(stage : Engine) : Nil
  stage.themes.define(:dark, base16: DARK16, fg: 0xcdd6f4, bg: 0x1e1e2e) do |theme|
    theme.role :accent, 4
    theme.role :text_muted, theme.mix(:text, :surface, 0.5)
    theme.role :sidebar, :surface_raised
  end
  stage.themes.define(:light, base16: LIGHT16, fg: 0x4c4f69, bg: 0xeff1f5)
end

private def watching(themes : Asekii::Render::Themes) : Array(String?)
  names = [] of String?
  themes.on_theme = ->(name : String?) { names << name; nil }
  names
end

private def ticking(themes : Asekii::Render::Themes) : Array(Proc(Nil))
  ticks = [] of Proc(Nil)
  themes.running = -> { true }
  themes.ticker = ->(span : Time::Span, tick : Proc(Nil)) {
    ticks << tick
    -> { ticks.delete(tick); nil }
  }
  ticks
end

describe Asekii::Render::Themes do
  it "detects the color depth from the environment" do
    Asekii::Render::ColorDepth.detect("truecolor", "xterm").should eq(Asekii::Render::ColorDepth::TrueColor)
    Asekii::Render::ColorDepth.detect(nil, "xterm-kitty").should eq(Asekii::Render::ColorDepth::TrueColor)
    Asekii::Render::ColorDepth.detect(nil, "xterm-256color").should eq(Asekii::Render::ColorDepth::Indexed256)
    Asekii::Render::ColorDepth.detect(nil, "linux").should eq(Asekii::Render::ColorDepth::Ansi16)
    Asekii::Render::ColorDepth.detect(nil, nil).should eq(Asekii::Render::ColorDepth::Indexed256)
  end

  it "eases between zero and one" do
    Asekii::Render::Easing.each do |easing|
      easing.apply(0.0).should be_close(0.0, 1e-9)
      easing.apply(1.0).should be_close(1.0, 1e-9)
    end
    Asekii::Render::Easing::InOut.apply(0.5).should be_close(0.5, 1e-9)
  end

  it "resolves the core roles against the terminal palette by default" do
    stage = Engine.new
    stage.themes.resolve(Asekii::Render::Roles::Core::Surface.value).should eq(Asekii::Render::Paint.background)
    stage.themes.resolve(Asekii::Render::Roles::Core::Text.value).should eq(Asekii::Render::Paint.foreground)
    stage.themes.resolve(Asekii::Render::Roles::Core::Accent.value).should eq(Asekii::Render::Paint.index(4))
    stage.themes.resolve(Asekii::Render::Roles::Core::Border.value).kind.should eq(Asekii::Render::Paint::Kind::RGB)
    stage.themes.resolve(Asekii::Render::Roles.slot(:never_defined)).should eq(Asekii::Render::Paint.foreground)
    stage.themes.role(:accent).should eq(Asekii::Render::Paint.role(Asekii::Render::Roles::Core::Accent.value))
    stage.themes.indexed?.should be_true
    stage.themes.themed_palette?.should be_false
  end

  it "resolves the elevation and interaction roles from the core roles" do
    stage = Engine.new
    stage.themes.resolve(Asekii::Render::Roles::Core::Focus.value).should eq(stage.themes.resolve(Asekii::Render::Roles::Core::Accent.value))
    on_accent = stage.themes.resolve(Asekii::Render::Roles::Core::OnAccent.value)
    on_accent.kind.should eq(Asekii::Render::Paint::Kind::RGB)
    accent = Asekii::Render::Pile.rgb(Asekii::Render::Paint.index(4), stage.themes.palette)
    Asekii::Render::ColorSpace.contrast(on_accent.value, accent).should be >= 4.5
    stage.themes.resolve(Asekii::Render::Roles::Core::Info.value).should eq(Asekii::Render::Paint.index(6))
    themed(stage)
    stage.themes.use(:dark)
    light = ->(role : Asekii::Render::Roles::Core) do
      paint = stage.themes.resolve(role.value)
      paint.kind.should eq(Asekii::Render::Paint::Kind::RGB)
      Asekii::Render::ColorSpace.lightness(paint.value)
    end
    surface = Asekii::Render::ColorSpace.lightness(0x1e1e2e_u32)
    light.call(Asekii::Render::Roles::Core::Shadow).should be < light.call(Asekii::Render::Roles::Core::SurfaceSunken)
    light.call(Asekii::Render::Roles::Core::SurfaceSunken).should be < surface
    surface.should be < light.call(Asekii::Render::Roles::Core::SurfaceRaised)
    light.call(Asekii::Render::Roles::Core::SurfaceRaised).should be < light.call(Asekii::Render::Roles::Core::SurfaceOverlay)
    light.call(Asekii::Render::Roles::Core::SurfaceOverlay).should be < light.call(Asekii::Render::Roles::Core::Hover)
  end

  it "generates a palette for a base16 theme and resolves its roles" do
    stage = Engine.new
    watch = watching(stage.themes)
    themed(stage)
    stage.themes.use(:dark)
    watch.should eq(["dark"])
    stage.themes.current.not_nil!.name.should eq("dark")
    stage.themes.palette.bg.should eq(0x1e1e2e_u32)
    stage.themes.palette[4].should eq(0x89b4fa_u32)
    stage.themes.palette.themed?.should be_true
    stage.themes.indexed?.should be_false
    muted = stage.themes.resolve(Asekii::Render::Roles::Core::TextMuted.value)
    muted.should eq(Asekii::Render::Paint.rgb(Asekii::Render::ColorSpace.mix(0xcdd6f4_u32, 0x1e1e2e_u32, 0.5_f32, Asekii::Render::BlendSpace::Oklab)))
    stage.themes.resolve(Asekii::Render::Roles.slot(:sidebar)).should eq(stage.themes.resolve(Asekii::Render::Roles::Core::SurfaceRaised.value))
    stage.themes.use(nil)
    watch.should eq(["dark", nil])
    stage.themes.palette.same?(Asekii::Render::Palette.stock).should be_true
    stage.themes.indexed?.should be_true
  end

  it "accepts an explicit palette and rejects malformed input" do
    stage = Engine.new
    table = Array.new(256) { |index| index * 0x010101 }
    stage.themes.define("flat", palette: table, fg: "#ffffff", bg: Asekii::Render::Paint.rgb(0_u8, 0_u8, 0_u8))
    stage.themes.use("flat")
    stage.themes.palette[200].should eq(0xc8c8c8_u32)
    stage.themes.palette.fg.should eq(0xffffff_u32)
    expect_raises(ArgumentError) { stage.themes.define(:bad, base16: [1, 2, 3]) }
    expect_raises(ArgumentError) { stage.themes.define(:bad, palette: [1, 2, 3]) }
    expect_raises(ArgumentError) { stage.themes.define(:bad, base16: DARK16, fg: "nope") }
    expect_raises(ArgumentError) { stage.themes.use(:missing) }
  end

  it "paints cells from a local theme as direct colors" do
    stage = Engine.new(4, 1)
    themed(stage)
    plane = stage.plane(4, 1)
    plane.put(0, 0, "a", fg: :accent, bg: :surface)
    plane.put(1, 0, "b", fg: 1)
    stage.frame
    stage.at(0, 0).fg_kind.should eq(Asekii::Render::Tile::Kind::Index)
    stage.at(0, 0).fg.should eq(4_u32)
    stage.at(0, 0).bg_kind.should eq(Asekii::Render::Tile::Kind::Default)
    stage.themes.use(:dark)
    wire = stage.frame
    stage.at(0, 0).fg_kind.should eq(Asekii::Render::Tile::Kind::RGB)
    stage.at(0, 0).fg.should eq(0x89b4fa_u32)
    stage.at(0, 0).bg.should eq(0x1e1e2e_u32)
    stage.at(1, 0).fg.should eq(0xf38ba8_u32)
    stage.at(3, 0).bg.should eq(0x1e1e2e_u32)
    wire.should contain("48;2;30;30;46")
  end

  it "re-resolves the current theme when it is defined again" do
    stage = Engine.new
    themed(stage)
    stage.themes.use(:dark)
    stage.themes.define(:dark, base16: DARK16, fg: 0xffffff, bg: 0x000000)
    stage.themes.palette.bg.should eq(0x000000_u32)
  end

  it "switches between a dark and a light theme" do
    stage = Engine.new
    watch = watching(stage.themes)
    themed(stage)
    stage.themes.pair(dark: :dark, light: :light)
    stage.themes.current.not_nil!.name.should eq("dark")
    stage.themes.dark?.should be_true
    stage.themes.system_dark = false
    stage.themes.current.not_nil!.name.should eq("light")
    stage.themes.palette.bg.should eq(0xeff1f5_u32)
    stage.themes.toggle
    stage.themes.mode.should eq(Asekii::Render::ThemeMode::Dark)
    stage.themes.current.not_nil!.name.should eq("dark")
    stage.themes.system_dark = false
    stage.themes.current.not_nil!.name.should eq("dark")
    stage.themes.mode = Asekii::Render::ThemeMode::Auto
    stage.themes.current.not_nil!.name.should eq("light")
    stage.themes.toggle
    stage.themes.current.not_nil!.name.should eq("dark")
    watch.should eq(["dark", "light", "dark", "light", "dark"])
  end

  it "resolves each adjust operation" do
    stage = Engine.new
    themed(stage)
    stage.themes.use(:dark)
    cs     = Asekii::Render::ColorSpace
    accent = stage.themes.resolve(Asekii::Render::Roles::Core::Accent.value)
    rgb = Asekii::Render::Pile.rgb(accent, stage.themes.palette)
    l, c, h = cs.oklch(rgb)

    light = stage.themes.resolve_spec(Asekii::Render::Adjust.lighten(:accent, 0.1), stage.themes.palette)
    cs.oklch(light.value)[0].should be > l

    dark = stage.themes.resolve_spec(Asekii::Render::Adjust.darken(:accent, 0.1), stage.themes.palette)
    cs.oklch(dark.value)[0].should be < l

    loud = stage.themes.resolve_spec(Asekii::Render::Adjust.saturate(:accent, 0.3), stage.themes.palette)
    cs.oklch(loud.value)[1].should be > c

    muted = stage.themes.resolve_spec(Asekii::Render::Adjust.desaturate(:accent, 0.5), stage.themes.palette)
    cs.oklch(muted.value)[1].should be < c

    faded = stage.themes.resolve_spec(Asekii::Render::Adjust.fade(:accent, 0.5), stage.themes.palette)
    faded.value.should eq(rgb)
    faded.alpha.should eq(128_u8)
  end

  it "resolves adjustments of adjustments" do
    stage = Engine.new
    stage.themes.define(:nested, base16: DARK16, fg: 0xcdd6f4, bg: 0x1e1e2e) do |theme|
      theme.role :base, theme.lighten(:accent, 0.05)
      theme.role :top, theme.darken(:base, 0.05)
    end
    stage.themes.use(:nested)
    base = stage.themes.resolve(Asekii::Render::Roles.slot(:base))
    top  = stage.themes.resolve(Asekii::Render::Roles.slot(:top))
    base.kind.should eq(Asekii::Render::Paint::Kind::RGB)
    top.kind.should eq(Asekii::Render::Paint::Kind::RGB)
    Asekii::Render::ColorSpace.oklch(top.value)[0].should be < Asekii::Render::ColorSpace.oklch(base.value)[0]
  end

  it "resolves a role cycle to the foreground" do
    stage = Engine.new
    stage.themes.define(:cycle) do |theme|
      theme.role :x, :y
      theme.role :y, :x
    end
    stage.themes.use(:cycle)
    stage.themes.resolve(Asekii::Render::Roles.slot(:x)).should eq(Asekii::Render::Paint.foreground)
  end

  it "meets its contrast targets across palettes" do
    cs = Asekii::Render::ColorSpace
    stage = Engine.new
    stage.themes.define(:solarized, base16: SOLARIZED_DARK16, fg: 0x93a1a1, bg: 0x002b36)
    stage.themes.define(:light, base16: LIGHT16, fg: 0x4c4f69, bg: 0xeff1f5)
    stage.themes.define(:base16, base16: DARK16, fg: 0xcdd6f4, bg: 0x1e1e2e)

    [nil, :solarized, :light, :base16].each do |name|
      stage.themes.use(name)
      palette = stage.themes.palette
      surface = palette.bg
      text    = palette.fg
      accent  = Asekii::Render::Pile.rgb(stage.themes.resolve(Asekii::Render::Roles::Core::Accent.value), palette)

      on_accent = Asekii::Render::Pile.rgb(stage.themes.resolve(Asekii::Render::Roles::Core::OnAccent.value), palette)
      cs.contrast(on_accent, accent).should be >= 3.0

      muted = Asekii::Render::Pile.rgb(stage.themes.resolve(Asekii::Render::Roles::Core::TextMuted.value), palette)
      cs.contrast(muted, surface).should be >= 4.5

      selection = Asekii::Render::Pile.rgb(stage.themes.resolve(Asekii::Render::Roles::Core::Selection.value), palette)
      cs.contrast(text, selection).should be >= 4.5

      border = Asekii::Render::Pile.rgb(stage.themes.resolve(Asekii::Render::Roles::Core::Border.value), palette)
      cs.contrast(border, surface).should be >= 1.5
    end
  end

  it "converts contrast targets to the active model" do
    stage = Engine.new
    stage.themes.contrast_target(4.5).should be_close(4.5, 0.01)
    stage.themes.contrast_model = Asekii::Render::ContrastModel::Apca
    stage.themes.contrast_target(4.5).should be_close(75.0, 0.5)
  end

  it "animates a transition and finishes on the target palette" do
    stage  = Engine.new
    themes = stage.themes
    watch  = watching(themes)
    ticks  = ticking(themes)
    themes.depth = Asekii::Render::ColorDepth::TrueColor
    themes.define(:dark, base16: DARK16, fg: 0xcdd6f4, bg: 0x1e1e2e)
    themes.define(:light, base16: LIGHT16, fg: 0x4c4f69, bg: 0xeff1f5)
    themes.use(:dark)
    middle = [] of UInt32
    themes.transition(to: :light, duration: 120.milliseconds)
    ticks.size.should eq(1)
    sleep 60.milliseconds
    ticks.last.call
    middle << themes.palette.bg
    sleep 80.milliseconds
    ticks.last.call
    watch.should eq(["dark", "light"])
    themes.transitioning?.should be_false
    themes.palette.bg.should eq(0xeff1f5_u32)
    middle.size.should eq(1)
    middle[0].should_not eq(0x1e1e2e_u32)
    middle[0].should_not eq(0xeff1f5_u32)
  end

  it "collapses a transition when it cannot animate" do
    stage  = Engine.new
    themes = stage.themes
    watch  = watching(themes)
    themes.depth = Asekii::Render::ColorDepth::Indexed256
    themes.delivery = Asekii::Render::ThemeDelivery::Local
    themes.define(:dark, base16: DARK16, fg: 0xcdd6f4, bg: 0x1e1e2e)
    themes.define(:light, base16: LIGHT16, fg: 0x4c4f69, bg: 0xeff1f5)
    themes.use(:dark)
    themes.transition(to: :light, duration: 10.seconds)
    themes.transitioning?.should be_false
    themes.palette.bg.should eq(0xeff1f5_u32)
    watch.should eq(["dark", "light"])
  end

  it "follows the system scheme with the default duration while running" do
    stage  = Engine.new
    themes = stage.themes
    watch  = watching(themes)
    ticks  = ticking(themes)
    themes.depth = Asekii::Render::ColorDepth::TrueColor
    themes.duration = 40.milliseconds
    themes.define(:dark, base16: DARK16, fg: 0xcdd6f4, bg: 0x1e1e2e)
    themes.define(:light, base16: LIGHT16, fg: 0x4c4f69, bg: 0xeff1f5)
    themes.pair(dark: :dark, light: :light)
    themes.system_dark = false
    ticks.size.should eq(1)
    sleep 60.milliseconds
    ticks.last.call
    themes.current.not_nil!.name.should eq("light")
    themes.palette.bg.should eq(0xeff1f5_u32)
  end

  it "raises the colour depth for a terminal it recognizes, unless the app chose one" do
    Asekii::Render::ColorDepth.recognize("WezTerm").should eq(Asekii::Render::ColorDepth::TrueColor)
    Asekii::Render::ColorDepth.recognize("vte").should eq(Asekii::Render::ColorDepth::TrueColor)
    Asekii::Render::ColorDepth.recognize("tmux").should be_nil
    saved = {ENV["COLORTERM"]?, ENV["TERM"]?}
    begin
      ENV.delete("COLORTERM")
      ENV["TERM"] = "xterm-256color"
      themes = Asekii::Render::Themes.new
      themes.depth.should eq(Asekii::Render::ColorDepth::Indexed256)
      themes.recognize("tmux")
      themes.depth.should eq(Asekii::Render::ColorDepth::Indexed256)
      themes.recognize("kitty")
      themes.depth.should eq(Asekii::Render::ColorDepth::TrueColor)
      chosen = Asekii::Render::Themes.new
      chosen.depth = Asekii::Render::ColorDepth::Ansi16
      chosen.recognize("kitty")
      chosen.depth.should eq(Asekii::Render::ColorDepth::Ansi16)
    ensure
      saved[0] ? (ENV["COLORTERM"] = saved[0]) : ENV.delete("COLORTERM")
      saved[1] ? (ENV["TERM"] = saved[1]) : ENV.delete("TERM")
    end
  end
end
