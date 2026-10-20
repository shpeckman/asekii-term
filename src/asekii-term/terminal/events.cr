# src/asekii/terminal/events.cr
module Asekii::Event
  @[Flags]
  enum Mods : UInt8
    Shift
    Alt
    Ctrl
    Super
    Hyper
    Meta
    CapsLock
    NumLock
  end

  enum Named
    Tab         =     9
    Enter       =    13
    Escape      =    27
    Backspace   =   127
    Insert      = 57348
    Delete
    Left
    Right
    Up
    Down
    PageUp
    PageDown
    Home
    End
    CapsLock
    ScrollLock
    NumLock
    PrintScreen
    Pause
    Menu
    {% for index in 1..35 %}
      F{{ index }}
    {% end %}
    {% for index in 0..9 %}
      Kp{{ index }}
    {% end %}
    KpDecimal
    KpDivide
    KpMultiply
    KpSubtract
    KpAdd
    KpEnter
    KpEqual
    KpSeparator
    KpLeft
    KpRight
    KpUp
    KpDown
    KpPageUp
    KpPageDown
    KpHome
    KpEnd
    KpInsert
    KpDelete
    KpBegin
    MediaPlay
    MediaPause
    MediaPlayPause
    MediaReverse
    MediaStop
    MediaFastForward
    MediaRewind
    MediaTrackNext
    MediaTrackPrevious
    MediaRecord
    LowerVolume
    RaiseVolume
    MuteVolume
    LeftShift
    LeftControl
    LeftAlt
    LeftSuper
    LeftHyper
    LeftMeta
    RightShift
    RightControl
    RightAlt
    RightSuper
    RightHyper
    RightMeta
    IsoLevel3Shift
    IsoLevel5Shift
  end

  COMMAND   = Mods::Ctrl | Mods::Super | Mods::Hyper | Mods::Meta
  LOCKS     = Mods::CapsLock | Mods::NumLock
  MODIFIERS = Named::LeftShift.value..Named::IsoLevel5Shift.value

  enum Direction
    Left
    Right
    Up
    Down
  end

  record Key, code : Int32, action : Action, mods : Mods, shifted : Int32?, base : Int32?, text : String? do
    enum Action
      Press   = 1
      Repeat
      Release
    end

    delegate shift?, alt?, ctrl?, to: @mods
    delegate press?, repeat?, release?, to: @action

    def named : Named?
      Named.from_value?(code)
    end

    def char : Char?
      code.unsafe_chr if code > 0 && named.nil?
    end

    def modifier? : Bool
      MODIFIERS.includes?(code)
    end

    def command? : Bool
      text.nil? || !(mods & COMMAND).none?
    end

    def stroke(physical : Bool = false) : {Int32, Mods}
      plain = mods & ~LOCKS
      return {base || code, plain} if physical
      upper = shifted if plain.shift?
      {upper || code, upper ? plain & ~Mods::Shift : plain}
    end
  end

  record Mouse, action : Action, button : Button, mods : Mods, x : Int32, y : Int32, col : Int32, row : Int32 do
    enum Action
      Press
      Release
      Drag
      Hover
      Scroll
      Leave
    end

    enum Button
      Left
      Middle
      Right
      None
      WheelUp
      WheelDown
      WheelLeft
      WheelRight
      Aux8
      Aux9
      Aux10
      Aux11
    end

    delegate shift?, alt?, ctrl?, to: @mods
  end

  record Resize, rows : Int32, cols : Int32, height : Int32, width : Int32
  record Focus, gained : Bool
  record Resume
  record Visibility, visible : Bool
  record ColorScheme, dark : Bool
  record Paste, mimes : Array(String), primary : Bool, password : String?, text : String? = nil
  record TextInput, text : String
  record KeyCommand, key : Key
  record Lock, lock : Mods, active : Bool
  record TypingMetric, code : Int32, dwell : Time::Span, latency : Time::Span, overlap : Int32
  record Size, width : Int32, height : Int32

  record KeyGesture, kind : Kind, key : Key, count : Int32 = 1 do
    enum Kind
      Activate
      AutoRepeat
      Tap
      MultiTap
      HoldStart
      HoldEnd
      HoldReached
      ModifierTap
    end
  end

  record Binding, kind : Kind, name : String do
    enum Kind
      Chord
      Sequence
      Shortcut
    end
  end

  record MouseGesture, kind : Kind, mouse : Mouse, count : Int32 = 1, dx : Int32 = 0, dy : Int32 = 0, velocity : Float64 = 0.0 do
    enum Kind
      Click
      DragStart
      DragMove
      DragEnd
      Enter
      HoverDwell
      HoverEnd
      Motion
      Scroll
      Swipe
      Chord
      LongPress
    end

    def direction : Direction
      if dx.abs >= dy.abs
        dx < 0 ? Direction::Left : Direction::Right
      else
        dy < 0 ? Direction::Up : Direction::Down
      end
    end
  end

  record Shortcut, code : Int32, mods : Mods, physical : Bool do
    KEYS      = {"space" => ' '.ord, "esc" => Named::Escape.value, "return" => Named::Enter.value}
    MODIFIERS = {"control" => Mods::Ctrl, "cmd" => Mods::Super, "command" => Mods::Super}

    def self.parse(spec : String, physical : Bool = false) : Shortcut
      raise ArgumentError.new("empty shortcut") if spec.empty?
      head, _, name = spec.ends_with?('+') ? {spec.rchop.rchop('+'), "", "+"} : spec.rpartition('+')
      mods = head.split('+', remove_empty: true).reduce(Mods::None) do |found, part|
        found | (MODIFIERS[part.downcase]? || Mods.parse?(part).try { |flag| flag if flag.value.popcount == 1 } || raise ArgumentError.new("unknown modifier #{part.inspect}"))
      end
      code = name.size == 1 ? name[0].ord : KEYS[name.downcase]? || Named.parse?(name).try(&.value) || raise ArgumentError.new("unknown key #{name.inspect}")
      new(code, mods, physical)
    end

    def matches?(key : Key) : Bool
      key.stroke(physical) == {code, mods}
    end
  end

  record Timer, at : Time::Span, kind : Kind, code : Int32 do
    enum Kind
      Hold
      Sequence
      Dwell
      LongPress
      Scroll
    end
  end

  def self.code(key : Char | Named | Int32) : Int32
    case key
    in Char  then key.ord
    in Named then key.value
    in Int32 then key
    end
  end
end
