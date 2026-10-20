# src/asekii-term/render/theme_enums.cr
module Asekii::Render
  enum ColorDepth
    Ansi16
    Indexed256
    TrueColor

    def self.detect(colorterm : String? = ENV["COLORTERM"]?, term : String? = ENV["TERM"]?) : ColorDepth
      mode = (colorterm || "").downcase
      name = (term || "").downcase
      return TrueColor if DEPTH_MODES.includes?(mode)
      DEPTH_TERMS.each do |marker, depth|
        return depth if name.includes?(marker)
      end
      Indexed256
    end

    def self.recognize(name : String) : ColorDepth?
      lowered = name.downcase
      DEPTH_TERMS.each do |marker, depth|
        return depth if lowered.includes?(marker)
      end
    end
  end

  DEPTH_MODES = {"truecolor", "24bit"}

  DEPTH_TERMS = {
    {"kitty",     ColorDepth::TrueColor},
    {"ghostty",   ColorDepth::TrueColor},
    {"wezterm",   ColorDepth::TrueColor},
    {"alacritty", ColorDepth::TrueColor},
    {"foot",      ColorDepth::TrueColor},
    {"contour",   ColorDepth::TrueColor},
    {"iterm",     ColorDepth::TrueColor},
    {"vte",       ColorDepth::TrueColor},
    {"mintty",    ColorDepth::TrueColor},
    {"konsole",   ColorDepth::TrueColor},
    {"direct",    ColorDepth::TrueColor},
    {"256",       ColorDepth::Indexed256},
    {"linux",     ColorDepth::Ansi16},
    {"vt100",     ColorDepth::Ansi16},
    {"vt220",     ColorDepth::Ansi16},
    {"ansi",      ColorDepth::Ansi16},
    {"dumb",      ColorDepth::Ansi16},
  }

  enum ThemeDelivery
    Auto
    Push
    Local
  end

  enum ThemeMode
    Auto
    Dark
    Light
  end

  enum PaletteSource
    Terminal
    Generated
    Explicit
  end

  enum Easing
    Linear
    In
    Out
    InOut

    def apply(amount : Float64) : Float64
      case self
      in Linear then amount
      in In     then amount * amount * amount
      in Out    then 1.0 - (1.0 - amount) ** 3
      in InOut  then amount < 0.5 ? 4.0 * amount * amount * amount : 1.0 - (2.0 - 2.0 * amount) ** 3 / 2.0
      end
    end
  end

  enum ContrastModel
    Wcag
    Apca
  end
end
