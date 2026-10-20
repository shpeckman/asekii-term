# src/asekii-term/terminal/parser.cr
class Asekii::Terminal
  MISSING    = Int32::MIN
  CSI_LIMIT  = 256
  TEXT_LIMIT = 1 << 28
  PASTE_END  = "\e[201~".to_slice

  enum State
    Ground
    Escape
    Ss3
    Csi
    Text
    TextEscape
    Paste
  end

  LETTERS = {
    'A' => Event::Named::Up,
    'B' => Event::Named::Down,
    'C' => Event::Named::Right,
    'D' => Event::Named::Left,
    'E' => Event::Named::KpBegin,
    'F' => Event::Named::End,
    'H' => Event::Named::Home,
    'P' => Event::Named::F1,
    'Q' => Event::Named::F2,
    'S' => Event::Named::F4,
  }

  SS3 = LETTERS.merge({'R' => Event::Named::F3})

  TILDES = {
     2 => Event::Named::Insert,
     3 => Event::Named::Delete,
     5 => Event::Named::PageUp,
     6 => Event::Named::PageDown,
     7 => Event::Named::Home,
     8 => Event::Named::End,
    11 => Event::Named::F1,
    12 => Event::Named::F2,
    13 => Event::Named::F3,
    14 => Event::Named::F4,
    15 => Event::Named::F5,
    17 => Event::Named::F6,
    18 => Event::Named::F7,
    19 => Event::Named::F8,
    20 => Event::Named::F9,
    21 => Event::Named::F10,
    23 => Event::Named::F11,
    24 => Event::Named::F12,
  }

  @state = State::Ground
  @string = 0_u8
  @seq = Bytewire.new(256)
  @reader = Bytewire::Reader.new(Bytes.empty)
  @scratch = Bytewire.new(64)
  @values = [] of Int32
  @starts = [] of Int32
  @utf = Bytewire.new(4)

  private def feed(byte : UInt8) : Nil
    case @state
    in .ground?
      if byte == 0x1b
        @state = State::Escape
      elsif byte < 0x80
        typed(byte.unsafe_chr, Event::Mods::None)
      else
        utf(byte)
      end
    in .escape?
      @seq.reset
      @state = case byte
               when 0x5b then State::Csi
               when 0x4f then State::Ss3
               when 0x1b then State::Escape
               when 0x50, 0x58, 0x5d, 0x5e, 0x5f
                 @string = byte
                 State::Text
               else
                 State::Ground
               end
      if @state.ground?
        byte < 0x80 ? typed(byte.unsafe_chr, Event::Mods::Alt) : utf(byte)
      end
    in .ss3?
      @state = State::Ground
      if named = SS3[byte.unsafe_chr]?
        tapped(Event::Key.new(named.value, Event::Key::Action::Press, Event::Mods::None, nil, nil, nil))
      end
    in .paste?
      @seq.byte(byte)
      slice = @seq.written
      if byte == 0x7e && slice.size >= PASTE_END.size && slice[-PASTE_END.size..] == PASTE_END
        @state = State::Ground
        push Event::Paste.new(["text/plain"], false, nil, String.new(slice[0, slice.size - PASTE_END.size]).scrub)
      elsif slice.size > TEXT_LIMIT
        @state = State::Ground
      end
    in .csi?
      case byte
      when 0x20..0x3f
        @seq.byte(byte)
        @state = State::Ground if @seq.pos > CSI_LIMIT
      when 0x40..0x7e
        @state = State::Ground
        csi(byte)
      when 0x1b
        @state = State::Escape
      else
        @state = State::Ground
      end
    in .text?
      case byte
      when 0x07
        @state = State::Ground
        text
      when 0x1b
        @state = State::TextEscape
      else
        @seq.byte(byte)
        @state = State::Ground if @seq.pos > TEXT_LIMIT
      end
    in .text_escape?
      if byte == 0x5c
        @state = State::Ground
        text
      else
        @state = State::Escape
        feed(byte)
      end
    end
  end

  private def idle : Nil
    case @state
    when .escape?
      @state = State::Ground
      tapped(Event::Key.new(Event::Named::Escape.value, Event::Key::Action::Press, Event::Mods::None, nil, nil, nil))
    when .ss3?
      @state = State::Ground
      typed('O', Event::Mods::Alt)
    end
  end

  private def utf(byte : UInt8) : Nil
    @utf.reset if byte & 0xc0 != 0x80
    @utf.byte(byte)
    slice = @utf.written
    lead = slice[0]
    need = lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc0 ? 2 : 0
    return @utf.reset if need == 0
    return if slice.size < need
    @reader.reset(slice)
    char = @reader.char?
    @utf.reset
    typed(char, Event::Mods::None) if char
  end

  private def typed(char : Char, mods : Event::Mods) : Nil
    code, extra, text =
      case char.ord
      when 0x0d   then {Event::Named::Enter.value, Event::Mods::None, nil}
      when 0x09   then {Event::Named::Tab.value, Event::Mods::None, nil}
      when 0x7f   then {Event::Named::Backspace.value, Event::Mods::None, nil}
      when 0x00   then {32, Event::Mods::Ctrl, nil}
      when 1..26  then {char.ord + 96, Event::Mods::Ctrl, nil}
      when 28..31 then {char.ord + 64, Event::Mods::Ctrl, nil}
      else
        lower = char.downcase
        {lower.ord, lower == char ? Event::Mods::None : Event::Mods::Shift, char.to_s}
      end
    mods |= extra
    shifted = char.ord if text && mods.shift?
    tapped(Event::Key.new(code, Event::Key::Action::Press, mods, shifted, nil, mods.alt? ? nil : text))
  end

  private def tapped(key : Event::Key) : Nil
    push key
    push key.copy_with(action: Event::Key::Action::Release, text: nil)
  end

  private def text : Nil
    case @string
    when 0x5d then osc
    when 0x5f then apc
    when 0x50 then dcs
    end
  rescue Base64::Error | ArgumentError
  end

  private def parse(bytes : Bytes) : Nil
    @values.clear
    @starts.clear
    @starts << 0
    current = MISSING
    negative = false
    bytes.each do |byte|
      case byte
      when 0x30..0x39
        current = (current == MISSING ? 0 : current) &* 10 &+ (byte &- 0x30)
      when 0x2d
        negative = true
      when 0x3a, 0x3b
        @values << (negative && current != MISSING ? -current : current)
        current = MISSING
        negative = false
        @starts << @values.size if byte == 0x3b
      end
    end
    @values << (negative && current != MISSING ? -current : current)
  end

  private def param(group : Int32, sub : Int32 = 0, default : Int32 = MISSING) : Int32
    start = @starts[group]? || return default
    stop = @starts[group + 1]? || @values.size
    index = start + sub
    return default unless index < stop
    value = @values[index]
    value == MISSING ? default : value
  end

  private def csi(final : UInt8) : Nil
    bytes = @seq.written
    letter = final.unsafe_chr
    parse(bytes)
    case bytes.first?.try(&.unsafe_chr)
    when '<'
      mouse(letter == 'm') if letter.in?('M', 'm')
    when '?'
      case letter
      when 'c'
        attributes = Attributes.new(@values.reject(MISSING))
        settle_palette if (waiting = peek(Query::Palette)) && peek(Query::Attributes).try(&.waiter.same?(waiting.waiter))
        route(Query::Attributes, attributes, strict: true)
      when 'u'
        route(Query::Mode, 1, "u")
      when 'y'
        route(Query::Mode, param(1, 0, 0), param(0, 0, 0).to_s)
      when 'n'
        case param(0)
        when 997 then push Event::ColorScheme.new(param(1) == 1)
        when 999 then push Event::Visibility.new(param(1) == 1)
        end
      end
    when '>'
      route(Query::Device, Device.new(param(0, 0, 0), param(1, 0, 0), param(2, 0, 0))) if letter == 'c'
    when '='
      nil
    else
      case letter
      when 'u' then key(param(0, 0, 0))
      when '~' then tilde
      when 'I' then push Event::Focus.new(true)
      when 'O' then push Event::Focus.new(false)
      when 't' then report
      else          LETTERS[letter]?.try { |named| key(named.value) }
      end
    end
  end

  private def tilde : Nil
    if param(0) == 200
      @seq.reset
      @state = State::Paste
    else
      TILDES[param(0)]?.try { |named| key(named.value) }
    end
  end

  private def report : Nil
    case param(0)
    when 48
      resize
    when 4
      width = param(2, 0, 0)
      height = param(1, 0, 0)
      if blind?
        rows = @rows.get
        cols = @cols.get
        resolve(width // cols, height // rows) if rows > 0
      end
      route(Query::Window, Event::Size.new(width, height))
    when 6
      width = param(2, 0, 0)
      height = param(1, 0, 0)
      resolve(width, height)
      route(Query::Cell, Event::Size.new(width, height))
    end
  end

  private def key(code : Int32) : Nil
    mods = Event::Mods.new((param(1, 0, 1) &- 1).to_u8!)
    action = Event::Key::Action.from_value?(param(1, 1, 1)) || Event::Key::Action::Press
    shifted = param(0, 1, 0)
    base = param(0, 2, 0)
    text = if @starts.size > 2
             @scratch.reset
             (@starts[2]...@values.size).each do |index|
               char(@values[index]).try { |char| @scratch.char(char) }
             end
             String.new(@scratch.written) unless @scratch.empty?
           end
    key = Event::Key.new(code, action, mods, shifted > 0 ? shifted : nil, base > 0 ? base : nil, text)
    features.keyboard? ? push(key) : tapped(key)
  end

  private def char(value : Int32) : Char?
    value.unsafe_chr if 0 < value <= Char::MAX_CODEPOINT && !(0xd800..0xdfff).includes?(value)
  end

  private def mouse(release : Bool) : Nil
    pb = param(0, 0, 0)
    x = param(1, 0, 0)
    y = param(2, 0, 0)
    low = pb & 3
    action, button =
      if pb.bits_set?(256)
        {Event::Mouse::Action::Leave, Event::Mouse::Button::None}
      elsif pb.bits_set?(64)
        {Event::Mouse::Action::Scroll, Event::Mouse::Button.new(4 + low)}
      elsif pb.bits_set?(32) && low == 3
        {Event::Mouse::Action::Hover, Event::Mouse::Button::None}
      elsif release
        {Event::Mouse::Action::Release, Event::Mouse::Button.new(pb.bits_set?(128) ? 8 + low : low)}
      elsif pb.bits_set?(32)
        {Event::Mouse::Action::Drag, Event::Mouse::Button.new(pb.bits_set?(128) ? 8 + low : low)}
      else
        {Event::Mouse::Action::Press, Event::Mouse::Button.new(pb.bits_set?(128) ? 8 + low : low)}
      end
    width = @cell_width.get
    height = @cell_height.get
    if features.pixels?
      col = width > 0 ? x // width : 0
      row = height > 0 ? y // height : 0
    else
      col = {x - 1, 0}.max
      row = {y - 1, 0}.max
      x = col * {width, 1}.max
      y = row * {height, 1}.max
    end
    push Event::Mouse.new(action, button, Event::Mods.new(((pb >> 2) & 7).to_u8!), x, y, col, row)
  end

  private def resize : Nil
    rows = param(1, 0, 0)
    cols = param(2, 0, 0)
    height = param(3, 0, 0)
    width = param(4, 0, 0)
    if resize = span(rows, cols, height, width)
      push resize
      requery
    else
      push Event::Resize.new(rows, cols, height, width)
    end
  end

  private def fields(bytes : Bytes, separator : UInt8 = 0x3a_u8) : Hash(String, String)
    result = {} of String => String
    reader = Bytewire::Reader.new(bytes)
    until reader.eof?
      pair = reader.take_until?(separator) || reader.take_rest
      reader.byte?
      next if pair.empty?
      sub = Bytewire::Reader.new(pair)
      name = sub.take_until?(0x3d_u8) || sub.take_rest
      value = sub.match?(0x3d_u8) ? sub.take_rest : Bytes.empty
      result[String.new(name).strip] = String.new(value).strip
    end
    result
  end

  private def fields(text : String, separator : Char = ':') : Hash(String, String)
    fields(text.to_slice, separator.ord.to_u8)
  end

  private def number(meta : Hash(String, String), name : String) : Int32
    meta[name]?.try(&.to_i?) || 0
  end

  private def osc : Nil
    @reader.reset(@seq.written)
    code = @reader.int?(Int32) || return
    return unless @reader.semi?
    case code
    when 22
      route(Query::Shape, String.new(@reader.take_rest))
    when 21
      route(Query::Color, decode_colors(@reader.take_rest))
    when 4
      indexed(@reader.take_rest)
    when 10..19
      dynamic(code, @reader.take_rest)
    when 52
      pasted(@reader.take_rest)
    when 5522, 99, DND
      meta = @reader.take_until?(0x3b_u8) || @reader.take_rest
      payload = @reader.semi? ? String.new(@reader.take_rest) : ""
      parsed = fields(meta)
      case code
      when 5522 then clipboard(parsed, payload)
      when 99   then notified(parsed, payload)
      when DND  then chained(parsed, payload)
      end
    end
  end

  private def dcs : Nil
    @reader.reset(@seq.written)
    return unless @reader.match?('>') && @reader.match?('|')
    route(Query::Version, String.new(@reader.take_rest).scrub)
  end

  private def apc : Nil
    @reader.reset(@seq.written)
    return unless @reader.match?('G')
    control = @reader.take_until?(0x3b_u8) || @reader.take_rest
    message = @reader.semi? ? String.new(@reader.take_rest) : ""
    meta = fields(control, 0x2c_u8)
    ack = Event::Ack.new(meta["i"]?.try(&.to_u32?) || 0_u32, meta["I"]?.try(&.to_u32?) || 0_u32, meta["p"]?.try(&.to_u32?) || 0_u32, message)
    route(Query::Graphics, ack, ack.number != 0 ? "I#{ack.number}" : "i#{ack.image}") || push(ack)
  end
end
