# src/asekii-term/terminal/config.cr
class Asekii::Terminal
  KEYBOARD = {"\e[>31u", "\e[<u"}

  enum Status
    Done
    EIO
    EINVAL
    ENOSYS
    EPERM
    EBUSY
    EFBIG
  end

  @[Flags]
  enum Feature
    Keyboard
    Resize
    Motion
    Pixels
    Focus
    Visibility
    ColorScheme
    Paste
  end

  record Mode, feature : Feature, number : Int32, fallback : Int32 = 0 do
    def key : String
      number == 0 ? "u" : number.to_s
    end

    def probe : String
      number == 0 ? "\e[?u" : "\e[?#{number}$p"
    end

    def switch(supported : Bool, enable : Bool) : String
      return supported ? KEYBOARD[enable ? 0 : 1] : "" if number == 0
      code = supported ? number : fallback
      code == 0 ? "" : "\e[?#{code}#{enable ? 'h' : 'l'}"
    end
  end

  enum ClipboardProtocol
    Auto
    Kitty
    Osc52
  end

  enum NotifyProtocol
    Auto
    Kitty
    Osc9
    Osc777
  end

  enum Multiplexer
    Auto
    None
    Tmux
    Screen
  end

  FEATURES = [
    Mode.new(Feature::Keyboard, 0),
    Mode.new(Feature::Resize, 2048),
    Mode.new(Feature::Motion, 1003),
    Mode.new(Feature::Pixels, 1016, 1006),
    Mode.new(Feature::Focus, 1004),
    Mode.new(Feature::Visibility, 2033),
    Mode.new(Feature::ColorScheme, 2031),
    Mode.new(Feature::Paste, 5522, 2004),
  ]

  struct Config
    property alternate_screen = true
    property job_control = true
    property detect = true
    property signals = true
    property enter = ""
    property leave = ""
    property app_name : String? = nil
    property clipboard_id = "term"
    property busy_retries = 3
    property busy_delay = 100.milliseconds
    property event_backlog = 65536
    property hover_radius = 4
    property dnd_id = 0
    property event_buffer = 1024
    property query_timeout = 1.second
    property clipboard_timeout = 30.seconds
    property transfer_timeout = 30.seconds
    property hold_repeats = 3
    property hold_after = 500.milliseconds
    property multi_tap_window = 300.milliseconds
    property sequence_timeout = 1.second
    property click_radius = 4
    property click_window = 300.milliseconds
    property multi_click_window = 400.milliseconds
    property long_press_after = 500.milliseconds
    property hover_dwell_after = 500.milliseconds
    property scroll_window = 16.milliseconds
    property scroll_pause = 200.milliseconds
    property swipe_velocity = 500.0
    property clipboard = ClipboardProtocol::Auto
    property notifications = NotifyProtocol::Auto
    property multiplexer = Multiplexer::Auto
    getter chords = {} of String => Array(Int32)
    getter sequences = {} of String => Array(Int32)
    getter shortcuts = {} of String => Event::Shortcut

    def chord(name : String, *keys : Char | Event::Named | Int32) : self
      @chords[name] = keys.map { |key| Asekii::Event.code(key) }.to_a
      self
    end

    def sequence(name : String, *keys : Char | Event::Named | Int32) : self
      @sequences[name] = keys.map { |key| Asekii::Event.code(key) }.to_a
      self
    end

    def shortcut(name : String, key : Char | Event::Named | Int32, mods : Event::Mods = Event::Mods::None, physical : Bool = false) : self
      @shortcuts[name] = Event::Shortcut.new(Asekii::Event.code(key), mods, physical)
      self
    end
  end
end
