# spec/terminal/terminal_spec.cr
require "spec"
require "file_utils"
require "../../src/asekii-term/terminal"

ENV.delete("TMUX")
ENV.delete("STY")

MODES_ON  = "\e[>31u\e[?2048h\e[?1003h\e[?1016h\e[?1004h\e[?2033h\e[?2031h\e[?5522h\e[16t"
MODES_OFF = "\e[?5522l\e[?2031l\e[?2033l\e[?1004l\e[?1016l\e[?1003l\e[?2048l\e[<u"
SETUP     = "\e[?1049h" + MODES_ON
TEARDOWN  = MODES_OFF + "\e[?1049l"
PROBES    = "\e[?1049h\e[?u\e[c\e[?2048$p\e[c\e[?1003$p\e[c\e[?1016$p\e[c\e[?1004$p\e[c\e[?2033$p\e[c\e[?2031$p\e[c\e[?5522$p\e[c"
DA1       = "\e[?62;c"

private def child(scenario : String) : NoReturn
  config = Asekii::Terminal::Config.new
  config.detect = scenario == "bare"
  config.query_timeout = 50.milliseconds
  config.signals = scenario != "unhooked"
  term = Asekii::Terminal.new(config, STDIN, STDOUT)
  term.accept_drops
  term.print "READY"
  if scenario == "exit"
    sleep 100.milliseconds
    exit 3
  end
  spawn do
    sleep 20.seconds
    exit 1
  end
  while event = term.events.receive?
    term.print "SIZE #{event.rows}x#{event.cols} #{event.width}x#{event.height}" if event.is_a?(Asekii::Event::Resize)
  end
  exit 1
end

ENV["TERM_SPEC_CHILD"]?.try { |scenario| child(scenario) }

private def plain : Asekii::Terminal::Config
  config = Asekii::Terminal::Config.new
  config.detect = false
  config.signals = false
  config
end

private def drain(screen, needle : String) : String
  screen.read_timeout = 20.milliseconds
  chunk = Bytes.new(65536)
  seen  = ""
  150.times do
    return seen if seen.includes?(needle)
    begin
      count = screen.read(chunk)
      seen += String.new(chunk[0, count]) if count > 0
    rescue IO::TimeoutError
    end
  end
  raise "expected #{needle.inspect}, got #{seen.inspect}"
end

private def detect(replies : String, limit : Time::Span = 1.second, & : Asekii::Terminal, IO::FileDescriptor, IO::FileDescriptor, String ->) : Nil
  reader, feed = IO.pipe
  screen, writer = IO.pipe
  config = Asekii::Terminal::Config.new
  config.signals = false
  config.query_timeout = limit
  opened = Channel(Asekii::Terminal).new(1)
  spawn { opened.send(Asekii::Terminal.new(config, reader, writer)) }
  probes = drain(screen, "\e[?5522$p\e[c")
  feed << replies
  feed.flush
  term = opened.receive
  begin
    yield term, feed, screen, probes
  ensure
    feed.close
    term.close
    writer.close
    screen.close
    reader.close
  end
end

private def finish(term : Asekii::Terminal, feed : IO::FileDescriptor, screen : IO::FileDescriptor) : String
  term.print "END"
  output = drain(screen, "END").rchop("END")
  feed.close
  term.close
  output + drain(screen, "\e[?1049l")
end

private def await(term : Asekii::Terminal, type : T.class) : T forall T
  loop do
    select
    when event = term.events.receive?
      raise "events closed" unless event
      return event if event.is_a?(T)
    when timeout(3.seconds)
      raise "no #{T} event"
    end
  end
end

private def window(rows : Int32, cols : Int32, width : Int32 = 0, height : Int32 = 0) : TTY::Winsize
  TTY::Winsize.new(rows.to_u16, cols.to_u16, width.to_u16, height.to_u16)
end

private def raw?(mode : TTY::Termios) : Bool
  !mode.canonical? && !mode.echo? && !mode.signals? && !mode.output.includes?(TTY::OutputFlag::OPost)
end

private class Console
  getter pty  : TTY::PTY
  getter term : Asekii::Terminal

  def initialize(config : Asekii::Terminal::Config = plain, size : TTY::Winsize? = nil, & : TTY::PTY ->)
    @pty = TTY::PTY.open
    size.try { |value| @pty.winsize = value }
    yield @pty
    slave = @pty.slave_io
    config.job_control = false
    @term = Asekii::Terminal.new(config, slave, slave)
  end

  def feed(text : String) : Nil
    @pty.io << text
  end

  def expect(needle : String) : String
    drain(@pty.io, needle)
  end

  def mode : TTY::Termios
    @pty.termios
  end

  def close : Nil
    @term.close
    @pty.close
  end
end

private def console(config : Asekii::Terminal::Config = plain, size : TTY::Winsize? = nil, prepare : TTY::PTY -> = ->(_pty : TTY::PTY) { }, & : Console ->) : Nil
  console = Console.new(config, size) { |pty| prepare.call(pty) }
  begin
    yield console
  ensure
    console.close
  end
end

private def stopped?(process : TTY::PTY::Process, expected : Bool) : Bool
  200.times do
    state = File.read("/proc/#{process.pid}/stat").rpartition(')')[2].split.first
    return true if (state == "T") == expected
    sleep 10.milliseconds
  end
  false
end

private def reap(process : TTY::PTY::Process) : Nil
  unless process.exited?
    begin
      process.kill
    rescue TTY::Error
    end
    process.wait
  end
  process.close
end

private def child(scenario : String, & : TTY::PTY::Process ->) : {String, TTY::ChildStatus}
  process = TTY::PTY.spawn(Process.executable_path.not_nil!, env: {"TERM_SPEC_CHILD" => scenario}, winsize: window(30, 100, 1000, 600))
  begin
    drain(process.io, "READY")
    yield process
    process.io.read_timeout = 5.seconds
    {process.io.gets_to_end, process.wait}
  ensure
    reap(process)
  end
end

private def osc(body : String) : String
  "\e]#{body}\e\\"
end

private def apc(body : String) : String
  "\e_G#{body}\e\\"
end

private def b64(data : String | Bytes) : String
  Base64.strict_encode(data)
end

private def press(key : Char) : String
  "\e[#{key.ord}u"
end

private def release(key : Char) : String
  "\e[#{key.ord};1:3u"
end

private def tap(key : Char) : String
  press(key) + release(key)
end

private class Rig
  getter term : Asekii::Terminal
  getter seen = ""
  getter last = ""
  @buffer = ""
  @feed   : IO::FileDescriptor
  @screen : IO::FileDescriptor
  @reader : IO::FileDescriptor
  @writer : IO::FileDescriptor

  def initialize(config : Asekii::Terminal::Config = plain)
    reader, @feed = IO.pipe
    @screen, writer = IO.pipe
    @screen.read_timeout = 20.milliseconds
    @term   = Asekii::Terminal.new(config, reader, writer)
    @reader = reader
    @writer = writer
    expect(/\e\[16t/)
  end

  def feed(text : String) : Nil
    @feed << text
    @feed.flush
  end

  def expect(pattern : Regex, attempts : Int32 = 150) : Regex::MatchData
    chunk = Bytes.new(65536)
    attempts.times do
      if match = pattern.match(@buffer)
        @seen   = match.pre_match + match[0]
        @last   = match[0]
        @buffer = match.post_match
        return match
      end
      begin
        count = @screen.read(chunk)
        @buffer += String.new(chunk[0, count]) if count > 0
      rescue IO::TimeoutError
      end
    end
    raise "expected output matching #{pattern.inspect}, got #{@buffer.inspect}"
  end

  def expect(text : String) : Regex::MatchData
    expect(Regex.new(Regex.escape(text)))
  end

  def ask(pattern : Regex, reply : Regex::MatchData -> String, &block : -> T) : T forall T
    result = Channel(T).new(1)
    spawn { result.send(block.call) }
    feed(reply.call(expect(pattern)))
    select
    when value = result.receive
      value
    when timeout(5.seconds)
      raise "no result for #{pattern.inspect}"
    end
  end

  def ask(pattern : Regex, reply : String, &block : -> T) : T forall T
    ask(pattern, ->(_match : Regex::MatchData) { reply }, &block)
  end

  def event(type : T.class, & : T -> Bool) : T forall T
    loop do
      select
      when event = @term.events.receive?
        raise "events closed while waiting for #{T}" unless event
        return event if event.is_a?(T) && yield event
      when timeout(3.seconds)
        raise "no #{T} event"
      end
    end
  end

  def event(type : T.class) : T forall T
    event(type) { true }
  end

  def upto(& : Asekii::Event::Input -> Bool) : Array(Asekii::Event::Input)
    events = [] of Asekii::Event::Input
    loop do
      select
      when event = @term.events.receive?
        raise "events closed" unless event
        events << event
        return events if yield event
      when timeout(3.seconds)
        raise "marker event never arrived, got #{events.inspect}"
      end
    end
  end

  def close : Nil
    @feed.close
    @term.close
    @writer.close
    @screen.close
    @reader.close
  end
end

private def rig(config : Asekii::Terminal::Config = plain, & : Rig ->) : Nil
  rig = Rig.new(config)
  begin
    yield rig
  ensure
    rig.close
  end
end

private def kinds(events : Array(Asekii::Event::Input)) : Array(Asekii::Event::KeyGesture::Kind)
  events.compact_map(&.as?(Asekii::Event::KeyGesture)).map(&.kind)
end

private def gestures(events : Array(Asekii::Event::Input)) : Array(Asekii::Event::MouseGesture::Kind)
  events.compact_map(&.as?(Asekii::Event::MouseGesture)).map(&.kind)
end

private def bindings(events : Array(Asekii::Event::Input), kind : Asekii::Event::Binding::Kind) : Array(String)
  events.compact_map(&.as?(Asekii::Event::Binding)).select { |binding| binding.kind == kind }.map(&.name)
end

private def marker?(event : Asekii::Event::Input, key : Char) : Bool
  event.is_a?(Asekii::Event::TypingMetric) && event.code == key.ord
end

SIZE_ASK    = "\e[14t"
SIZE_ANSWER = "\e[4;600;800t"
POOL        = Fiber::ExecutionContext::Parallel.new("term.spec", 4)

private def swarm(count : Int32, &block : Int32 ->) : Nil
  results = Channel(Exception?).new(count)
  count.times do |index|
    POOL.spawn do
      block.call(index)
      results.send(nil)
    rescue error
      results.send(error)
    end
  end
  Array.new(count) { results.receive }.compact.first?.try { |error| raise error }
end

private def launch(context : Fiber::ExecutionContext::Parallel?, config : Asekii::Terminal::Config, reader : IO::FileDescriptor, writer : IO::FileDescriptor) : Asekii::Terminal
  return Asekii::Terminal.new(config, reader, writer) unless context
  made = Channel(Asekii::Terminal).new(1)
  context.spawn { made.send(Asekii::Terminal.new(config, reader, writer)) }
  made.receive
end

private def capture(config : Asekii::Terminal::Config = plain, context : Fiber::ExecutionContext::Parallel? = nil, pattern : Regex = /\e\[14t/, reply : Regex::MatchData -> String = ->(_match : Regex::MatchData) { SIZE_ANSWER }, & : Asekii::Terminal, IO::FileDescriptor ->) : String
  reader, feed = IO.pipe
  screen, writer = IO.pipe
  output = Channel(String).new(1)
  seen   = String::Builder.new
  spawn do
    tail  = ""
    chunk = Bytes.new(65536)
    loop do
      count = screen.read(chunk)
      break if count == 0
      text = String.new(chunk[0, count])
      seen << text
      tail += text
      begin
        while match = pattern.match(tail)
          feed << reply.call(match)
          tail = match.post_match
        end
        feed.flush
      rescue IO::Error
      end
      tail = tail.byte_slice({tail.bytesize - 64, 0}.max)
    end
  rescue IO::Error
  ensure
    output.send(seen.to_s)
  end
  term = launch(context, config, reader, writer)
  begin
    yield term, feed
  ensure
    feed.close
    term.close
    writer.close
  end
  result = select
  when text = output.receive
    text
  when timeout(10.seconds)
    raise "output never ended"
  end
  screen.close
  reader.close
  result
end

private def roundtrip : String
  reader, feed = IO.pipe
  screen, writer = IO.pipe
  term = Asekii::Terminal.new(plain, reader, writer)
  Asekii::Terminal.refresh
  feed.close
  term.close
  writer.close
  output = screen.gets_to_end
  screen.close
  reader.close
  output
end

private def settle(term : Asekii::Terminal) : Nil
  term.window_size(5.seconds).should eq(Asekii::Event::Size.new(800, 600))
end

private def cycles(ending : String) : Regex
  setup    = Regex.escape(SETUP)
  teardown = Regex.escape(TEARDOWN)
  Regex.new("\\A#{setup}(?:#{teardown}#{setup})*#{teardown}#{ending}\\z")
end

describe Asekii::Terminal do
  describe "lifecycle" do
    it "enables every mode on open and undoes them in reverse on close" do
      reader, feed = IO.pipe
      screen, writer = IO.pipe
      term = Asekii::Terminal.new(plain, reader, writer)
      term.closed?.should be_false
      feed.close
      term.close
      writer.close
      screen.gets_to_end.should eq(SETUP + TEARDOWN)
      term.closed?.should be_true
      term.events.receive?.should be_nil
    end

    it "stays on the main screen when the alternate screen is disabled" do
      config = plain
      config.alternate_screen = false
      reader, feed = IO.pipe
      screen, writer = IO.pipe
      term = Asekii::Terminal.new(config, reader, writer)
      feed.close
      term.close
      writer.close
      output = screen.gets_to_end
      output.should_not contain("1049")
      output.should start_with("\e[>31u")
      output.should end_with("\e[<u")
    end

    it "closes when the block given to open returns and tolerates a second close" do
      reader, feed = IO.pipe
      screen, writer = IO.pipe
      captured = nil
      Asekii::Terminal.open(plain, reader, writer) do |term|
        captured = term
        feed.close
      end
      term = captured.not_nil!
      term.closed?.should be_true
      term.close
      writer.close
      screen.gets_to_end.should eq(SETUP + TEARDOWN)
    end

    it "writes through print and <<" do
      rig do |rig|
        rig.term.print "a", 1, :b
        rig.term << "x" << 2
        rig.expect("a1bx2")
      end
    end
  end

  describe "keyboard" do
    it "decodes every field of a CSI u report" do
      rig do |rig|
        rig.feed "\e[97:65:113;2:1;65u"
        key = rig.event(Asekii::Event::Key)
        key.code.should eq(97)
        key.char.should eq('a')
        key.shifted.should eq(65)
        key.base.should eq(113)
        key.mods.should eq(Asekii::Event::Mods::Shift)
        key.shift?.should be_true
        key.press?.should be_true
        key.text.should eq("A")
        key.named.should be_nil
        key.command?.should be_false
      end
    end

    it "decodes the whole modifier bitfield and the event type" do
      rig do |rig|
        rig.feed "\e[97;256:2u\e[97;1:3u"
        key = rig.event(Asekii::Event::Key)
        key.mods.should eq(Asekii::Event::Mods::All)
        key.repeat?.should be_true
        rig.event(Asekii::Event::Key).release?.should be_true
      end
    end

    it "treats a missing modifier field as no modifiers and a press" do
      rig do |rig|
        rig.feed "\e[13u"
        key = rig.event(Asekii::Event::Key)
        key.named.should eq(Asekii::Event::Named::Enter)
        key.mods.should eq(Asekii::Event::Mods::None)
        key.press?.should be_true
        key.char.should be_nil
      end
    end

    it "decodes legacy letter and tilde forms" do
      rig do |rig|
        rig.feed "\e[1;5A\e[B\e[3~\e[15;2~\e[1;3:3H\e[E"
        up = rig.event(Asekii::Event::Key)
        up.named.should eq(Asekii::Event::Named::Up)
        up.ctrl?.should be_true
        rig.event(Asekii::Event::Key).named.should eq(Asekii::Event::Named::Down)
        rig.event(Asekii::Event::Key).named.should eq(Asekii::Event::Named::Delete)
        f5 = rig.event(Asekii::Event::Key)
        f5.named.should eq(Asekii::Event::Named::F5)
        f5.shift?.should be_true
        home = rig.event(Asekii::Event::Key)
        home.named.should eq(Asekii::Event::Named::Home)
        home.alt?.should be_true
        home.release?.should be_true
        rig.event(Asekii::Event::Key).named.should eq(Asekii::Event::Named::KpBegin)
      end
    end

    it "maps the documented functional key codes" do
      Asekii::Event::Named::CapsLock.value.should eq(57358)
      Asekii::Event::Named::Menu.value.should eq(57363)
      Asekii::Event::Named::F13.value.should eq(57376)
      Asekii::Event::Named::F35.value.should eq(57398)
      Asekii::Event::Named::Kp0.value.should eq(57399)
      Asekii::Event::Named::KpBegin.value.should eq(57427)
      Asekii::Event::Named::MediaPlay.value.should eq(57428)
      Asekii::Event::Named::MuteVolume.value.should eq(57440)
      Asekii::Event::Named::LeftShift.value.should eq(57441)
      Asekii::Event::Named::RightShift.value.should eq(57447)
      Asekii::Event::Named::IsoLevel5Shift.value.should eq(57454)
      rig do |rig|
        rig.feed "\e[57376u\e[57441;2u"
        rig.event(Asekii::Event::Key).named.should eq(Asekii::Event::Named::F13)
        shift = rig.event(Asekii::Event::Key)
        shift.named.should eq(Asekii::Event::Named::LeftShift)
        shift.modifier?.should be_true
      end
    end

    it "emits text input for text and not for commands or releases" do
      rig do |rig|
        rig.feed "\e[0;;229:8364u\e[97;5;97u\e[98;1:3;98u#{tap('q')}"
        events = rig.upto { |event| marker?(event, 'q') }
        events.compact_map(&.as?(Asekii::Event::TextInput)).map(&.text).should eq(["å€"])
        keys = events.compact_map(&.as?(Asekii::Event::Key))
        keys[0].code.should eq(0)
        keys[0].text.should eq("å€")
        keys[1].command?.should be_true
      end
    end

    it "reports a tap, counts multi-taps and measures typing" do
      rig do |rig|
        rig.feed tap('a') + tap('a') + tap('b')
        events = rig.upto { |event| marker?(event, 'b') }
        taps   = events.compact_map(&.as?(Asekii::Event::KeyGesture)).select(&.kind.tap?)
        taps.map(&.count).should eq([1, 2, 1])
        taps.map(&.key.code).should eq([97, 97, 98])
        metrics = events.compact_map(&.as?(Asekii::Event::TypingMetric))
        metrics.size.should eq(3)
        metrics[0].latency.should eq(Time::Span.zero)
        metrics[0].overlap.should eq(0)
      end
    end

    it "counts rollover overlap from the pressed set" do
      rig do |rig|
        rig.feed press('a') + press('b') + release('a') + release('b')
        events  = rig.upto { |event| marker?(event, 'b') }
        metrics = events.compact_map(&.as?(Asekii::Event::TypingMetric))
        metrics.map(&.code).should eq([97, 98])
        metrics.map(&.overlap).should eq([0, 1])
      end
    end

    it "turns repeats into a hold and reports the repeat threshold" do
      rig do |rig|
        rig.feed "#{press('a')}\e[97;1:2u\e[97;1:2u\e[97;1:2u#{release('a')}"
        events = rig.upto { |event| marker?(event, 'a') }
        kinds(events).should eq([
          Asekii::Event::KeyGesture::Kind::Activate,
          Asekii::Event::KeyGesture::Kind::HoldStart,
          Asekii::Event::KeyGesture::Kind::AutoRepeat,
          Asekii::Event::KeyGesture::Kind::AutoRepeat,
          Asekii::Event::KeyGesture::Kind::HoldReached,
          Asekii::Event::KeyGesture::Kind::AutoRepeat,
          Asekii::Event::KeyGesture::Kind::HoldEnd,
        ])
        reached = events.compact_map(&.as?(Asekii::Event::KeyGesture)).find!(&.kind.hold_reached?)
        reached.count.should eq(3)
      end
    end

    it "starts a hold from the timer when no repeat arrives" do
      config = plain
      config.hold_after = 20.milliseconds
      rig(config) do |rig|
        rig.feed press('a')
        rig.event(Asekii::Event::KeyGesture, &.kind.hold_start?).key.code.should eq(97)
        rig.feed release('a')
        rig.event(Asekii::Event::KeyGesture, &.kind.hold_end?)
      end
    end

    it "fires a chord once per completion and re-arms after a release" do
      config = plain
      config.chord("ab", 'a', 'b')
      rig(config) do |rig|
        rig.feed press('a') + press('b') + press('c') + "\e[98;1:2u" + release('b') + press('b') + tap('q')
        events = rig.upto { |event| marker?(event, 'q') }
        bindings(events, :chord).should eq(["ab", "ab"])
      end
    end

    it "walks a key sequence and ignores modifiers and repeats in between" do
      config = plain
      config.sequence("leader", ' ', 'f', 'g')
      rig(config) do |rig|
        rig.feed "#{tap(' ')}\e[57441;2u\e[57441;1:3u#{press('f')}\e[102;1:2u#{release('f')}#{tap('g')}"
        events = rig.upto { |event| marker?(event, 'g') }
        bindings(events, :sequence).should eq(["leader"])
      end
    end

    it "resets a key sequence on a wrong key and on the timeout" do
      config = plain
      config.sequence_timeout = 20.milliseconds
      config.sequence("gg", 'g', 'g')
      rig(config) do |rig|
        rig.feed tap('g') + tap('x') + tap('g')
        events = rig.upto { |event| marker?(event, 'g') && event.as(Asekii::Event::TypingMetric).latency > Time::Span.zero }
        bindings(events, :sequence).should be_empty
        sleep 80.milliseconds
        rig.feed tap('q') + tap('g')
        events = rig.upto { |event| marker?(event, 'g') }
        bindings(events, :sequence).should be_empty
        rig.feed tap('g')
        events = rig.upto { |event| marker?(event, 'g') }
        bindings(events, :sequence).should eq(["gg"])
      end
    end

    it "matches symbolic shortcuts, ignoring lock modifiers and consuming shift" do
      config = plain
      config.shortcut("save", 's', Asekii::Event::Mods::Ctrl)
      config.shortcut("plus", '+', Asekii::Event::Mods::Ctrl)
      rig(config) do |rig|
        rig.feed "\e[115;5u\e[115;197u\e[61:43;6u\e[115;3u#{tap('q')}"
        events = rig.upto { |event| marker?(event, 'q') }
        bindings(events, :shortcut).should eq(["save", "save", "plus"])
      end
    end

    it "parses shortcut specs" do
      Asekii::Event::Shortcut.parse("ctrl+shift+a").should eq(Asekii::Event::Shortcut.new('a'.ord, Asekii::Event::Mods::Ctrl | Asekii::Event::Mods::Shift, false))
      Asekii::Event::Shortcut.parse("Control+S").should eq(Asekii::Event::Shortcut.new('S'.ord, Asekii::Event::Mods::Ctrl, false))
      Asekii::Event::Shortcut.parse("enter").should eq(Asekii::Event::Shortcut.new(Asekii::Event::Named::Enter.value, Asekii::Event::Mods::None, false))
      Asekii::Event::Shortcut.parse("alt+page_up").code.should eq(Asekii::Event::Named::PageUp.value)
      Asekii::Event::Shortcut.parse("f13").code.should eq(Asekii::Event::Named::F13.value)
      Asekii::Event::Shortcut.parse("kp_5").code.should eq(Asekii::Event::Named::Kp5.value)
      Asekii::Event::Shortcut.parse("ctrl++").should eq(Asekii::Event::Shortcut.new('+'.ord, Asekii::Event::Mods::Ctrl, false))
      Asekii::Event::Shortcut.parse("+").should eq(Asekii::Event::Shortcut.new('+'.ord, Asekii::Event::Mods::None, false))
      Asekii::Event::Shortcut.parse("cmd+space", physical: true).should eq(Asekii::Event::Shortcut.new(' '.ord, Asekii::Event::Mods::Super, true))
      expect_raises(ArgumentError) { Asekii::Event::Shortcut.parse("") }
      expect_raises(ArgumentError) { Asekii::Event::Shortcut.parse("hyperdrive+a") }
      expect_raises(ArgumentError) { Asekii::Event::Shortcut.parse("all+a") }
      expect_raises(ArgumentError) { Asekii::Event::Shortcut.parse("ctrl+nope") }
    end

    it "matches a shortcut against a key the way bindings do" do
      press = Asekii::Event::Key::Action::Press
      save  = Asekii::Event::Shortcut.parse("ctrl+s")
      plus  = Asekii::Event::Shortcut.parse("ctrl++")
      quit  = Asekii::Event::Shortcut.parse("ctrl+q", physical: true)
      save.matches?(Asekii::Event::Key.new('s'.ord, press, Asekii::Event::Mods::Ctrl | Asekii::Event::Mods::CapsLock, nil, nil, nil)).should be_true
      save.matches?(Asekii::Event::Key.new('s'.ord, press, Asekii::Event::Mods::Alt, nil, nil, nil)).should be_false
      plus.matches?(Asekii::Event::Key.new('='.ord, press, Asekii::Event::Mods::Ctrl | Asekii::Event::Mods::Shift, '+'.ord, nil, nil)).should be_true
      quit.matches?(Asekii::Event::Key.new('a'.ord, press, Asekii::Event::Mods::Ctrl, nil, 'q'.ord, nil)).should be_true
      quit.matches?(Asekii::Event::Key.new('q'.ord, press, Asekii::Event::Mods::Ctrl, nil, nil, nil)).should be_true
      quit.matches?(Asekii::Event::Key.new('a'.ord, press, Asekii::Event::Mods::Ctrl, nil, nil, nil)).should be_false
    end

    it "matches physical shortcuts on the base layout key" do
      config = plain
      config.shortcut("quit", 'q', Asekii::Event::Mods::Ctrl, physical: true)
      rig(config) do |rig|
        rig.feed "\e[97::113;5u\e[113;5u\e[97;5u#{tap('z')}"
        events = rig.upto { |event| marker?(event, 'z') }
        bindings(events, :shortcut).should eq(["quit", "quit"])
      end
    end

    it "reports a modifier tapped alone and not one used with another key" do
      rig do |rig|
        rig.feed "\e[57441;2u\e[57441;1:3u\e[57442;5u#{press('a')}\e[57442;1:3u#{release('a')}"
        events = rig.upto { |event| marker?(event, 'a') }
        taps   = events.compact_map(&.as?(Asekii::Event::KeyGesture)).select(&.kind.modifier_tap?)
        taps.map(&.key.code).should eq([57441])
      end
    end
  end

  describe "mouse" do
    it "decodes buttons, modifiers and pixel coordinates" do
      rig do |rig|
        rig.feed "\e[<20;45;65M"
        mouse = rig.event(Asekii::Event::Mouse)
        mouse.action.should eq(Asekii::Event::Mouse::Action::Press)
        mouse.button.should eq(Asekii::Event::Mouse::Button::Left)
        mouse.mods.should eq(Asekii::Event::Mods::Shift | Asekii::Event::Mods::Ctrl)
        mouse.x.should eq(45)
        mouse.y.should eq(65)
        mouse.col.should eq(0)
        mouse.row.should eq(0)
      end
    end

    it "decodes every event class in priority order" do
      rig do |rig|
        rig.feed "\e[<1;1;1M\e[<2;1;1m\e[<34;2;2M\e[<35;3;3M\e[<65;3;3M\e[<67;3;3M\e[<129;3;3M\e[<131;3;3m\e[<8;3;3M\e[<256;0;0M"
        expected = [
          {Asekii::Event::Mouse::Action::Press,   Asekii::Event::Mouse::Button::Middle},
          {Asekii::Event::Mouse::Action::Release, Asekii::Event::Mouse::Button::Right},
          {Asekii::Event::Mouse::Action::Drag,    Asekii::Event::Mouse::Button::Right},
          {Asekii::Event::Mouse::Action::Hover,   Asekii::Event::Mouse::Button::None},
          {Asekii::Event::Mouse::Action::Scroll,  Asekii::Event::Mouse::Button::WheelDown},
          {Asekii::Event::Mouse::Action::Scroll,  Asekii::Event::Mouse::Button::WheelRight},
          {Asekii::Event::Mouse::Action::Press,   Asekii::Event::Mouse::Button::Aux9},
          {Asekii::Event::Mouse::Action::Release, Asekii::Event::Mouse::Button::Aux11},
          {Asekii::Event::Mouse::Action::Press,   Asekii::Event::Mouse::Button::Left},
          {Asekii::Event::Mouse::Action::Leave,   Asekii::Event::Mouse::Button::None},
        ]
        expected.each do |action, button|
          mouse = rig.event(Asekii::Event::Mouse)
          {mouse.action, mouse.button}.should eq({action, button})
        end
      end
    end

    it "converts pixels to cells from the resize report" do
      rig do |rig|
        rig.feed "\e[48;10;20;200;400t\e[<0;45;65M"
        resize = rig.event(Asekii::Event::Resize)
        {resize.rows, resize.cols, resize.height, resize.width}.should eq({10, 20, 200, 400})
        mouse = rig.event(Asekii::Event::Mouse)
        {mouse.col, mouse.row}.should eq({2, 3})
      end
    end

    it "keeps the cell size when the resize report has no pixels" do
      rig do |rig|
        rig.feed "\e[6;20;10t\e[48;10;20;0;0t\e[<0;45;65M"
        resize = rig.event(Asekii::Event::Resize)
        {resize.rows, resize.cols, resize.height, resize.width}.should eq({10, 20, 200, 200})
        mouse = rig.event(Asekii::Event::Mouse)
        {mouse.col, mouse.row}.should eq({4, 3})
      end
    end

    it "converts pixels to cells from the cell size report" do
      rig do |rig|
        rig.feed "\e[6;20;10t\e[<0;45;65M"
        mouse = rig.event(Asekii::Event::Mouse)
        {mouse.col, mouse.row}.should eq({4, 3})
      end
    end

    it "synthesizes clicks and counts multi-clicks within the radius" do
      rig do |rig|
        click = "\e[<0;10;10M\e[<0;11;11m"
        rig.feed click + click + click + "\e[<0;90;90M\e[<0;90;90m" + "\e[<2;90;90M\e[<2;90;90m"
        clicks = Array.new(5) { rig.event(Asekii::Event::MouseGesture, &.kind.click?) }
        clicks.map(&.count).should eq([1, 2, 3, 1, 1])
        clicks.last.mouse.button.should eq(Asekii::Event::Mouse::Button::Right)
      end
    end

    it "does not click when the release is outside the radius or on another button" do
      rig do |rig|
        rig.feed "\e[<0;10;10M\e[<0;30;10m\e[<0;10;10M\e[<1;10;10m#{tap('q')}"
        events = rig.upto { |event| marker?(event, 'q') }
        gestures(events).should_not contain(Asekii::Event::MouseGesture::Kind::Click)
      end
    end

    it "brackets drag reports into start, move and end with a swipe" do
      rig do |rig|
        rig.feed "\e[<0;10;10M\e[<32;30;10M\e[<32;50;14M\e[<0;50;14m#{tap('q')}"
        events = rig.upto { |event| marker?(event, 'q') }
        drags  = events.compact_map(&.as?(Asekii::Event::MouseGesture)).select { |gesture| gesture.kind.drag_start? || gesture.kind.drag_move? || gesture.kind.drag_end? }
        drags.map(&.kind).should eq([Asekii::Event::MouseGesture::Kind::DragStart, Asekii::Event::MouseGesture::Kind::DragMove, Asekii::Event::MouseGesture::Kind::DragEnd])
        drags.map(&.dx).should eq([20, 40, 40])
        drags.last.dy.should eq(4)
        drags.last.direction.should eq(Asekii::Event::Direction::Right)
        swipe = events.compact_map(&.as?(Asekii::Event::MouseGesture)).find!(&.kind.swipe?)
        swipe.velocity.should be > 500.0
        gestures(events).should_not contain(Asekii::Event::MouseGesture::Kind::Click)
      end
    end

    it "infers enter from the first report and after a leave" do
      rig do |rig|
        rig.feed "\e[<35;5;5M\e[<35;6;6M\e[<256;0;0M\e[<35;7;7M#{tap('q')}"
        events = rig.upto { |event| marker?(event, 'q') }
        enters = events.compact_map(&.as?(Asekii::Event::MouseGesture)).select(&.kind.enter?)
        enters.map(&.mouse.x).should eq([5, 7])
      end
    end

    it "reports motion deltas between successive reports" do
      rig do |rig|
        rig.feed "\e[<35;10;10M\e[<35;13;14M"
        motion = rig.event(Asekii::Event::MouseGesture, &.kind.motion?)
        {motion.dx, motion.dy}.should eq({3, 4})
        motion.velocity.should be > 0.0
        motion.direction.should eq(Asekii::Event::Direction::Down)
      end
    end

    it "reports the first wheel step at once and batches the rest until the direction turns" do
      config = plain
      config.scroll_window = 5.seconds
      rig(config) do |rig|
        rig.feed "\e[<64;5;5M\e[<64;5;5M\e[<64;5;5M\e[<65;5;5M"
        first = rig.event(Asekii::Event::MouseGesture, &.kind.scroll?)
        first.count.should eq(1)
        first.velocity.should eq(0.0)
        first.mouse.button.should eq(Asekii::Event::Mouse::Button::WheelUp)
        rest = rig.event(Asekii::Event::MouseGesture, &.kind.scroll?)
        rest.count.should eq(2)
        rest.mouse.button.should eq(Asekii::Event::Mouse::Button::WheelUp)
        down = rig.event(Asekii::Event::MouseGesture, &.kind.scroll?)
        down.count.should eq(1)
        down.velocity.should eq(0.0)
        down.mouse.button.should eq(Asekii::Event::Mouse::Button::WheelDown)
      end
    end

    it "emits one scroll gesture per window while the wheel keeps turning" do
      config = plain
      config.scroll_window = 60.milliseconds
      rig(config) do |rig|
        rig.feed "\e[<64;5;5M"
        rig.event(Asekii::Event::MouseGesture, &.kind.scroll?).count.should eq(1)
        rig.feed "\e[<64;5;5M\e[<64;5;5M"
        started = Time.instant
        batch   = rig.event(Asekii::Event::MouseGesture, &.kind.scroll?)
        batch.count.should eq(2)
        batch.velocity.should be > 0.0
        started.elapsed.should be < 500.milliseconds
      end
    end

    it "bounds the velocity of steps cut short by a turn" do
      config = plain
      config.scroll_window = 5.seconds
      rig(config) do |rig|
        rig.feed "\e[<65;5;5M\e[<65;5;5M\e[<64;5;5M"
        rig.event(Asekii::Event::MouseGesture, &.kind.scroll?).velocity.should eq(0.0)
        cut = rig.event(Asekii::Event::MouseGesture, &.kind.scroll?)
        cut.count.should eq(1)
        cut.mouse.button.should eq(Asekii::Event::Mouse::Button::WheelDown)
        cut.velocity.should be_close(0.2, 0.001)
        rig.event(Asekii::Event::MouseGesture, &.kind.scroll?).mouse.button.should eq(Asekii::Event::Mouse::Button::WheelUp)
      end
    end

    it "measures slow steady scrolling and forgets it after a pause" do
      config = plain
      config.scroll_window = 10.milliseconds
      config.scroll_pause = 400.milliseconds
      rig(config) do |rig|
        rig.feed "\e[<64;5;5M"
        rig.event(Asekii::Event::MouseGesture, &.kind.scroll?).velocity.should eq(0.0)
        sleep 80.milliseconds
        rig.feed "\e[<64;5;5M"
        steady = rig.event(Asekii::Event::MouseGesture, &.kind.scroll?)
        steady.count.should eq(1)
        steady.velocity.should be > 2.5
        steady.velocity.should be < 13.0
        sleep 600.milliseconds
        rig.feed "\e[<64;5;5M"
        rig.event(Asekii::Event::MouseGesture, &.kind.scroll?).velocity.should eq(0.0)
      end
    end

    it "tracks the vertical and the horizontal wheel on their own" do
      config = plain
      config.scroll_window = 60.milliseconds
      rig(config) do |rig|
        rig.feed "\e[<65;5;5M\e[<66;5;5M\e[<65;5;5M\e[<66;5;5M\e[<65;5;5M"
        seen = Array.new(4) { rig.event(Asekii::Event::MouseGesture, &.kind.scroll?) }
        seen.first(2).map(&.mouse.button).should eq([Asekii::Event::Mouse::Button::WheelDown, Asekii::Event::Mouse::Button::WheelLeft])
        seen.first(2).map(&.velocity).should eq([0.0, 0.0])
        down = seen.last(2).find!(&.mouse.button.wheel_down?)
        left = seen.last(2).find!(&.mouse.button.wheel_left?)
        down.count.should eq(2)
        left.count.should eq(1)
        down.velocity.should be > 0.0
        left.velocity.should be > 0.0
      end
    end

    it "detects multi-button chords" do
      rig do |rig|
        rig.feed "\e[<0;5;5M\e[<2;5;5M"
        chord = rig.event(Asekii::Event::MouseGesture, &.kind.chord?)
        chord.count.should eq(2)
        chord.mouse.button.should eq(Asekii::Event::Mouse::Button::Right)
      end
    end

    it "reports a long press when no release follows" do
      config = plain
      config.long_press_after = 20.milliseconds
      rig(config) do |rig|
        rig.feed "\e[<0;5;5M"
        rig.event(Asekii::Event::MouseGesture, &.kind.long_press?).mouse.x.should eq(5)
      end
    end

    it "reports hover dwell and its end when motion resumes" do
      config = plain
      config.hover_dwell_after = 20.milliseconds
      rig(config) do |rig|
        rig.feed "\e[<35;5;5M"
        rig.event(Asekii::Event::MouseGesture, &.kind.hover_dwell?).mouse.x.should eq(5)
        rig.feed "\e[<35;9;9M"
        rig.event(Asekii::Event::MouseGesture, &.kind.hover_end?).mouse.x.should eq(9)
      end
    end

    it "reports a dwell as a plain hover whatever the last report was" do
      config = plain
      config.hover_dwell_after = 20.milliseconds
      rig(config) do |rig|
        rig.feed "\e[<35;5;5M\e[<64;5;5M"
        dwell = rig.event(Asekii::Event::MouseGesture, &.kind.hover_dwell?).mouse
        dwell.action.should eq(Asekii::Event::Mouse::Action::Hover)
        dwell.button.should eq(Asekii::Event::Mouse::Button::None)
        dwell.x.should eq(5)
      end
    end
  end

  describe "terminal notifications" do
    it "reports focus, visibility and color scheme changes" do
      rig do |rig|
        rig.feed "\e[I\e[O\e[?999;1n\e[?999;2n\e[?997;1n\e[?997;2n"
        rig.event(Asekii::Event::Focus).gained.should be_true
        rig.event(Asekii::Event::Focus).gained.should be_false
        rig.event(Asekii::Event::Visibility).visible.should be_true
        rig.event(Asekii::Event::Visibility).visible.should be_false
        rig.event(Asekii::Event::ColorScheme).dark.should be_true
        rig.event(Asekii::Event::ColorScheme).dark.should be_false
      end
    end

    it "sends the visibility and color scheme queries" do
      rig do |rig|
        rig.term.query_visibility
        rig.term.query_color_scheme
        rig.expect("\e[?998n\e[?996n")
      end
    end

    it "queries mode support" do
      rig do |rig|
        rig.ask(/\e\[\?5522\$p/, "\e[?5522;2$y") { rig.term.supports?(5522) }.should be_true
        rig.ask(/\e\[\?2026\$p/, "\e[?2026;0$y") { rig.term.supports?(2026) }.should be_false
        rig.ask(/\e\[\?7\$p/, "\e[?7;4$y") { rig.term.supports?(7) }.should be_false
      end
    end

    it "queries the window and cell size in pixels" do
      rig do |rig|
        window = rig.ask(/\e\[14t/, "\e[4;600;800t") { rig.term.window_size }.not_nil!
        {window.width, window.height}.should eq({800, 600})
        cell = rig.ask(/\e\[16t/, "\e[6;20;10t") { rig.term.cell_size }.not_nil!
        {cell.width, cell.height}.should eq({10, 20})
      end
    end
  end

  describe "pointer shape" do
    it "sets, pushes, pops and resets" do
      rig do |rig|
        (rig.term.pointer = Asekii::Terminal::Shape::NsResize).should eq(Asekii::Terminal::Shape::NsResize)
        rig.term.push_pointer(:wait, :vertical_text)
        rig.term.pop_pointer
        rig.term.reset_pointer
        rig.expect("\e]22;=ns-resize\e\\\e]22;>wait,vertical-text\e\\\e]22;<\e\\\e]22;\e\\")
      end
    end

    it "names all thirty mandatory shapes" do
      names = Asekii::Terminal::Shape.values.map(&.wire)
      names.size.should eq(30)
      names.should contain("nesw-resize")
      names.should contain("not-allowed")
      names.should contain("zoom-out")
      names.all?(&.matches?(/\A[a-z0-9_-]+\z/)).should be_true
    end

    it "queries the current, default and grabbed shapes" do
      rig do |rig|
        rig.ask(/\e\]22;\?__current__\e\\/, osc("22;crosshair")) { rig.term.pointer }.should eq("crosshair")
        rig.ask(/\e\]22;\?__current__\e\\/, osc("22;0")) { rig.term.pointer }.should be_nil
        rig.ask(/\e\]22;\?__default__\e\\/, osc("22;text")) { rig.term.pointer(:default) }.should eq("text")
        rig.ask(/\e\]22;\?__grabbed__\e\\/, "\e]22;grabbing\a") { rig.term.pointer(:grabbed) }.should eq("grabbing")
      end
    end

    it "queries shape support" do
      rig do |rig|
        flags = rig.ask(/\e\]22;\?pointer,crosshair,wait\e\\/, osc("22;1,0,1")) do
          rig.term.pointer_support(:pointer, :crosshair, :wait)
        end
        flags.should eq([true, false, true])
      end
    end
  end

  describe "color control" do
    it "pushes and pops the color stack" do
      rig do |rig|
        rig.term.push_colors
        rig.term.pop_colors
        rig.expect("\e]30001\e\\\e]30101\e\\")
      end
    end

    it "sets, makes dynamic and resets colors" do
      rig do |rig|
        rig.term.color("foreground", "green")
        rig.term.color(1, Asekii::Terminal::Color.rgb(255, 0, 128))
        rig.term.color("transparent_background_color1", Asekii::Terminal::Color.rgb(0, 0, 0, 0.5))
        rig.term.dynamic_color("cursor")
        rig.term.reset_color("background")
        rig.expect("\e]21;foreground=green\e\\\e]21;1=rgb:ffff/0000/8080\e\\\e]21;transparent_background_color1=rgb:0000/0000/0000@0.5\e\\\e]21;cursor=\e\\\e]21;background\e\\")
      end
    end

    it "queries colors, mapping undefined values to nil and dropping unknown keys" do
      rig do |rig|
        colors = rig.ask(/\e\]21;foreground=\?;cursor=\?;7=\?;nonsense=\?\e\\/, osc("21;foreground=rgb:ff/00/00;cursor=;7=#3a7;unknown=bm9uc2Vuc2U")) do
          rig.term.colors("foreground", "cursor", 7, "nonsense")
        end.not_nil!
        colors.keys.should eq(["foreground", "cursor", "7"])
        colors.unknown.should eq(["nonsense"])
        colors.size.should eq(3)
        colors["foreground"].should eq(Asekii::Terminal::Color.new(0xffff, 0, 0))
        colors["cursor"].should be_nil
        colors["7"].should eq(Asekii::Terminal::Color.new(0x3000, 0xa000, 0x7000))
      end
    end

    it "parses the rgb form by scaling each component" do
      Asekii::Terminal::Color.parse("rgb:f/0/8").should eq(Asekii::Terminal::Color.new(0xffff, 0, 0x8888))
      Asekii::Terminal::Color.parse("rgb:FF/80/00").should eq(Asekii::Terminal::Color.new(0xffff, 0x8080, 0))
      Asekii::Terminal::Color.parse("rgb:fff/000/800").should eq(Asekii::Terminal::Color.new(0xffff, 0, 0x8007))
      Asekii::Terminal::Color.parse("rgb:1234/abcd/ffff").should eq(Asekii::Terminal::Color.new(0x1234, 0xabcd, 0xffff))
    end

    it "parses the hash form as most significant bits" do
      Asekii::Terminal::Color.parse("#3a7").should eq(Asekii::Terminal::Color.new(0x3000, 0xa000, 0x7000))
      Asekii::Terminal::Color.parse("#ff0080").should eq(Asekii::Terminal::Color.new(0xff00, 0, 0x8000))
      Asekii::Terminal::Color.parse("#123456789").should eq(Asekii::Terminal::Color.new(0x1230, 0x4560, 0x7890))
      Asekii::Terminal::Color.parse("#111122223333").should eq(Asekii::Terminal::Color.new(0x1111, 0x2222, 0x3333))
    end

    it "parses the rgbi form with clipping, and alpha on any form" do
      Asekii::Terminal::Color.parse("rgbi:1.0/0/2.5").should eq(Asekii::Terminal::Color.new(0xffff, 0, 0xffff))
      Asekii::Terminal::Color.parse("rgbi:-1/1e0/0.0").should eq(Asekii::Terminal::Color.new(0, 0xffff, 0))
      Asekii::Terminal::Color.parse("#ff0000@0.3").should eq(Asekii::Terminal::Color.new(0xff00, 0, 0, 0.3))
      Asekii::Terminal::Color.parse("rgb:ff/00/00@0.1").not_nil!.alpha.should eq(0.1)
    end

    it "rejects values it cannot decode" do
      Asekii::Terminal::Color.parse("").should be_nil
      Asekii::Terminal::Color.parse("not-a-color").should be_nil
      Asekii::Terminal::Color.parse("rgb:gg/00/00").should be_nil
      Asekii::Terminal::Color.parse("rgb:ff/00").should be_nil
      Asekii::Terminal::Color.parse("rgb:fffff/0/0").should be_nil
      Asekii::Terminal::Color.parse("#ff00").should be_nil
      Asekii::Terminal::Color.parse("#ff0000@x").should be_nil
    end

    it "round-trips through its wire form" do
      color = Asekii::Terminal::Color.new(0x1234, 0xabcd, 0x00ff, 0.25)
      color.to_s.should eq("rgb:1234/abcd/00ff@0.25")
      Asekii::Terminal::Color.parse(color.to_s).should eq(color)
    end
  end

  describe "clipboard" do
    it "writes text and reports success" do
      rig do |rig|
        status = rig.ask(/\e\]5522;type=wdata\e\\/, osc("5522;type=write:status=DONE")) { rig.term.copy("hi") }
        status.should eq(Asekii::Terminal::Status::Done)
        rig.seen.should eq("\e]5522;type=write\e\\\e]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\e\\\e]5522;type=wdata\e\\")
      end
    end

    it "sends the password and name when an app name is configured, and the location" do
      config = plain
      config.app_name = "demo"
      rig(config) do |rig|
        rig.ask(/\e\]5522;type=wdata\e\\/, osc("5522;type=write:status=DONE")) { rig.term.copy("x", primary: true) }
        match = rig.seen.match!(/\e\]5522;type=write:loc=primary:pw=([A-Za-z0-9+\/=]+):name=ZGVtbw==\e\\/)
        Base64.decode_string(match[1]).should match(/\A[0-9a-f-]{36}\z/)
      end
    end

    it "chunks large payloads below the limit and sends aliases" do
      rig do |rig|
        data = Bytes.new(9000) { |index| (index % 251).to_u8 }
        rig.ask(/\e\]5522;type=wdata\e\\/, osc("5522;type=write:status=DONE")) do
          rig.term.clipboard_write({"image/png" => data}, {"image/png" => ["image/x-png", "PNG"]})
        end
        chunks = rig.seen.scan(/\e\]5522;type=wdata:mime=aW1hZ2UvcG5n;([^\e]*)\e\\/).map { |match| Base64.decode(match[1]) }
        chunks.size.should eq(3)
        chunks.all? { |chunk| chunk.size <= 4096 }.should be_true
        chunks.reduce(Bytes.empty) { |all, chunk| all + chunk }.should eq(data)
        rig.seen.should contain("\e]5522;type=walias:mime=aW1hZ2UvcG5n;#{b64("image/x-png PNG")}\e\\")
      end
    end

    it "reports write errors" do
      rig do |rig|
        rig.ask(/type=wdata\e\\/, osc("5522;type=write:status=EPERM")) { rig.term.copy("x") }.should eq(Asekii::Terminal::Status::EPERM)
        rig.ask(/type=wdata\e\\/, osc("5522;type=write:status=EFBIG")) { rig.term.copy("x") }.should eq(Asekii::Terminal::Status::EFBIG)
        rig.ask(/type=wdata\e\\/, osc("5522;type=write:status=EWHAT")) { rig.term.copy("x") }.should eq(Asekii::Terminal::Status::EIO)
      end
    end

    it "reads several MIME types delivered in separately padded chunks" do
      rig do |rig|
        reply = osc("5522;type=read:status=OK:id=term") +
                osc("5522;type=read:status=DATA:id=term:mime=#{b64("text/plain")};#{b64("He")}") +
                osc("5522;type=read:status=DATA:id=term:mime=#{b64("text/plain")};#{b64("llo")}") +
                osc("5522;type=read:status=DATA:id=term:mime=#{b64("image/png")};#{b64(Bytes[1, 2, 3])}") +
                osc("5522;type=read:status=DONE:id=term")
        clipboard = rig.ask(/\e\]5522;type=read:id=term;#{Regex.escape(b64("text/plain image/png"))}\e\\/, reply) do
          rig.term.clipboard_read("text/plain", "image/png")
        end.not_nil!
        clipboard.done?.should be_true
        clipboard.text.should eq("Hello")
        clipboard.data["image/png"].should eq(Bytes[1, 2, 3])
      end
    end

    it "reads from the primary selection" do
      rig do |rig|
        reply     = osc("5522;type=read:status=ENOSYS:id=term")
        clipboard = rig.ask(/\e\]5522;type=read:id=term:loc=primary;/, reply) { rig.term.clipboard_read("text/plain", primary: true) }.not_nil!
        clipboard.status.should eq(Asekii::Terminal::Status::ENOSYS)
        clipboard.done?.should be_false
        clipboard.text.should be_nil
      end
    end

    it "lists the available MIME types" do
      rig do |rig|
        reply = osc("5522;type=read:status=OK:id=term") +
                osc("5522;type=read:status=DATA:id=term:mime=Lg==;#{b64(" text/html  text/plain\n")}") +
                osc("5522;type=read:status=DONE:id=term")
        rig.ask(/\e\]5522;type=read:id=term;Lg==\e\\/, reply) { rig.term.clipboard_mimes }.should eq(["text/html", "text/plain"])
      end
    end

    it "turns an unsolicited listing into a paste event and reads with its password" do
      rig do |rig|
        rig.feed osc("5522;type=read:status=OK:loc=primary:pw=c2VjcmV0") +
                 osc("5522;type=read:status=DATA:mime=Lg==:pw=c2VjcmV0;#{b64("text/html text/plain\n")}") +
                 osc("5522;type=read:status=DONE:pw=c2VjcmV0")
        paste = rig.event(Asekii::Event::Paste)
        paste.mimes.should eq(["text/html", "text/plain"])
        paste.primary.should be_true
        paste.password.should eq("c2VjcmV0")
        reply = osc("5522;type=read:status=OK:id=term") +
                osc("5522;type=read:status=DATA:id=term:mime=#{b64("text/html")};#{b64("<b>Bold text</b>")}") +
                osc("5522;type=read:status=DONE:id=term")
        request   = /\e\]5522;type=read:id=term:loc=primary:pw=c2VjcmV0:name=UGFzdGUgZXZlbnQ=;#{Regex.escape(b64("text/html"))}\e\\/
        clipboard = rig.ask(request, reply) { rig.term.clipboard_read(paste, "text/html") }.not_nil!
        String.new(clipboard.data["text/html"]).should eq("<b>Bold text</b>")
      end
    end

    it "ignores a read reply carrying invalid base64" do
      rig do |rig|
        rig.feed osc("5522;type=read:status=OK") + osc("5522;type=read:status=DATA:mime=Lg==;@@@@") + press('a')
        rig.event(Asekii::Event::Key).code.should eq(97)
      end
    end
  end

  describe "graphics" do
    it "transmits a small image in one code and returns the acknowledgement" do
      rig do |rig|
        ack = rig.ask(/\e_G[^\e]*\e\\/, apc("i=7;OK")) { rig.term.image(Asekii::Terminal::Pixels.rgb(Bytes[1, 2, 3], 1, 1), id: 7) }.not_nil!
        rig.last.should eq("\e_Ga=t,i=7,f=24,t=d,s=1,v=1;AQID\e\\")
        ack.ok?.should be_true
        ack.error.should be_nil
        ack.image.should eq(7)
      end
    end

    it "transmits and displays with every placement key" do
      rig do |rig|
        placement = Asekii::Terminal::Placement.new(id: 3, x: 1, y: 2, width: 3, height: 4, offset_x: 5, offset_y: 6, columns: 7, rows: 8, z: -9, hold_cursor: true, placeholder: true, parent: 10, parent_placement: 11, shift_x: 12, shift_y: -13)
        rig.term.image(Asekii::Terminal::Pixels.png(Bytes[9]), placement: placement, transient: true).should be_nil
        rig.expect("\e_Ga=T,N=1,f=100,t=d,p=3,x=1,y=2,w=3,h=4,X=5,Y=6,c=7,r=8,z=-9,C=1,U=1,P=10,Q=11,H=12,V=-13;CQ==\e\\")
      end
    end

    it "chunks large direct data with only m on continuation chunks" do
      rig do |rig|
        data = Bytes.new(4 * 40 * 40) { |index| (index % 253).to_u8 }
        rig.ask(/\e_Ga=t,i=5.*?m=0;[^\e]*\e\\/m, apc("i=5;OK")) { rig.term.image(Asekii::Terminal::Pixels.rgba(data, 40, 40), id: 5) }
        codes = rig.last.scan(/\e_G([^;]*);([^\e]*)\e\\/)
        codes.map(&.[1]).should eq(["a=t,i=5,f=32,t=d,s=40,v=40,m=1", "m=1", "m=0"])
        codes.map(&.[2].bytesize).should eq([4096, 4096, 344])
        Base64.decode(codes.join(&.[2])).should eq(data)
      end
    end

    it "does not wait when responses are suppressed or no id is given" do
      rig do |rig|
        data = Bytes.new(4000, 1_u8)
        rig.term.image(Asekii::Terminal::Pixels.rgb(data, 40, 25), id: 5, quiet: :all).should be_nil
        rig.term.image(Asekii::Terminal::Pixels.rgb(Bytes[1, 2, 3], 1, 1)).should be_nil
        rig.expect("\e_Ga=t,f=24,t=d,s=1,v=1;AQID\e\\")
        codes = rig.seen.scan(/\e_G([^;]*);/).map(&.[1])
        codes.should eq(["a=t,i=5,q=2,f=24,t=d,s=40,v=25,m=1", "q=2,m=0", "a=t,f=24,t=d,s=1,v=1"])
      end
    end

    it "compresses direct data and requests an id through an image number" do
      rig do |rig|
        data = Bytes.new(500, 7_u8)
        ack  = rig.ask(/\e_Ga=t,I=13[^\e]*\e\\/, apc("i=99,I=13;OK")) { rig.term.image(Asekii::Terminal::Pixels.png(data, compress: true), number: 13) }.not_nil!
        {ack.image, ack.number}.should eq({99, 13})
        match = rig.last.match!(/\e_G([^;]*);([^\e]*)\e\\/)
        match[1].should eq("a=t,I=13,f=100,t=d,S=500,o=z")
        Compress::Zlib::Reader.open(IO::Memory.new(Base64.decode(match[2])), &.getb_to_end).should eq(data)
      end
    end

    it "sends paths for file, temporary file and shared memory media" do
      rig do |rig|
        rig.term.image(Asekii::Terminal::Pixels.at("/path/to/file.png"), quiet: :all)
        rig.term.image(Asekii::Terminal::Pixels.at("/tmp/tty-graphics-protocol-x", :temp_file, :rgb, 10, 20), quiet: :ok)
        rig.term.image(Asekii::Terminal::Pixels.at("/some-shared-memory-name", :shared_memory, :rgba, 10, 2, compress: true, size: 80, offset: 10))
        rig.expect("\e_Ga=t,q=2,f=100,t=f;#{b64("/path/to/file.png")}\e\\" \
                   "\e_Ga=t,q=1,f=24,t=t,s=10,v=20;#{b64("/tmp/tty-graphics-protocol-x")}\e\\" \
                   "\e_Ga=t,f=32,t=s,s=10,v=2,S=80,O=10,o=z;#{b64("/some-shared-memory-name")}\e\\")
      end
    end

    it "places an image and returns the terminal's error" do
      rig do |rig|
        ack = rig.ask(/\e_Ga=p[^\e]*\e\\/, apc("i=9,p=3;ENOENT:image not found")) do
          rig.term.place(id: 9, placement: Asekii::Terminal::Placement.new(id: 3, columns: 4, rows: 2, placeholder: true))
        end.not_nil!
        rig.last.should eq("\e_Ga=p,i=9,p=3,c=4,r=2,U=1\e\\")
        ack.ok?.should be_false
        ack.error.should eq("ENOENT:image not found")
        ack.placement.should eq(3)
      end
    end

    it "builds relative placements by image number" do
      rig do |rig|
        rig.ask(/\e_Ga=p[^\e]*\e\\/, apc("i=4,I=2,p=1;OK")) do
          rig.term.place(number: 2, placement: Asekii::Terminal::Placement.new(id: 1, parent: 8, parent_placement: 9, shift_x: -1, shift_y: 2))
        end.not_nil!.image.should eq(4)
        rig.last.should eq("\e_Ga=p,I=2,p=1,P=8,Q=9,H=-1,V=2\e\\")
      end
    end

    it "routes interleaved acknowledgements to the matching request" do
      rig do |rig|
        results = Channel({Int32, Asekii::Event::Ack?}).new(2)
        spawn { results.send({1, rig.term.place(id: 1)}) }
        spawn { results.send({2, rig.term.place(id: 2)}) }
        rig.expect(/\e_Ga=p,i=\d\e\\\e_Ga=p,i=\d\e\\/)
        rig.feed apc("i=2;EINVAL") + apc("i=1;OK")
        acks = {results.receive, results.receive}.to_h
        acks[1].not_nil!.message.should eq("OK")
        acks[2].not_nil!.message.should eq("EINVAL")
      end
    end

    it "deletes by every documented target" do
      rig do |rig|
        rig.term.delete_images
        rig.term.delete_images(:id, id: 10)
        rig.term.delete_images(:id, id: 10, placement: 7)
        rig.term.delete_images(:z, free: true, z: -1)
        rig.term.delete_images(:cell, x: 3, y: 4)
        rig.term.delete_images(:number, free: true, number: 13)
        rig.term.delete_images(:range, x: 2, y: 9)
        rig.term.delete_images(:cell_z, free: true, x: 3, y: 4, z: 5)
        rig.term.delete_images(:frames, id: 2)
        rig.expect("\e_Ga=d,d=a\e\\\e_Ga=d,d=i,i=10\e\\\e_Ga=d,d=i,i=10,p=7\e\\\e_Ga=d,d=Z,z=-1\e\\\e_Ga=d,d=p,x=3,y=4\e\\\e_Ga=d,d=N,I=13\e\\\e_Ga=d,d=r,x=2,y=9\e\\\e_Ga=d,d=Q,x=3,y=4,z=5\e\\\e_Ga=d,d=f,i=2\e\\")
        Asekii::Terminal::DELETES.values.sort.join.should eq("acfinpqrxyz")
      end
    end

    it "builds placement and delete codes that match what the methods send" do
      rig do |rig|
        layout = Asekii::Terminal::Placement.new(id: 3, columns: 4, rows: 2, z: -1)
        Asekii::Terminal.place_code(id: 9, placement: layout, quiet: :all).should eq("\e_Ga=p,i=9,q=2,p=3,c=4,r=2,z=-1\e\\")
        Asekii::Terminal.place_code(number: 2).should eq("\e_Ga=p,I=2\e\\")
        Asekii::Terminal.delete_code.should eq("\e_Ga=d,d=a\e\\")
        Asekii::Terminal.delete_code(:id, free: true, id: 10, placement: 7).should eq("\e_Ga=d,d=I,i=10,p=7\e\\")
        rig.term.place(id: 9, placement: layout, quiet: :all)
        rig.term.delete_images(:id, free: true, id: 10, placement: 7)
        rig.expect(Asekii::Terminal.place_code(id: 9, placement: layout, quiet: :all) + Asekii::Terminal.delete_code(:id, free: true, id: 10, placement: 7))
      end
    end

    it "transmits animation frames and keeps a=f on continuation chunks" do
      rig do |rig|
        rig.term.frame(Asekii::Terminal::Pixels.rgb(Bytes.new(3), 1, 1), id: 5, x: 1, y: 2, base: 3, edit: 4, gap: -1, replace: true, background: 4278190335, quiet: :all)
        rig.expect("\e_Ga=f,i=5,q=2,x=1,y=2,c=3,r=4,z=-1,X=1,Y=4278190335,f=24,t=d,s=1,v=1;AAAA\e\\")
        ack = rig.ask(/\e_Ga=f,I=3.*?m=0;[^\e]*\e\\/m, apc("i=8,I=3;OK")) { rig.term.frame(Asekii::Terminal::Pixels.rgb(Bytes.new(3600), 40, 30), number: 3, gap: 40) }.not_nil!
        ack.image.should eq(8)
        rig.last.scan(/\e_G([^;]*);/).map(&.[1]).should eq(["a=f,I=3,z=40,f=24,t=d,s=40,v=30,m=1", "a=f,m=0"])
      end
    end

    it "controls animations without waiting, since success is not acknowledged" do
      rig do |rig|
        rig.term.animate(id: 3, current: 7).should be_nil
        rig.term.animate(id: 7, target: 3, gap: 48)
        rig.term.animate(number: 2, state: :loop, loops: 1)
        rig.term.animate(id: 2, state: Asekii::Terminal::Playback::Stop, quiet: :all)
        rig.term.animate(id: 2, state: Asekii::Terminal::Playback::Loading)
        rig.expect("\e_Ga=a,i=3,c=7\e\\\e_Ga=a,i=7,r=3,z=48\e\\\e_Ga=a,I=2,s=3,v=1\e\\\e_Ga=a,i=2,q=2,s=1\e\\\e_Ga=a,i=2,s=2\e\\")
      end
    end

    it "composes frames and returns the acknowledgement" do
      rig do |rig|
        rig.term.compose(7, 9, id: 1, width: 23, height: 27, source_x: 4, source_y: 8, x: 1, y: 3, replace: true, quiet: :all).should be_nil
        rig.expect("\e_Ga=c,i=1,q=2,r=7,c=9,w=23,h=27,X=4,Y=8,x=1,y=3,C=1\e\\")
        rig.ask(/\e_Ga=c,i=1,r=1,c=2\e\\/, apc("i=1;OK")) { rig.term.compose(1, 2, id: 1) }.not_nil!.ok?.should be_true
        rig.ask(/\e_Ga=c,i=1,r=1,c=2\e\\/, apc("i=1;ENOENT")) { rig.term.compose(1, 2, id: 1) }.not_nil!.error.should eq("ENOENT")
      end
    end

    it "delivers acknowledgements nobody is waiting for as events" do
      rig do |rig|
        rig.term.animate(id: 404, current: 2)
        rig.expect("\e_Ga=a,i=404,c=2\e\\")
        rig.feed apc("i=404;ENOENT:Animation command refers to non-existent image")
        ack = rig.event(Asekii::Event::Ack)
        {ack.image, ack.ok?}.should eq({404, false})
        ack.error.not_nil!.should start_with("ENOENT")
      end
    end

    it "streams image data from an IO in bounded chunks" do
      rig do |rig|
        data = Bytes.new(3072 * 2) { |index| (index % 241).to_u8 }
        rig.ask(/\e_Ga=t,i=6.*?m=0;[^\e]*\e\\/m, apc("i=6;OK")) { rig.term.image(Asekii::Terminal::Pixels.rgb(IO::Memory.new(data), 64, 32), id: 6) }.not_nil!.ok?.should be_true
        codes = rig.last.scan(/\e_G([^;]*);([^\e]*)\e\\/)
        codes.map(&.[1]).should eq(["a=t,i=6,f=24,t=d,s=64,v=32,m=1", "m=0"])
        codes.map(&.[2].bytesize).should eq([4096, 4096])
        Base64.decode(codes.join(&.[2])).should eq(data)
      end
    end

    it "keeps concurrent chunked uploads from interleaving" do
      rig do |rig|
        done = Channel(Nil).new
        {1_u32, 2_u32}.each do |id|
          spawn do
            rig.term.image(Asekii::Terminal::Pixels.rgb(Bytes.new(3072 * 5, id.to_u8), 64, 80), id: id, quiet: :all)
            done.send(nil)
          end
        end
        2.times { done.receive }
        rig.term.print "END"
        rig.expect("END")
        heads = rig.seen.scan(/\e_G([^;]*);(.)/).map { |match| {match[1], match[2]} }
        heads.size.should eq(10)
        heads.each_slice(5) do |group|
          group.first[0].should start_with("a=t,i=")
          group[1..].map(&.[0]).should eq(["q=2,m=1", "q=2,m=1", "q=2,m=1", "q=2,m=0"])
          group.map(&.[1]).uniq.size.should eq(1)
        end
      end
    end

    it "writes temporary files and shared memory objects for local transmission" do
      data = Bytes[1, 2, 3, 4, 5]
      temp = Asekii::Terminal::Pixels.temp(data, :rgb, 1, 1)
      path = String.new(temp.data.as(Bytes))
      begin
        temp.medium.should eq(Asekii::Terminal::Medium::TempFile)
        path.should contain("tty-graphics-protocol")
        path.should start_with(Dir.tempdir)
        File.read(path).to_slice.should eq(data)
      ensure
        File.delete?(path)
      end
      {% if flag?(:linux) %}
        shared = Asekii::Terminal::Pixels.shared(data, :rgba, 1, 1)
        name = String.new(shared.data.as(Bytes))
        begin
          shared.medium.should eq(Asekii::Terminal::Medium::SharedMemory)
          name.should match(/\A\/[^\/]+\z/)
          File.read("/dev/shm#{name}").to_slice.should eq(data)
        ensure
          File.delete?("/dev/shm#{name}")
        end
      {% end %}
    end

    it "builds compact placeholder rows that rely on inheritance" do
      Asekii::Terminal.placeholder(42, 3, 2, compact: true).should eq([
        "\e[38;2;0;0;42m\u{10EEEE}\u0305\u{10EEEE}\u{10EEEE}\e[39m",
        "\e[38;2;0;0;42m\u{10EEEE}\u030D\u{10EEEE}\u{10EEEE}\e[39m",
      ])
      Asekii::Terminal.placeholder(33554474, 2, 1, compact: true).should eq(["\e[38;2;0;0;42m\u{10EEEE}\u0305\u0305\u030E\u{10EEEE}\e[39m"])
    end

    it "detects support when the query is answered before device attributes" do
      rig do |rig|
        rig.ask(/\e_Ga=q,i=31,f=24,t=d,s=1,v=1;AAAA\e\\\e\[c/, apc("i=31;OK") + DA1) { rig.term.supports_graphics? }.should be_true
        rig.ask(/\e_Ga=q,i=31[^\e]*\e\\\e\[c/, apc("i=31;OK") + DA1) { rig.term.supports_graphics? }.should be_true
      end
    end

    it "detects no support when device attributes arrive first" do
      rig do |rig|
        rig.ask(/\e_Ga=q,i=31[^\e]*\e\\\e\[c/, DA1) { rig.term.supports_graphics? }.should be_false
        rig.ask(/\e_Ga=q,i=31[^\e]*\e\\\e\[c/, apc("i=31;EINVAL:nope") + DA1) { rig.term.supports_graphics? }.should be_false
        rig.ask(/\e_Ga=q,i=31[^\e]*\e\\\e\[c/, apc("i=31;OK") + DA1) { rig.term.supports_graphics? }.should be_true
      end
    end

    it "detects indexed pixel support with a one-pixel palette query" do
      rig do |rig|
        rig.ask(/\e_Ga=q,i=31,f=8,t=d,s=1,v=1;AA==\e\\\e\[c/, apc("i=31;OK") + DA1) { rig.term.supports_indexed? }.should be_true
        rig.ask(/\e_Ga=q,i=31,f=8[^\e]*\e\\\e\[c/, apc("i=31;EINVAL:unknown format") + DA1) { rig.term.supports_indexed? }.should be_false
      end
    end

    it "encodes graphics commands without sending them" do
      rig do |rig|
        rig.term.frame_code(Asekii::Terminal::Pixels.rgba(Bytes.new(4), 1, 1), id: 5, x: 2, edit: 1, replace: true)
          .should eq("\e_Ga=f,i=5,q=2,x=2,r=1,X=1,f=32,t=d,s=1,v=1;AAAAAA==\e\\")
        rig.term.image_code(Asekii::Terminal::Pixels.rgb(Bytes.new(3), 1, 1), id: 6, quiet: Asekii::Terminal::Quiet::Ok)
          .should eq("\e_Ga=t,i=6,q=1,f=24,t=d,s=1,v=1;AAAA\e\\")
        Asekii::Terminal.compose_code(1, 2, id: 5, width: 3, replace: true).should eq("\e_Ga=c,i=5,q=2,r=1,c=2,w=3,C=1\e\\")
        Asekii::Terminal.animate_code(id: 5, current: 2).should eq("\e_Ga=a,i=5,q=2,c=2\e\\")
      end
    end

    it "returns the load result of an image query" do
      rig do |rig|
        ack = rig.ask(/\e_Ga=q,i=44,f=100,t=s;[^\e]*\e\\\e\[c/, apc("i=44;EBADF:Failed to read image file") + DA1) do
          rig.term.image_query(Asekii::Terminal::Pixels.at("/name", :shared_memory), id: 44)
        end.not_nil!
        ack.error.should eq("EBADF:Failed to read image file")
      end
    end

    it "builds Unicode placeholder rows" do
      rows = Asekii::Terminal.placeholder(42, 2, 2)
      rows.should eq([
        "\e[38;2;0;0;42m\u{10EEEE}̅̅\u{10EEEE}̅̍\e[39m",
        "\e[38;2;0;0;42m\u{10EEEE}̍̅\u{10EEEE}̍̍\e[39m",
      ])
    end

    it "carries the high id byte in a third diacritic and the placement in the underline color" do
      Asekii::Terminal.placeholder(33554474, 1, 1, 0x010203).should eq(["\e[38;2;0;0;42m\e[58;2;1;2;3m\u{10EEEE}̅̅̎\e[39m\e[59m"])
      Asekii::Terminal.placeholder(0x00abcdef, 1, 3).last.should eq("\e[38;2;171;205;239m\u{10EEEE}̎̅\e[39m")
      Asekii::UnicodePlaceholder::DIACRITICS.size.should eq(297)
      Asekii::UnicodePlaceholder::DIACRITICS.first(4).should eq([0x0305, 0x030d, 0x030e, 0x0310])
      Asekii::UnicodePlaceholder::DIACRITICS.uniq.size.should eq(297)
    end
  end

  describe "desktop notifications" do
    it "sends a one-shot notification and returns its generated id" do
      rig do |rig|
        id = rig.term.notify("Hello world")
        rig.expect(/\e\]99;i=([0-9a-f-]{36}):e=1;#{Regex.escape(b64("Hello world"))}\e\\/)[1].should eq(id)
      end
    end

    it "sends every option, then body, buttons and icon data with the done flag last" do
      rig do |rig|
        icon = Bytes.new(3000) { |index| (index % 200).to_u8 }
        id   = rig.term.notify("Title", "Body", id: "n1", report: true, closes: true, app: "demo", types: ["im", "email"], icons: ["info", "demo"], icon: icon, icon_key: "k1", buttons: ["Yes", "No"], sound: "silent", urgency: Asekii::Terminal::Urgency::Critical, expires: 5.seconds, occasion: Asekii::Terminal::Occasion::Invisible)
        id.should eq("n1")
        rig.expect(/\e\]99;i=n1:p=icon:e=1:g=k1;[^\e]*\e\\/)
        codes = rig.seen.scan(/\e\]99;([^;]*);([^\e]*)\e\\/).map { |match| {match[1], match[2]} }
        codes.map(&.[0]).should eq([
          "i=n1:a=report,focus:c=1:f=#{b64("demo")}:t=#{b64("im")}:t=#{b64("email")}:n=#{b64("info")}:n=#{b64("demo")}:g=k1:o=invisible:s=#{b64("silent")}:u=2:w=5000:e=1:d=0",
          "i=n1:p=body:e=1:d=0",
          "i=n1:p=buttons:e=1:d=0",
          "i=n1:p=icon:e=1:g=k1:d=0",
          "i=n1:p=icon:e=1:g=k1",
        ])
        Base64.decode_string(codes[0][1]).should eq("Title")
        Base64.decode_string(codes[1][1]).should eq("Body")
        Base64.decode_string(codes[2][1]).should eq("Yes No")
        chunks = codes[3..].map { |code| Base64.decode(code[1]) }
        chunks.map(&.size).should eq([2048, 952])
        (chunks[0] + chunks[1]).should eq(icon)
      end
    end

    it "encodes the action set" do
      rig do |rig|
        rig.term.notify("a", id: "x", focus: false)
        rig.term.notify("a", id: "y", focus: false, report: true)
        rig.term.notify("a", id: "z", expires: Time::Span.zero, urgency: Asekii::Terminal::Urgency::Low)
        rig.expect("\e]99;i=x:a=-focus:e=1;YQ==\e\\\e]99;i=y:a=report,-focus:e=1;YQ==\e\\\e]99;i=z:u=0:w=0:e=1;YQ==\e\\")
      end
    end

    it "chunks long text on character boundaries" do
      rig do |rig|
        title = "a" + "é" * 1500
        rig.term.notify(title, id: "long")
        rig.expect(/\e\]99;i=long:e=1;[^\e]*\e\\/)
        codes = rig.seen.scan(/\e\]99;([^;]*);([^\e]*)\e\\/).map { |match| {match[1], Base64.decode(match[2])} }
        codes.map(&.[0]).should eq(["i=long:e=1:d=0", "i=long:e=1"])
        codes.map(&.[1].size).should eq([2047, 954])
        codes.all? { |code| String.new(code[1]).valid_encoding? }.should be_true
        codes.join { |code| String.new(code[1]) }.should eq(title)
      end
    end

    it "sends an empty notice, a cached icon reference and a close request" do
      rig do |rig|
        rig.term.notify(Asekii::Terminal::Notice.new(id: "e"))
        rig.term.notify(Asekii::Terminal::Notice.new(body: "only body", id: "b", icon_key: "k1"))
        rig.term.close_notification("b")
        rig.expect("\e]99;i=e;\e\\\e]99;i=b:g=k1:p=body:e=1;#{b64("only body")}\e\\\e]99;i=b:p=close;\e\\")
      end
    end

    it "reports activation, button and close events" do
      rig do |rig|
        rig.feed osc("99;i=n1;") + osc("99;i=n1;2") + osc("99;i=n1:p=close;") + osc("99;i=n2:p=close;untracked") + osc("99;;")
        activated = rig.event(Asekii::Event::Notification)
        {activated.kind, activated.id, activated.button}.should eq({Asekii::Event::Notification::Kind::Activated, "n1", 0})
        button = rig.event(Asekii::Event::Notification)
        {button.kind, button.button}.should eq({Asekii::Event::Notification::Kind::Button, 2})
        closed = rig.event(Asekii::Event::Notification)
        {closed.kind, closed.untracked}.should eq({Asekii::Event::Notification::Kind::Closed, false})
        untracked = rig.event(Asekii::Event::Notification)
        {untracked.id, untracked.untracked}.should eq({"n2", true})
        rig.event(Asekii::Event::Notification).id.should eq("0")
      end
    end

    it "queries live notifications" do
      rig do |rig|
        reply = ->(match : Regex::MatchData) { osc("99;i=#{match[1]}:p=alive;id1,id2,id3") }
        rig.ask(/\e\]99;i=([^:]+):p=alive;\e\\/, reply) { rig.term.notifications_alive }.should eq(["id1", "id2", "id3"])
        empty = ->(match : Regex::MatchData) { osc("99;i=#{match[1]}:p=alive;") }
        rig.ask(/\e\]99;i=([^:]+):p=alive;\e\\/, empty) { rig.term.notifications_alive }.should eq([] of String)
      end
    end

    it "queries support and reports none when device attributes arrive first" do
      rig do |rig|
        reply = ->(match : Regex::MatchData) { osc("99;i=#{match[1]}:p=?;a=report,focus:c=1:o=always:p=title,body,icon:s=system,silent:u=0,1,2:w=1") + DA1 }
        support = rig.ask(/\e\]99;i=([^:]+):p=\?;\e\\\e\[c/, reply) { rig.term.notification_support }.not_nil!
        support["a"].should eq(["report", "focus"])
        support["p"].should eq(["title", "body", "icon"])
        support["u"].should eq(["0", "1", "2"])
        support["w"].should eq(["1"])
        rig.ask(/\e\]99;i=([^:]+):p=\?;\e\\\e\[c/, DA1) { rig.term.notification_support }.should be_nil
      end
    end
  end

  describe "drag and drop" do
    it "starts and stops accepting drops, and stops on close" do
      reader, feed = IO.pipe
      screen, writer = IO.pipe
      term = Asekii::Terminal.new(plain, reader, writer)
      term.accept_drops
      term.accept_drops("text/plain", "application/x-private")
      term.stop_drops
      term.accept_drops
      term.offer_drags
      feed.close
      term.close
      writer.close
      screen.gets_to_end.should eq(SETUP + "\e]72;t=a\e\\\e]72;t=a;text/plain application/x-private\e\\\e]72;t=A\e\\\e]72;t=a\e\\\e]72;t=o:x=1\e\\\e]72;t=A\e\\\e]72;t=o:x=2\e\\" + TEARDOWN)
    end

    it "hashes the machine id and sends it for remote drops and drags" do
      path = "/etc/machine-id"
      if File.exists?(path)
        expected = "1:#{OpenSSL::HMAC.hexdigest(:sha256, "tty-dnd-protocol-machine-id", File.read(path).rstrip)}"
        Asekii::Terminal.machine_id.should eq(expected)
        expected.should match(/\A1:[0-9a-f]{64}\z/)
        rig do |rig|
          rig.term.accept_drops("text/uri-list", remote: true)
          rig.term.offer_drags(remote: true)
          rig.expect("\e]72;t=a;text/uri-list\e\\\e]72;t=a:x=1;#{expected}\e\\\e]72;t=o:x=1;#{expected}\e\\")
        end
      else
        Asekii::Terminal.machine_id.should be_nil
      end
    end

    it "adds the multiplexer id to every code" do
      config = plain
      config.dnd_id = 7
      rig(config) do |rig|
        rig.term.accept_drops
        rig.term.drop_reply(:move)
        rig.term.drag_presend(1, "hi".to_slice)
        rig.expect("\e]72;t=a:i=7\e\\\e]72;t=m:o=2:i=7\e\\\e]72;t=p:x=1:i=7:m=1;aGk=\e\\\e]72;t=p:x=1:i=7:m=0\e\\")
      end
    end

    it "reports drop moves, leaves and the drop itself" do
      rig do |rig|
        rig.feed osc("72;t=m:x=1:y=2:X=10:Y=20:o=3;text/uri-list text/plain") + osc("72;t=m:x=2:y=2:X=30:Y=20:o=3") + osc("72;t=m:x=-1:y=-1") + osc("72;t=M:x=4:y=5:X=40:Y=50:o=1;text/uri-list")
        move = rig.event(Asekii::Event::Drop)
        {move.kind, move.col, move.row, move.x, move.y}.should eq({Asekii::Event::Drop::Kind::Move, 1, 2, 10, 20})
        move.operations.should eq(Asekii::Event::Operation::Copy | Asekii::Event::Operation::Move)
        move.mimes.should eq(["text/uri-list", "text/plain"])
        rig.event(Asekii::Event::Drop).mimes.should be_nil
        leave = rig.event(Asekii::Event::Drop)
        {leave.kind, leave.col, leave.row}.should eq({Asekii::Event::Drop::Kind::Leave, -1, -1})
        land = rig.event(Asekii::Event::Drop)
        {land.kind, land.col, land.row, land.operations}.should eq({Asekii::Event::Drop::Kind::Land, 4, 5, Asekii::Event::Operation::Copy})
        land.mimes.should eq(["text/uri-list"])
      end
    end

    it "assembles a chunked MIME list using the first chunk's metadata" do
      rig do |rig|
        rig.feed osc("72;t=m:x=1:y=2:o=2:m=1;text/pl") + osc("72;m=1;ain image") + osc("72;m=0;/png")
        move = rig.event(Asekii::Event::Drop)
        {move.col, move.row, move.operations}.should eq({1, 2, Asekii::Event::Operation::Move})
        move.mimes.should eq(["text/plain", "image/png"])
      end
    end

    it "accepts, rejects and finishes drops" do
      rig do |rig|
        rig.term.drop_reply(:copy, "text/uri-list", "text/plain")
        rig.term.drop_reply
        rig.term.drop_close(5)
        rig.term.drop_finish(:move)
        rig.term.drop_finish
        rig.expect("\e]72;t=m:o=1;text/uri-list text/plain\e\\\e]72;t=m\e\\\e]72;t=r:Y=5\e\\\e]72;t=r:o=2\e\\\e]72;t=r:o=0\e\\")
      end
    end

    it "reads dropped data sent in unpadded chunks and sees the remote flag" do
      rig do |rig|
        encoded = b64("file:///a\r\n#comment\r\nfile:///d/\r\n").rstrip('=')
        reply   = osc("72;t=r:x=1:X=1:m=1;#{encoded[0, 10]}") + osc("72;t=r:x=1:m=1;#{encoded[10..]}") + osc("72;t=r:x=1;")
        data    = rig.ask(/\e\]72;t=r:x=1\e\\/, reply) { rig.term.drop_data(1) }.not_nil!
        data.ok?.should be_true
        data.remote?.should be_true
        data.symlink?.should be_false
        data.uris.should eq(["file:///a", "file:///d/"])
      end
    end

    it "reads a single unchunked response and reports errors" do
      rig do |rig|
        data = rig.ask(/\e\]72;t=r:x=2\e\\/, osc("72;t=r:x=2;#{b64("plain")}")) { rig.term.drop_data(2) }.not_nil!
        data.text.should eq("plain")
        data.remote?.should be_false
        failed = rig.ask(/\e\]72;t=r:x=3\e\\/, osc("72;t=R:x=3;EPERM:not dropped yet")) { rig.term.drop_data(3) }.not_nil!
        failed.ok?.should be_false
        failed.error.should eq("EPERM:not dropped yet")
        failed.data.should be_empty
      end
    end

    it "reads remote files, symlinks and directories" do
      rig do |rig|
        file = rig.ask(/\e\]72;t=r:x=1:y=1\e\\/, osc("72;t=r:x=1:y=1:X=0:m=1;#{b64("data")}") + osc("72;t=r:x=1:y=1;")) { rig.term.drop_data(1, 1) }.not_nil!
        {file.text, file.symlink?, file.directory?}.should eq({"data", false, false})
        link = rig.ask(/\e\]72;t=r:x=1:y=2\e\\/, osc("72;t=r:x=1:y=2:X=1;#{b64("target")}")) { rig.term.drop_data(1, 2) }.not_nil!
        {link.text, link.symlink?, link.remote?}.should eq({"target", true, false})
        dir = rig.ask(/\e\]72;t=r:x=1:y=3\e\\/, osc("72;t=r:x=1:y=3:X=5;#{b64("a\0b\0sub")}")) { rig.term.drop_data(1, 3) }.not_nil!
        {dir.directory?, dir.handle, dir.entries}.should eq({true, 5, ["a", "b", "sub"]})
        child = rig.ask(/\e\]72;t=r:Y=5:x=3\e\\/, osc("72;t=r:Y=5:x=3:X=6;#{b64("c")}")) { rig.term.drop_entry(5, 3) }.not_nil!
        {child.directory?, child.handle, child.entries}.should eq({true, 6, ["c"]})
        gone = rig.ask(/\e\]72;t=r:Y=5:x=2\e\\/, osc("72;t=R:Y=5:x=2;ENOENT")) { rig.term.drop_entry(5, 2) }.not_nil!
        gone.error.should eq("ENOENT")
      end
    end

    it "matches interleaved responses to their requests" do
      rig do |rig|
        results = Channel({Int32, String?}).new(2)
        spawn { results.send({1, rig.term.drop_data(1, 1).try(&.text)}) }
        spawn { results.send({2, rig.term.drop_data(1, 2).try(&.text)}) }
        rig.expect(/\e\]72;t=r:x=1:y=\d\e\\\e\]72;t=r:x=1:y=\d\e\\/)
        rig.feed osc("72;t=r:x=1:y=2:m=1;#{b64("two")}") + osc("72;t=r:x=1:y=1:m=1;#{b64("one")}") + osc("72;t=r:x=1:y=2;") + osc("72;t=r:x=1:y=1;")
        {results.receive, results.receive}.to_h.should eq({1 => "one", 2 => "two"})
      end
    end

    it "offers drags and reports the start gesture" do
      rig do |rig|
        rig.term.offer_drags
        rig.term.stop_drags
        rig.expect("\e]72;t=o:x=1\e\\\e]72;t=o:x=2\e\\")
        rig.feed osc("72;t=o:x=3:y=4:X=30:Y=40")
        gesture = rig.event(Asekii::Event::Drag)
        {gesture.kind, gesture.col, gesture.row, gesture.x, gesture.y}.should eq({Asekii::Event::Drag::Kind::Gesture, 3, 4, 30, 40})
      end
    end

    it "sends the offer, chunking a long MIME list" do
      rig do |rig|
        rig.term.drag_offer(Asekii::Event::Operation::Copy | Asekii::Event::Operation::Move, "text/plain", "text/uri-list")
        rig.expect("\e]72;t=o:o=3;text/plain text/uri-list\e\\")
        mimes = {"a/" + "a" * 1500, "b/" + "b" * 1500, "c/" + "c" * 1500}
        rig.term.drag_offer(Asekii::Event::Operation::Copy, *mimes)
        rig.expect(/\e\]72;t=o:o=1;[^\e]*\e\\/)
        codes = rig.seen.scan(/\e\]72;([^;]*);([^\e]*)\e\\/).map { |match| {match[1], match[2]} }
        codes.map(&.[0]).should eq(["t=o:o=1:m=1", "t=o:o=1"])
        codes[0][1].bytesize.should eq(4096)
        codes.join(&.[1]).should eq(mimes.join(' '))
      end
    end

    it "pre-sends data as a stream ended by an empty chunk" do
      rig do |rig|
        data = Bytes.new(5000) { |index| (index % 199).to_u8 }
        rig.term.drag_presend(0, data)
        rig.expect("\e]72;t=p:m=0\e\\")
        codes = rig.seen.scan(/\e\]72;([^;\e]*);([^\e]*)\e\\/).map { |match| {match[1], match[2]} }
        codes.map(&.[0]).should eq(["t=p:m=1", "t=p:m=1"])
        codes.map(&.[1].bytesize).should eq([4096, 2572])
        Base64.decode(codes.join(&.[1])).should eq(data)
        rig.term.drag_presend(2, "hi".to_slice)
        rig.expect("\e]72;t=p:x=2:m=1;aGk=\e\\\e]72;t=p:x=2:m=0\e\\")
      end
    end

    it "sends drag images, text images and image changes" do
      rig do |rig|
        rig.term.drag_image(1, Bytes[1, 2, 3, 4], :rgba, 1, 1)
        rig.term.drag_image(2, Bytes[9], :png, 16, 16)
        rig.term.drag_text(3, "X", 2, 1, 512)
        rig.term.drag_show(1)
        rig.term.drag_show(0)
        rig.expect("\e]72;t=p:x=-1:y=32:X=1:Y=1:m=1;AQIDBA==\e\\\e]72;t=p:x=-1:y=32:X=1:Y=1:m=0\e\\" \
                   "\e]72;t=p:x=-2:y=100:X=16:Y=16:m=1;CQ==\e\\\e]72;t=p:x=-2:y=100:X=16:Y=16:m=0\e\\" \
                   "\e]72;t=p:x=-3:X=2:Y=1:o=512:m=1;WA==\e\\\e]72;t=p:x=-3:X=2:Y=1:o=512:m=0\e\\" \
                   "\e]72;t=P:x=1\e\\\e]72;t=P\e\\")
      end
    end

    it "starts the drag and returns the terminal's answer" do
      rig do |rig|
        rig.ask(/\e\]72;t=P:x=-1\e\\/, osc("72;t=E;OK")) { rig.term.drag_start }.should eq("OK")
        rig.ask(/\e\]72;t=P:x=-1\e\\/, osc("72;t=E;EPERM")) { rig.term.drag_start }.should eq("EPERM")
      end
    end

    it "reports unsolicited drag errors and status events" do
      rig do |rig|
        rig.feed osc("72;t=E;EFBIG") + osc("72;t=E;OK") + osc("72;t=e:x=1:y=2") + osc("72;t=e:x=2:o=2") + osc("72;t=e:x=3") + osc("72;t=e:x=5:y=1") + osc("72;t=k:x=4") + osc("72;t=e:x=4:y=1") + osc("72;t=e:x=4:y=0")
        error = rig.event(Asekii::Event::Drag)
        {error.kind, error.error}.should eq({Asekii::Event::Drag::Kind::Error, "EFBIG"})
        rig.event(Asekii::Event::Drag).kind.should eq(Asekii::Event::Drag::Kind::Started)
        accepted = rig.event(Asekii::Event::Drag)
        {accepted.kind, accepted.index}.should eq({Asekii::Event::Drag::Kind::Accepted, 2})
        action = rig.event(Asekii::Event::Drag)
        {action.kind, action.operation}.should eq({Asekii::Event::Drag::Kind::Action, Asekii::Event::Operation::Move})
        rig.event(Asekii::Event::Drag).kind.should eq(Asekii::Event::Drag::Kind::Dropped)
        request = rig.event(Asekii::Event::Drag)
        {request.kind, request.index}.should eq({Asekii::Event::Drag::Kind::DataRequest, 1})
        file = rig.event(Asekii::Event::Drag)
        {file.kind, file.index}.should eq({Asekii::Event::Drag::Kind::FileRequest, 4})
        canceled = rig.event(Asekii::Event::Drag)
        {canceled.kind, canceled.canceled}.should eq({Asekii::Event::Drag::Kind::Finished, true})
        rig.event(Asekii::Event::Drag).canceled.should be_false
      end
    end

    it "answers data requests and reports failures and cancellation" do
      rig do |rig|
        rig.term.drag_data(1, "payload".to_slice)
        rig.term.drag_data(0, Bytes.empty)
        rig.term.drag_fail(1, "ENOENT", "no such type")
        rig.term.drag_fail(0, "EIO")
        rig.term.drag_abort("EIO", "read failed")
        rig.term.drag_cancel
        rig.expect("\e]72;t=e:y=1:m=1;#{b64("payload")}\e\\\e]72;t=e:y=1:m=0\e\\\e]72;t=e:m=0\e\\\e]72;t=E:y=1;ENOENT:no such type\e\\\e]72;t=E;EIO\e\\\e]72;t=E;EIO:read failed\e\\\e]72;t=E:y=-1\e\\")
      end
    end

    it "sends uri-list entries for files, symlinks and directory children" do
      rig do |rig|
        rig.term.drag_entry(1, "data".to_slice)
        rig.term.drag_entry(2, "target".to_slice, 1)
        rig.term.drag_entry(3, "a\0b".to_slice, 2)
        rig.term.drag_entry(3, "x".to_slice, 0, 2, 1)
        rig.expect("\e]72;t=k:x=1:m=1;#{b64("data")}\e\\\e]72;t=k:x=1:m=0\e\\" \
                   "\e]72;t=k:x=2:X=1:m=1;#{b64("target")}\e\\\e]72;t=k:x=2:X=1:m=0\e\\" \
                   "\e]72;t=k:x=3:X=2:m=1;#{b64("a\0b")}\e\\\e]72;t=k:x=3:X=2:m=0\e\\" \
                   "\e]72;t=k:x=3:Y=2:y=1:m=1;#{b64("x")}\e\\\e]72;t=k:x=3:Y=2:y=1:m=0\e\\")
      end
    end

    it "sends a directory tree breadth first with every child" do
      root = File.tempname("term-spec")
      Dir.mkdir_p(File.join(root, "sub"))
      File.write(File.join(root, "a.txt"), "hello")
      File.write(File.join(root, "sub", "b.txt"), "deep")
      File.symlink("a.txt", File.join(root, "link"))
      begin
        rig do |rig|
          rig.term.drag_path(1, root)
          rig.expect("\e]72;t=k:x=1:Y=3:y=1:m=0\e\\")
          heads = rig.seen.scan(/\e\]72;([^;\e]*);([^\e]*)\e\\/).map { |match| {match[1], Base64.decode_string(match[2])} }
          heads.should eq([
            {"t=k:x=1:X=2:m=1",         "a.txt\0link\0sub"},
            {"t=k:x=1:Y=2:y=1:m=1",     "hello"},
            {"t=k:x=1:X=1:Y=2:y=2:m=1", "a.txt"},
            {"t=k:x=1:X=3:Y=2:y=3:m=1", "b.txt"},
            {"t=k:x=1:Y=3:y=1:m=1",     "deep"},
          ])
          rig.seen.scan(/:m=0\e\\/).size.should eq(5)
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "aborts the drag with the error name when a path cannot be read" do
      rig do |rig|
        rig.term.drag_path(1, "/nonexistent/term-spec")
        rig.expect("\e]72;t=E;ENOENT\e\\")
      end
    end

    it "detects support" do
      rig do |rig|
        rig.ask(/\e\]72;t=q\e\\\e\[c/, osc("72;t=q;") + DA1) { rig.term.supports_dnd? }.should be_true
        rig.ask(/\e\]72;t=q\e\\\e\[c/, DA1) { rig.term.supports_dnd? }.should be_false
      end
    end
  end

  describe "robustness" do
    it "returns nil when a query times out and still answers the next one" do
      config = plain
      config.query_timeout = 40.milliseconds
      rig(config) do |rig|
        rig.term.pointer.should be_nil
        rig.term.supports?(5522).should be_nil
        rig.term.window_size.should be_nil
        rig.term.place(id: 3).should be_nil
        rig.term.supports_graphics?.should be_false
        rig.term.supports_dnd?.should be_false
        rig.term.notification_support.should be_nil
        rig.term.notifications_alive.should be_nil
        rig.term.colors("foreground").should be_nil
        rig.term.drag_start(limit: 40.milliseconds).should be_nil
        rig.term.drop_data(1, limit: 40.milliseconds).should be_nil
        rig.term.copy("x", limit: 40.milliseconds).should be_nil
        rig.term.clipboard_read("text/plain", limit: 40.milliseconds).should be_nil
        rig.expect(/type=read:id=term;[^\e]*\e\\/)
        rig.ask(/\e\[14t/, "\e[4;600;800t") { rig.term.window_size(2.seconds) }.should eq(Asekii::Event::Size.new(800, 600))
      end
    end

    it "ignores plain bytes, unknown sequences and unsolicited replies" do
      rig do |rig|
        rig.feed "\e[5n\e[>1;2;3c\e[?1;2c\e]22;pointer\e\\\e]21;foreground=red\e\\\e_Gi=1;OK\e\\\e]99;i=q:p=alive;a\e\\\e]72;t=r:x=1;AAAA\e\\\e]72;t=q;\e\\\eP1$r0m\e\\\e^private\e\\\e]7;file:///x\a\e[4;1;2t" + press('a')
        key = rig.event(Asekii::Event::Key)
        key.code.should eq(97)
      end
    end

    it "recovers from sequences interrupted by a new escape" do
      rig do |rig|
        rig.feed "\e[12;\e[97u\e]99;i=a\e[98u\e_Gi=1\e[99u"
        Array.new(3) { rig.event(Asekii::Event::Key).code }.should eq([97, 98, 99])
      end
    end

    it "parses a sequence split across reads" do
      rig do |rig|
        "\e[97;5u".each_char do |char|
          rig.feed char.to_s
          sleep 2.milliseconds
        end
        key = rig.event(Asekii::Event::Key)
        {key.code, key.ctrl?}.should eq({97, true})
      end
    end

    it "ignores invalid base64 in drag and drop data and keeps running" do
      rig do |rig|
        config_limit = 60.milliseconds
        result       = Channel(Asekii::Event::DropData?).new(1)
        spawn { result.send(rig.term.drop_data(1, limit: config_limit)) }
        rig.expect("\e]72;t=r:x=1\e\\")
        rig.feed osc("72;t=r:x=1;@@@@") + press('a')
        rig.event(Asekii::Event::Key).code.should eq(97)
        result.receive.should be_nil
      end
    end

    it "keeps escape sequences from concurrent writers intact" do
      rig do |rig|
        done = Channel(Nil).new
        8.times do |writer|
          spawn do
            20.times { rig.term.color(writer, "rgb:00/00/00") }
            done.send(nil)
          end
        end
        8.times { done.receive }
        rig.term.print "END"
        rig.expect("END")
        codes = rig.seen.rchop("END").scan(/\e\]21;(\d)=rgb:00\/00\/00\e\\/)
        codes.size.should eq(160)
        codes.sum(&.[0].bytesize).should eq(rig.seen.rchop("END").bytesize)
      end
    end
  end

  describe "identification" do
    it "reads the primary device attributes" do
      rig do |rig|
        attributes = rig.ask(/\e\[c/, "\e[?62;4;22c") { rig.term.attributes }.not_nil!
        attributes.codes.should eq([62, 4, 22])
        attributes.sixel?.should be_true
      end
    end

    it "names the terminal from XTVERSION and keeps the secondary attributes" do
      rig do |rig|
        found = Channel(Asekii::Terminal::Identity?).new(1)
        spawn { found.send(rig.term.identity) }
        rig.expect(/\e\[>0q\e\[c/)
        rig.feed("\eP>|kitty(0.39.1)\e\\" + DA1)
        rig.expect(/\e\[>c\e\[c/)
        rig.feed("\e[>1;4000;29c" + DA1)
        identity = found.receive.not_nil!
        identity.name.should eq("kitty")
        identity.version.should eq("0.39.1")
        identity.device.should eq(Asekii::Terminal::Device.new(1, 4000, 29))
        rig.term.identity.should eq(identity)
      end
    end

    it "names the terminal from the secondary attributes when XTVERSION goes unanswered" do
      rig do |rig|
        found = Channel(Asekii::Terminal::Identity?).new(1)
        spawn { found.send(rig.term.identity) }
        rig.expect(/\e\[>0q\e\[c/)
        rig.feed(DA1)
        rig.expect(/\e\[>c\e\[c/)
        rig.feed("\e[>84;0;0c" + DA1)
        identity = found.receive.not_nil!
        identity.name.should eq("tmux")
        identity.matches?("tmux").should be_true
      end
    end

    it "splits a version reply on a parenthesis or a space" do
      Asekii::Terminal::Identity.from("WezTerm 20240203-110809-5046fc22", nil).not_nil!.version.should eq("20240203-110809-5046fc22")
      Asekii::Terminal::Identity.from("XTerm(390)", nil).not_nil!.name.should eq("XTerm")
      Asekii::Terminal::Identity.from("foot", nil).not_nil!.version.should eq("")
      Asekii::Terminal::Identity.from(nil, nil).should be_nil
    end
  end

  describe "fallbacks" do
    it "copies and reads through OSC 52 when configured" do
      config = plain
      config.clipboard = Asekii::Terminal::ClipboardProtocol::Osc52
      rig(config) do |rig|
        rig.term.copy("hi").should eq(Asekii::Terminal::Status::Done)
        rig.term.copy("x", primary: true)
        rig.expect("\e]52;c;aGk=\e\\\e]52;p;eA==\e\\")
        clipboard = rig.ask(/\e\]52;c;\?\e\\\e\[c/, "\e]52;c;SGVsbG8=\e\\" + DA1) { rig.term.clipboard_read("text/plain") }.not_nil!
        clipboard.text.should eq("Hello")
        rig.ask(/\e\]52;c;\?\e\\\e\[c/, DA1) { rig.term.clipboard_read("text/plain") }.should be_nil
        rig.term.clipboard_read("image/png").not_nil!.status.should eq(Asekii::Terminal::Status::ENOSYS)
        rig.term.clipboard_write({"image/png" => Bytes[1]}).should eq(Asekii::Terminal::Status::ENOSYS)
        rig.term.clipboard_mimes.should be_nil
      end
    end

    it "streams an OSC 52 read into a sink" do
      config = plain
      config.clipboard = Asekii::Terminal::ClipboardProtocol::Osc52
      rig(config) do |rig|
        sink = IO::Memory.new
        rig.ask(/\e\]52;p;\?\e\\/, "\e]52;p;SGk=\e\\" + DA1) { rig.term.clipboard_read("text/plain", primary: true, into: sink) }
        sink.to_s.should eq("Hi")
      end
    end

    it "picks OSC 52 when the terminal does not report the clipboard protocol" do
      detect(DA1 * 8) do |term, feed, screen|
        term.clipboard_protocol.should eq(Asekii::Terminal::ClipboardProtocol::Osc52)
        term.copy("ok")
        finish(term, feed, screen).should start_with("\e[?1006h\e[?2004h\e[16t\e]52;c;b2s=\e\\")
      end
    end

    it "sends OSC 9 and OSC 777 notifications without control characters" do
      config = plain
      config.notifications = Asekii::Terminal::NotifyProtocol::Osc9
      rig(config) do |rig|
        rig.term.notify("Build", "done\nnow", id: "one").should eq("one")
        rig.term.notify("", "only body")
        rig.expect("\e]9;Build: done now\e\\\e]9;only body\e\\")
      end
      config.notifications = Asekii::Terminal::NotifyProtocol::Osc777
      rig(config) do |rig|
        rig.term.notify("a;b", "c;d")
        rig.expect("\e]777;notify;a,b;c;d\e\\")
        rig.term.notifications_alive.should be_nil
      end
    end

    it "falls back from OSC 99 to the protocol the terminal is known for" do
      detect(DA1 * 8) do |term, feed, screen|
        id = Channel(String).new(1)
        spawn { id.send(term.notify("Build", "done")) }
        drain(screen, "p=?;\e\\\e[c")
        feed << DA1
        feed.flush
        drain(screen, "\e[>0q\e[c")
        feed << "\eP>|WezTerm 20240203\e\\" + DA1
        feed.flush
        drain(screen, "\e[>c\e[c")
        feed << DA1
        feed.flush
        drain(screen, "\e]9;Build: done\e\\")
        id.receive.should match(/\A[0-9a-f-]{36}\z/)
        term.notify_protocol.should eq(Asekii::Terminal::NotifyProtocol::Osc9)
      end
    end

    it "encodes Sixel scaled to cells and iTerm2 images from the pixels it is given" do
      rig do |rig|
        rig.ask(/\e\[16t/, "\e[6;8;4t") { rig.term.cell_size }
        pixels = Asekii::Terminal::Pixels.rgba(Bytes.new(2 * 2 * 4, 255_u8), 2, 2)
        rig.term.sixel_code(pixels, 2, 1).should start_with("\eP0;1;0q\"1;1;8;8")
        rig.term.sixel_code(pixels).should start_with("\eP0;1;0q\"1;1;2;2")
        png = Asekii::Raster.rgba(Bytes.new(4, 255_u8), 1, 1).not_nil!.to_png
        rig.term.inline_image_code(Asekii::Terminal::Pixels.png(png), 3, 2).should eq(Asekii::Raster.iterm(png, 3, 2))
        rig.term.inline_image(pixels)
        rig.expect(/\e\]1337;File=inline=1;size=\d+;width=auto;height=auto;preserveAspectRatio=0;doNotMoveCursor=1:[A-Za-z0-9+\/=]+\a/)
        rig.term.sixel_code(Asekii::Terminal::Pixels.png(Bytes[1, 2, 3])).should eq("")
      end
    end

    it "picks Sixel when kitty graphics go unanswered and the attributes list it" do
      rig do |rig|
        found = Channel(Asekii::ImageProtocol).new(1)
        spawn { found.send(rig.term.image_protocol) }
        rig.expect(/a=q[^\e]*;[A-Za-z0-9+\/=]*\e\\\e\[c/)
        rig.feed(DA1)
        rig.expect(/\e\[c/)
        rig.feed("\e[?62;4;22c")
        found.receive.should eq(Asekii::ImageProtocol::Sixel)
      end
    end

    it "queries the palette with OSC 4, 10 and 11 when OSC 21 goes unanswered" do
      rig do |rig|
        found = Channel(Asekii::Terminal::Palette?).new(1)
        spawn { found.send(rig.term.colors(0, "foreground", "background", "nonsense")) }
        rig.expect(/\e\]21;0=\?;foreground=\?;background=\?;nonsense=\?\e\\\e\[c/)
        rig.feed(DA1)
        rig.expect(/\e\]4;0;\?\e\\\e\]10;\?\e\\\e\]11;\?\e\\\e\[c/)
        rig.feed("\e]4;0;rgb:0000/0000/0000\e\\\e]10;rgb:ffff/ffff/ffff\a\e]11;rgb:1111/2222/3333\e\\" + DA1)
        palette = found.receive.not_nil!
        palette.keys.should eq(["0", "foreground", "background"])
        palette.unknown.should eq(["nonsense"])
        palette["foreground"].should eq(Asekii::Terminal::Color.new(0xffff, 0xffff, 0xffff))
        palette["background"].should eq(Asekii::Terminal::Color.new(0x1111, 0x2222, 0x3333))
        rig.term.legacy_colors?.should be_true
        rig.term.color(1, Asekii::Terminal::Color.rgb(255, 0, 0, 0.5))
        rig.term.reset_color("background")
        rig.term.dynamic_color(3)
        rig.expect("\e]4;1;rgb:ffff/0000/0000\e\\\e]111\e\\\e]104;3\e\\")
      end
    end

    it "reports no palette when the terminal answers no colour query" do
      rig do |rig|
        found = Channel(Asekii::Terminal::Palette?).new(1)
        spawn { found.send(rig.term.colors(1)) }
        rig.expect(/\e\]21;1=\?\e\\\e\[c/)
        rig.feed(DA1)
        rig.expect(/\e\]4;1;\?\e\\\e\[c/)
        rig.feed(DA1)
        found.receive.should be_nil
      end
    end

    it "judges the colour scheme from the background when mode 2031 is missing" do
      detect(DA1 * 8) do |term, feed, screen|
        term.query_color_scheme
        drain(screen, "\e]11;?\e\\")
        feed << "\e]11;rgb:f0f0/f0f0/f0f0\e\\"
        feed.flush
        await(term, Asekii::Event::ColorScheme).dark.should be_false
        term.query_color_scheme
        drain(screen, "\e]11;?\e\\")
        feed << "\e]11;rgb:1c1c/1c1c/1c1c\e\\"
        feed.flush
        await(term, Asekii::Event::ColorScheme).dark.should be_true
      end
    end

    it "measures the luminance of a colour" do
      Asekii::Terminal::Color.rgb(255, 255, 255).luminance.should be_close(1.0, 1e-9)
      Asekii::Terminal::Color.rgb(0, 0, 0).dark?.should be_true
      Asekii::Terminal::Color.rgb(128, 128, 128).dark?.should be_false
    end
  end

  describe "title, bell and progress" do
    it "saves the title before the first change and restores it on close" do
      detect(DA1 * 8) do |term, feed, screen|
        term.title = "Build\e]0;x"
        term.title = "Done"
        term.title.should eq("Done")
        term.bell
        term.progress(0.42)
        term.progress(state: :indeterminate)
        term.progress(0.5, :error)
        output = finish(term, feed, screen)
        output.should start_with("\e[?1006h\e[?2004h\e[16t\e[22;0t\e]2;Build ]0;x\e\\\e]2;Done\e\\\a\e]9;4;1;42\e\\\e]9;4;3\e\\\e]9;4;2;50\e\\")
        output.should end_with("\e]9;4;0\e\\\e[23;0t\e[?2004l\e[?1006l\e[?1049l")
      end
    end

    it "clears progress and restores the title on request" do
      rig do |rig|
        rig.term.reset_title
        rig.term.clear_progress
        rig.term.title = "x"
        rig.term.reset_title
        rig.term.progress(1.5, :paused)
        rig.term.clear_progress
        rig.term.clear_progress
        rig.term.print "END"
        rig.expect("END")
        rig.seen.should eq("\e[22;0t\e]2;x\e\\\e[23;0t\e]9;4;4;100\e\\\e]9;4;0\e\\END")
      end
    end
  end

  describe "multiplexer passthrough" do
    it "wraps kitty-family sequences for tmux and passes the rest through" do
      config = plain
      config.multiplexer = Asekii::Terminal::Multiplexer::Tmux
      rig(config) do |rig|
        rig.term.multiplexer.should eq(Asekii::Terminal::Multiplexer::Tmux)
        rig.term.push_colors
        rig.term.color(1, "red")
        rig.term.bell
        rig.term.print "END"
        rig.expect("END")
        rig.seen.should eq("\ePtmux;\e\e]30001\e\e\\\e\\\ePtmux;\e\e]21;1=red\e\e\\\e\\\aEND")
        rig.term.write("\e[1;1Hab\e_Ga=".to_slice)
        rig.term.write("d;\e\\cd\e]8;;x\e\\END".to_slice)
        rig.expect("END")
        rig.seen.should eq("\e[1;1Hab\ePtmux;\e\e_Ga=d;\e\e\\\e\\cd\e]8;;x\e\\END")
      end
    end

    it "splits sequences for GNU screen and ends OSC with BEL" do
      config = plain
      config.multiplexer = Asekii::Terminal::Multiplexer::Screen
      rig(config) do |rig|
        rig.term.push_colors
        rig.term.print "END"
        rig.expect("END")
        rig.seen.should eq("\eP\e]30001\a\e\\END")
        rig.term.write("\e_Ga=d\e\\END".to_slice)
        rig.expect("END")
        rig.seen.should eq("\eP\e_Ga=d\e\e\\\eP\\\e\\END")
      end
    end

    it "chunks long sequences for GNU screen" do
      config = plain
      config.multiplexer = Asekii::Terminal::Multiplexer::Screen
      rig(config) do |rig|
        rig.term.write("\e_G#{"A" * 2000}\e\\".to_slice)
        rig.term.print "END"
        rig.expect("END")
        chunks = rig.seen.rchop("END").scan(/\eP(.*?)\e\\/m).map(&.[1])
        chunks.all? { |chunk| chunk.bytesize <= 768 }.should be_true
        chunks.join.should eq("\e_G#{"A" * 2000}\e\\")
      end
    end
  end

  describe "support detection" do
    it "probes every feature and enables all of them when the terminal answers" do
      replies = "\e[?0u" + DA1 + {2048, 1003, 1016, 1004, 2033, 2031, 5522}.join { |mode| "\e[?#{mode};2$y" + DA1 }
      detect(replies) do |term, feed, screen, probes|
        probes.should eq(PROBES)
        term.features.should eq(Asekii::Terminal::Feature::All)
        finish(term, feed, screen).should eq(MODES_ON + TEARDOWN)
      end
    end

    it "falls back to cell mouse reports and bracketed paste when nothing is supported" do
      detect(DA1 * 8) do |term, feed, screen|
        term.features.should eq(Asekii::Terminal::Feature::None)
        finish(term, feed, screen).should eq("\e[?1006h\e[?2004h\e[16t\e[?2004l\e[?1006l\e[?1049l")
      end
    end

    it "enables only what is supported, treating states 0 and 4 as unsupported" do
      replies = "\e[?1u" + DA1 + DA1 + DA1 + "\e[?1016;1$y" + DA1 + DA1 + DA1 + "\e[?2031;4$y" + DA1 + "\e[?5522;0$y" + DA1
      detect(replies) do |term, feed, screen|
        term.features.should eq(Asekii::Terminal::Feature::Keyboard | Asekii::Terminal::Feature::Pixels)
        term.features.keyboard?.should be_true
        term.features.paste?.should be_false
        finish(term, feed, screen).should eq("\e[>31u\e[?1016h\e[?2004h\e[16t\e[?2004l\e[?1016l\e[<u\e[?1049l")
      end
    end

    it "assumes nothing is supported when the terminal never answers" do
      detect("", 60.milliseconds) do |term|
        term.features.should eq(Asekii::Terminal::Feature::None)
      end
    end

    it "reads SGR mouse reports as one-based cells without pixel mode" do
      detect(DA1 * 8) do |term, feed|
        feed << "\e[<0;5;3M"
        feed.flush
        mouse = await(term, Asekii::Event::Mouse)
        {mouse.col, mouse.row, mouse.x, mouse.y}.should eq({4, 2, 4, 2})
        feed << "\e[6;20;10t\e[<0;5;3M"
        feed.flush
        mouse = await(term, Asekii::Event::Mouse)
        {mouse.col, mouse.row, mouse.x, mouse.y}.should eq({4, 2, 40, 40})
      end
    end

    it "synthesizes a release for legacy escape keys without the keyboard protocol" do
      detect(DA1 * 8) do |term, feed|
        feed << "\e[A\e[3;5~"
        feed.flush
        keys = Array.new(4) { await(term, Asekii::Event::Key) }
        keys.map(&.named).should eq([Asekii::Event::Named::Up, Asekii::Event::Named::Up, Asekii::Event::Named::Delete, Asekii::Event::Named::Delete])
        keys.map(&.action).should eq([Asekii::Event::Key::Action::Press, Asekii::Event::Key::Action::Release, Asekii::Event::Key::Action::Press, Asekii::Event::Key::Action::Release])
        keys[2].ctrl?.should be_true
      end
    end

    it "skips the probes and enables everything when detection is off" do
      rig do |rig|
        rig.term.features.should eq(Asekii::Terminal::Feature::All)
      end
    end
  end

  describe "legacy input" do
    it "turns typed bytes into a press and release with text" do
      rig do |rig|
        rig.feed "aA1" + tap('q')
        events = rig.upto { |event| marker?(event, 'q') }
        keys   = events.compact_map(&.as?(Asekii::Event::Key)).first(6)
        keys.map(&.code).should eq([97, 97, 97, 97, 49, 49])
        keys.map(&.action.press?).should eq([true, false, true, false, true, false])
        keys[0].text.should eq("a")
        keys[1].text.should be_nil
        keys[2].mods.should eq(Asekii::Event::Mods::Shift)
        keys[2].shifted.should eq(65)
        keys[2].text.should eq("A")
        events.compact_map(&.as?(Asekii::Event::TextInput)).map(&.text).should eq(["a", "A", "1"])
        events.compact_map(&.as?(Asekii::Event::KeyGesture)).select(&.kind.tap?).first(2).map(&.count).should eq([1, 2])
      end
    end

    it "decodes multi-byte UTF-8, even split across reads" do
      rig do |rig|
        bytes = "é€😀".to_slice
        rig.feed String.new(bytes[0, 3])
        sleep 5.milliseconds
        rig.feed String.new(bytes[3..]) + tap('q')
        events = rig.upto { |event| marker?(event, 'q') }
        events.compact_map(&.as?(Asekii::Event::TextInput)).map(&.text).should eq(["é", "€", "😀"])
        events.compact_map(&.as?(Asekii::Event::Key)).select(&.press?).first(3).map(&.code).should eq(['é'.ord, '€'.ord, '😀'.ord])
      end
    end

    it "maps control bytes to named keys and ctrl combinations" do
      config = plain
      config.shortcut("save", 's', Asekii::Event::Mods::Ctrl)
      rig(config) do |rig|
        rig.feed "\r\t\u007f\u0001\u0000\u001d\u0013" + tap('q')
        events = rig.upto { |event| marker?(event, 'q') }
        keys   = events.compact_map(&.as?(Asekii::Event::Key)).select(&.press?).first(7)
        keys.first(3).map(&.named).should eq([Asekii::Event::Named::Enter, Asekii::Event::Named::Tab, Asekii::Event::Named::Backspace])
        keys[3..].map(&.code).should eq([97, 32, 93, 115])
        keys[3..].all?(&.ctrl?).should be_true
        keys.all?(&.text.nil?).should be_true
        events.compact_map(&.as?(Asekii::Event::TextInput)).should be_empty
        bindings(events, :shortcut).should eq(["save"])
      end
    end

    it "reads an escape prefix as alt and SS3 as function keys" do
      rig do |rig|
        rig.feed "\ea\eOP\eOA\eOR" + tap('q')
        events = rig.upto { |event| marker?(event, 'q') }
        keys   = events.compact_map(&.as?(Asekii::Event::Key)).select(&.press?).first(4)
        {keys[0].code, keys[0].mods, keys[0].text}.should eq({97, Asekii::Event::Mods::Alt, nil})
        keys[1..].map(&.named).should eq([Asekii::Event::Named::F1, Asekii::Event::Named::Up, Asekii::Event::Named::F3])
      end
    end

    it "reports a lone escape once no sequence follows" do
      rig do |rig|
        rig.feed "\e"
        key = rig.event(Asekii::Event::Key)
        {key.named, key.press?}.should eq({Asekii::Event::Named::Escape, true})
        rig.event(Asekii::Event::Key).release?.should be_true
        rig.feed "\eO"
        key = rig.event(Asekii::Event::Key)
        {key.code, key.mods}.should eq({111, Asekii::Event::Mods::Alt | Asekii::Event::Mods::Shift})
      end
    end

    it "delivers a bracketed paste as one event without parsing its contents" do
      rig do |rig|
        text = "hello\r\nwörld \e[31m\e]0;x\a ~"
        rig.feed "\e[200~#{text}\e[201~" + tap('q')
        events = rig.upto { |event| marker?(event, 'q') }
        events.compact_map(&.as?(Asekii::Event::Key)).map(&.code).uniq.should eq([113])
        paste = events.compact_map(&.as?(Asekii::Event::Paste)).first
        paste.text.should eq(text)
        paste.mimes.should eq(["text/plain"])
        paste.password.should be_nil
        clipboard = rig.term.clipboard_read(paste, "text/plain").not_nil!
        clipboard.done?.should be_true
        clipboard.text.should eq(text)
      end
    end
  end

  describe "cleanup" do
    it "restores every open terminal at once and does not repeat it on close" do
      reader, feed = IO.pipe
      screen, writer = IO.pipe
      term = Asekii::Terminal.new(plain, reader, writer)
      term.accept_drops
      term.print "X"
      drain(screen, "X").should eq(SETUP + "\e]72;t=a\e\\X")
      Asekii::Terminal.restore
      drain(screen, "\e[?1049l").should eq("\e]72;t=A\e\\" + TEARDOWN)
      Asekii::Terminal.restore
      feed.close
      term.close
      writer.close
      screen.gets_to_end.should eq("")
    end
  end

  describe "event delivery" do
    it "keeps answering queries while the consumer is not reading events" do
      config = plain
      config.event_buffer = 2
      rig(config) do |rig|
        rig.feed "\e[<35;1;1M" * 3000
        window = rig.ask(/\e\[14t/, "\e[4;600;800t") { rig.term.window_size }
        window.should eq(Asekii::Event::Size.new(800, 600))
        Array.new(3000) { rig.event(Asekii::Event::Mouse) }.size.should eq(3000)
      end
    end

    it "drops the oldest events once the backlog limit is reached" do
      config = plain
      config.event_buffer = 1
      config.event_backlog = 10
      rig(config) do |rig|
        rig.feed (1..200).join { |x| "\e[I" }
        rig.feed "\e[O"
        rig.ask(/\e\[14t/, "\e[4;1;1t") { rig.term.window_size }
        sleep 50.milliseconds
        events = rig.upto { |event| event.is_a?(Asekii::Event::Focus) && !event.gained }
        events.size.should be <= 12
      end
    end
  end

  describe "keyboard extras" do
    it "reports lock toggles from transitions in the lock bits" do
      rig do |rig|
        rig.feed "\e[97;1u\e[97;1:3u\e[98;65u\e[98;65:3u\e[99;193u\e[99;129:3u#{tap('q')}"
        events = rig.upto { |event| marker?(event, 'q') }
        locks  = events.compact_map(&.as?(Asekii::Event::Lock)).map { |lock| {lock.lock, lock.active} }
        locks.should eq([
          {Asekii::Event::Mods::CapsLock, true},
          {Asekii::Event::Mods::NumLock,  true},
          {Asekii::Event::Mods::CapsLock, false},
          {Asekii::Event::Mods::NumLock,  false},
        ])
      end
    end

    it "classifies every key event as text input or a key command" do
      rig do |rig|
        rig.feed "\e[97;1;97u\e[97;1:3u\e[97;5;97u\e[57350u#{tap('q')}"
        events = rig.upto { |event| marker?(event, 'q') }
        events.compact_map(&.as?(Asekii::Event::TextInput)).map(&.text).should eq(["a"])
        commands = events.compact_map(&.as?(Asekii::Event::KeyCommand)).map { |command| {command.key.code, command.key.action} }
        commands.first(3).should eq([
          {97,    Asekii::Event::Key::Action::Release},
          {97,    Asekii::Event::Key::Action::Press},
          {57350, Asekii::Event::Key::Action::Press},
        ])
      end
    end

    it "emits a multi-tap event after every tap" do
      rig do |rig|
        rig.feed tap('a') + tap('a') + tap('b')
        events = rig.upto { |event| marker?(event, 'b') }
        multi  = events.compact_map(&.as?(Asekii::Event::KeyGesture)).select(&.kind.multi_tap?)
        multi.map { |gesture| {gesture.key.code, gesture.count} }.should eq([{97, 1}, {97, 2}, {98, 1}])
      end
    end
  end

  describe "mouse extras" do
    it "keeps a hover dwell alive while the pointer stays inside the radius" do
      config = plain
      config.hover_dwell_after = 20.milliseconds
      config.hover_radius = 6
      rig(config) do |rig|
        rig.feed "\e[<35;50;50M"
        rig.event(Asekii::Event::MouseGesture, &.kind.hover_dwell?)
        rig.feed "\e[<35;53;52M\e[<35;48;47M#{tap('q')}"
        events = rig.upto { |event| marker?(event, 'q') }
        gestures(events).should_not contain(Asekii::Event::MouseGesture::Kind::HoverEnd)
        rig.feed "\e[<35;60;50M"
        rig.event(Asekii::Event::MouseGesture, &.kind.hover_end?).mouse.x.should eq(60)
      end
    end

    it "reports a leave at the last valid position instead of the placeholder origin" do
      rig do |rig|
        rig.feed "\e[48;10;20;200;400t\e[<35;45;65M\e[<256;0;0M"
        rig.event(Asekii::Event::Mouse)
        leave = rig.event(Asekii::Event::Mouse)
        {leave.action, leave.x, leave.y, leave.col, leave.row}.should eq({Asekii::Event::Mouse::Action::Leave, 45, 65, 2, 3})
      end
    end
  end

  describe "clipboard extras" do
    it "uses the configured request id and rejects an invalid one" do
      config = plain
      config.clipboard_id = "pane-7"
      rig(config) do |rig|
        reply = osc("5522;type=read:status=OK:id=pane-7") + osc("5522;type=read:status=DATA:id=pane-7:mime=#{b64("text/plain")};#{b64("hi")}") + osc("5522;type=read:status=DONE:id=pane-7")
        rig.ask(/\e\]5522;type=read:id=pane-7;/, reply) { rig.term.clipboard_read("text/plain") }.not_nil!.text.should eq("hi")
      end
      bad = plain
      bad.clipboard_id = "no:colons"
      reader, _feed = IO.pipe
      _screen, writer = IO.pipe
      expect_raises(ArgumentError) { Asekii::Terminal.new(bad, reader, writer) }
    end

    it "treats an id-less reply as its own when a read is pending" do
      rig do |rig|
        reply = osc("5522;type=read:status=OK") + osc("5522;type=read:status=DATA:mime=#{b64("text/plain")};#{b64("hi")}") + osc("5522;type=read:status=DONE")
        rig.ask(/\e\]5522;type=read:id=term;/, reply) { rig.term.clipboard_read("text/plain") }.not_nil!.text.should eq("hi")
      end
    end

    it "retries reads and writes that report EBUSY" do
      config = plain
      config.busy_delay = 5.milliseconds
      rig(config) do |rig|
        result = Channel(Asekii::Terminal::Status?).new(1)
        spawn { result.send(rig.term.copy("x")) }
        rig.expect(/type=wdata\e\\/)
        rig.feed osc("5522;type=write:status=EBUSY")
        rig.expect(/type=wdata\e\\/)
        rig.feed osc("5522;type=write:status=DONE")
        result.receive.should eq(Asekii::Terminal::Status::Done)
        read = Channel(Asekii::Terminal::Clipboard?).new(1)
        spawn { read.send(rig.term.clipboard_read("text/plain")) }
        rig.expect(/type=read:id=term;[^\e]*\e\\/)
        rig.feed osc("5522;type=read:status=EBUSY:id=term")
        rig.expect(/type=read:id=term;[^\e]*\e\\/)
        rig.feed osc("5522;type=read:status=OK:id=term") + osc("5522;type=read:status=DONE:id=term")
        read.receive.not_nil!.done?.should be_true
      end
    end

    it "gives up after the configured number of busy retries" do
      config = plain
      config.busy_delay = 1.millisecond
      config.busy_retries = 2
      rig(config) do |rig|
        result = Channel(Asekii::Terminal::Status?).new(1)
        spawn { result.send(rig.term.copy("x")) }
        3.times do
          rig.expect(/type=wdata\e\\/)
          rig.feed osc("5522;type=write:status=EBUSY")
        end
        result.receive.should eq(Asekii::Terminal::Status::EBUSY)
      end
    end

    it "streams a write from an IO and a read into an IO" do
      rig do |rig|
        data = Bytes.new(9000) { |index| (index % 239).to_u8 }
        rig.ask(/\e\]5522;type=wdata\e\\/, osc("5522;type=write:status=DONE")) do
          rig.term.clipboard_write({"application/octet-stream" => IO::Memory.new(data)})
        end.should eq(Asekii::Terminal::Status::Done)
        chunks = rig.seen.scan(/\e\]5522;type=wdata:mime=[^;]+;([^\e]*)\e\\/).map { |match| Base64.decode(match[1]) }
        chunks.map(&.size).should eq([4095, 4095, 810])
        chunks.reduce(Bytes.empty) { |all, chunk| all + chunk }.should eq(data)
        sink = IO::Memory.new
        reply = osc("5522;type=read:status=OK:id=term") +
                osc("5522;type=read:status=DATA:id=term:mime=#{b64("image/png")};#{b64(data[0, 4096])}") +
                osc("5522;type=read:status=DATA:id=term:mime=#{b64("image/png")};#{b64(data[4096..])}") +
                osc("5522;type=read:status=DONE:id=term")
        clipboard = rig.ask(/type=read:id=term;/, reply) { rig.term.clipboard_read("image/png", into: sink) }.not_nil!
        clipboard.done?.should be_true
        clipboard.data.should be_empty
        sink.to_slice.should eq(data)
      end
    end
  end

  describe "color extras" do
    it "parses named colors case-insensitively and with spaces" do
      Asekii::Terminal::Color.parse("red").should eq(Asekii::Terminal::Color.new(0xffff, 0, 0))
      Asekii::Terminal::Color.parse("Alice Blue").should eq(Asekii::Terminal::Color.rgb(240, 248, 255))
      Asekii::Terminal::Color.parse("DARKSLATEGRAY4@0.5").should eq(Asekii::Terminal::Color.rgb(82, 139, 139, 0.5))
      Asekii::Terminal::NAMES.size.should be > 600
    end

    it "sets a color and confirms it in one escape code" do
      rig do |rig|
        color = rig.ask(/\e\]21;foreground=white;foreground=\?\e\\/, osc("21;foreground=white")) { rig.term.confirm_color("foreground", "white") }
        color.should eq(Asekii::Terminal::Color.new(0xffff, 0xffff, 0xffff))
        rig.ask(/\e\]21;9=#102030;9=\?\e\\/, osc("21;unknown=OQ")) { rig.term.confirm_color(9, "#102030") }.should be_nil
      end
    end
  end

  describe "notification extras" do
    it "rejects identifiers outside the allowed character set" do
      rig do |rig|
        expect_raises(ArgumentError) { rig.term.notify("x", id: "bad;id") }
        expect_raises(ArgumentError) { rig.term.notify("x", icon_key: "a:b") }
        expect_raises(ArgumentError) { rig.term.close_notification("\e]0") }
        rig.term.notify("x", id: "ok_id-1+2.3")
        rig.expect("\e]99;i=ok_id-1+2.3:e=1;eA==\e\\")
      end
    end

    it "transmits cached icon data only once per key" do
      rig do |rig|
        rig.term.notify("a", id: "one", icon: Bytes[1, 2, 3], icon_key: "k")
        rig.term.notify("b", id: "two", icon: Bytes[1, 2, 3], icon_key: "k")
        rig.term.notify("c", id: "three", icon: Bytes[4], icon_key: "other")
        rig.expect("\e]99;i=one:g=k:e=1:d=0;YQ==\e\\\e]99;i=one:p=icon:e=1:g=k;AQID\e\\" \
                   "\e]99;i=two:g=k:e=1;Yg==\e\\" \
                   "\e]99;i=three:g=other:e=1:d=0;Yw==\e\\\e]99;i=three:p=icon:e=1:g=other;BA==\e\\")
      end
    end
  end

  describe "drag and drop extras" do
    it "returns the feature flags from the support query" do
      rig do |rig|
        rig.ask(/\e\]72;t=q\e\\\e\[c/, osc("72;t=q;future=1:other=x") + DA1) { rig.term.dnd_support }.should eq({"future" => "1", "other" => "x"})
        rig.ask(/\e\]72;t=q\e\\\e\[c/, osc("72;t=q;") + DA1) { rig.term.dnd_support }.should eq({} of String => String)
        rig.ask(/\e\]72;t=q\e\\\e\[c/, DA1) { rig.term.dnd_support }.should be_nil
      end
    end

    it "streams dropped data into an IO" do
      rig do |rig|
        data    = Bytes.new(7000) { |index| (index % 233).to_u8 }
        encoded = b64(data).rstrip('=')
        reply   = osc("72;t=r:x=1:m=1;#{encoded[0, 4095]}") + osc("72;t=r:x=1:m=1;#{encoded[4095, 4095]}") + osc("72;t=r:x=1:m=1;#{encoded[8190..]}") + osc("72;t=r:x=1;")
        sink    = IO::Memory.new
        dropped = rig.ask(/\e\]72;t=r:x=1\e\\/, reply) { rig.term.drop_data(1, into: sink) }.not_nil!
        dropped.ok?.should be_true
        dropped.data.should be_empty
        sink.to_slice.should eq(data)
      end
    end

    it "streams outgoing data from an IO and never interleaves two streams" do
      rig do |rig|
        done = Channel(Nil).new
        {1, 2}.each do |index|
          spawn do
            rig.term.drag_data(index, IO::Memory.new(Bytes.new(3072 * 4, index.to_u8)))
            done.send(nil)
          end
        end
        2.times { done.receive }
        rig.term.print "END"
        rig.expect("END")
        order = rig.seen.scan(/\e\]72;t=e:y=(\d):m=(\d)/).map { |match| {match[1], match[2]} }
        order.size.should eq(10)
        order.each_slice(5) do |group|
          group.map(&.[0]).uniq.size.should eq(1)
          group.map(&.[1]).should eq(["1", "1", "1", "1", "0"])
        end
      end
    end

    it "saves a remote directory tree to disk" do
      root = File.tempname("term-drop")
      begin
        rig do |rig|
          result = Channel(Bool).new(1)
          spawn { result.send(rig.term.drop_save(1, 2, root)) }
          rig.expect("\e]72;t=r:x=1:y=2\e\\")
          rig.feed osc("72;t=r:x=1:y=2:X=7;#{b64("a.txt\0link\0sub")}")
          rig.expect("\e]72;t=r:Y=7:x=1\e\\")
          rig.feed osc("72;t=r:Y=7:x=1:m=1;#{b64("hello")}") + osc("72;t=r:Y=7:x=1;")
          rig.expect("\e]72;t=r:Y=7:x=2\e\\")
          rig.feed osc("72;t=r:Y=7:x=2:X=1;#{b64("a.txt")}")
          rig.expect("\e]72;t=r:Y=7:x=3\e\\")
          rig.feed osc("72;t=r:Y=7:x=3:X=8;#{b64("b.txt")}")
          rig.expect("\e]72;t=r:Y=8:x=1\e\\")
          rig.feed osc("72;t=r:Y=8:x=1;#{b64("deep")}")
          rig.expect("\e]72;t=r:Y=8\e\\\e]72;t=r:Y=7\e\\")
          result.receive.should be_true
        end
        File.read(File.join(root, "a.txt")).should eq("hello")
        File.readlink(File.join(root, "link")).should eq("a.txt")
        File.read(File.join(root, "sub", "b.txt")).should eq("deep")
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "refuses entry names that would escape the destination" do
      root = File.tempname("term-drop")
      begin
        rig do |rig|
          result = Channel(Bool).new(1)
          spawn { result.send(rig.term.drop_save(1, 1, root)) }
          rig.expect("\e]72;t=r:x=1:y=1\e\\")
          rig.feed osc("72;t=r:x=1:y=1:X=7;#{b64("../evil")}")
          rig.expect("\e]72;t=r:Y=7\e\\")
          result.receive.should be_false
        end
        File.exists?(root + "/../evil").should be_false
        Dir.children(root).should be_empty
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "reports a failed save and leaves nothing behind" do
      root = File.tempname("term-drop")
      rig do |rig|
        rig.ask(/\e\]72;t=r:x=1:y=1\e\\/, osc("72;t=R:x=1:y=1;EPERM")) { rig.term.drop_save(1, 1, root) }.should be_false
      end
      File.exists?(root).should be_false
    end

    it "builds a uri-list and answers the terminal's file requests in order" do
      root = File.tempname("term-drag")
      Dir.mkdir_p(File.join(root, "dir with space"))
      File.write(File.join(root, "a.txt"), "hello")
      File.write(File.join(root, "dir with space", "b.txt"), "deep")
      begin
        rig do |rig|
          list = rig.term.drag_files([File.join(root, "a.txt"), File.join(root, "dir with space")])
          list.should eq("file://#{root}/a.txt\r\nfile://#{root}/dir%20with%20space/\r\n")
          rig.feed osc("72;t=k:x=2") + osc("72;t=k:x=1") + osc("72;t=k:x=9")
          rig.expect("\e]72;t=E;ENOENT\e\\")
          heads = rig.seen.scan(/\e\]72;([^;\e]*);([^\e]*)\e\\/).map { |match| {match[1], match[1].ends_with?("m=1") ? Base64.decode_string(match[2]) : match[2]} }
          heads.should eq([
            {"t=k:x=2:X=2:m=1",     "b.txt"},
            {"t=k:x=2:Y=2:y=1:m=1", "deep"},
            {"t=k:x=1:m=1",         "hello"},
            {"t=E",                 "ENOENT"},
          ])
          Array.new(3) { rig.event(Asekii::Event::Drag).index }.should eq([2, 1, 9])
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "leaves file requests to the application when no files are registered" do
      rig do |rig|
        rig.feed osc("72;t=k:x=1")
        rig.event(Asekii::Event::Drag).kind.should eq(Asekii::Event::Drag::Kind::FileRequest)
        rig.term.print "END"
        rig.expect("END")
        rig.seen.should eq("END")
      end
    end

    it "aborts with EINVAL when asked to send something that is not a file, link or directory" do
      rig do |rig|
        rig.term.drag_path(1, "/dev/null")
        rig.expect("\e]72;t=E;EINVAL\e\\")
      end
    end
  end

  describe "suspend and resume" do
    it "leaves and re-enters the terminal modes" do
      reader, feed = IO.pipe
      screen, writer = IO.pipe
      term = Asekii::Terminal.new(plain, reader, writer)
      drain(screen, "\e[16t")
      term.suspend
      term.suspend
      drain(screen, "\e[?1049l").should eq(TEARDOWN)
      term.resume
      term.resume
      drain(screen, "\e[16t").should eq(SETUP)
      term.refresh
      feed.close
      term.close
      writer.close
      screen.gets_to_end.should eq(TEARDOWN)
    end
  end

  describe "on a real terminal" do
    it "enters raw mode on open and restores the exact original settings on close" do
      original = nil
      prepare = ->(pty : TTY::PTY) do
        custom = pty.termios
        custom.echo = false
        custom[TTY::ControlChar::Min] = 3_u8
        pty.termios = custom
        original = pty.termios
        nil
      end
      console(prepare: prepare) do |console|
        console.expect("\e[16t").should eq(SETUP)
        raw?(console.mode).should be_true
        console.term.close
        console.expect("\e[?1049l").should eq(TEARDOWN)
        restored = console.mode
        restored.should eq(original.not_nil!)
        restored.canonical?.should be_true
        restored.echo?.should be_false
        restored[TTY::ControlChar::Min].should eq(3_u8)
      end
    end

    it "passes input and output through the line discipline untouched" do
      console do |console|
        console.expect("\e[16t")
        console.feed "\r\n\u0003\e[97u"
        keys = Array.new(7) { await(console.term, Asekii::Event::Key) }.select(&.press?)
        keys.map(&.code).should eq([13, 106, 99, 97])
        keys[1].ctrl?.should be_true
        keys[2].ctrl?.should be_true
        console.term.print "a\nb\tc"
        console.expect("c").should eq("a\nb\tc")
      end
    end

    it "leaves raw mode while suspended and when restored early" do
      console do |console|
        console.expect("\e[16t")
        console.term.suspend
        console.expect("\e[?1049l").should eq(TEARDOWN)
        raw?(console.mode).should be_false
        console.term.resume
        console.expect("\e[16t").should eq(SETUP)
        raw?(console.mode).should be_true
        Asekii::Terminal.restore
        console.expect("\e[?1049l").should eq(TEARDOWN)
        raw?(console.mode).should be_false
      end
    end

    it "reads the cell size from the terminal at startup" do
      console(size: window(30, 100, 1000, 600)) do |console|
        console.expect("\e[16t")
        console.feed "\e[<0;45;65M"
        mouse = await(console.term, Asekii::Event::Mouse)
        {mouse.col, mouse.row}.should eq({4, 3})
      end
    end

    it "reports a resize from the terminal when in-band resize is unsupported" do
      config = Asekii::Terminal::Config.new
      config.signals = false
      config.query_timeout = 60.milliseconds
      console(config, window(30, 100, 1000, 600)) do |console|
        console.term.features.should eq(Asekii::Terminal::Feature::None)
        console.expect("\e[16t")
        console.feed "\e[<0;5;3M"
        mouse = await(console.term, Asekii::Event::Mouse)
        {mouse.col, mouse.row, mouse.x, mouse.y}.should eq({4, 2, 40, 40})
        console.pty.winsize = window(40, 120, 1200, 800)
        console.term.refresh
        resize = await(console.term, Asekii::Event::Resize)
        {resize.rows, resize.cols, resize.width, resize.height}.should eq({40, 120, 1200, 800})
      end
    end

    it "fills missing window pixels from the cell size report" do
      config = Asekii::Terminal::Config.new
      config.signals = false
      config.query_timeout = 60.milliseconds
      console(config, window(30, 100)) do |console|
        console.expect("\e[16t\e[14t")
        console.feed "\e[6;20;10t"
        resize = await(console.term, Asekii::Event::Resize)
        {resize.rows, resize.cols, resize.width, resize.height}.should eq({30, 100, 1000, 600})
        console.pty.winsize = window(40, 120)
        console.term.refresh
        resize = await(console.term, Asekii::Event::Resize)
        {resize.rows, resize.cols, resize.width, resize.height}.should eq({40, 120, 1200, 800})
      end
    end

    it "falls back to the window size report for the cell size" do
      config = Asekii::Terminal::Config.new
      config.signals = false
      config.query_timeout = 60.milliseconds
      console(config, window(30, 100)) do |console|
        console.expect("\e[16t\e[14t")
        console.feed "\e[4;600;1000t"
        resize = await(console.term, Asekii::Event::Resize)
        {resize.rows, resize.cols, resize.width, resize.height}.should eq({30, 100, 1000, 600})
      end
    end

    it "prefers the cell size report over the window size report" do
      config = Asekii::Terminal::Config.new
      config.signals = false
      config.query_timeout = 60.milliseconds
      console(config, window(30, 100)) do |console|
        console.expect("\e[16t\e[14t")
        console.feed "\e[6;20;10t"
        resize = await(console.term, Asekii::Event::Resize)
        {resize.width, resize.height}.should eq({1000, 600})
        console.feed "\e[4;660;1040t\e[I"
        following = loop do
          event = console.term.events.receive
          break event if event.is_a?(Asekii::Event::Resize) || event.is_a?(Asekii::Event::Focus)
        end
        following.should be_a(Asekii::Event::Focus)
      end
    end

    it "does nothing on refresh when the terminal reports resizes itself" do
      console(size: window(30, 100, 1000, 600)) do |console|
        console.expect("\e[16t")
        console.term.refresh
        console.feed "\e[I"
        await(console.term, Asekii::Event::Focus).gained.should be_true
      end
    end
  end

  describe "parallel execution" do
    it "tracks terminals opened and closed in parallel" do
      swarm(8) do |_index|
        10.times { roundtrip.should eq(SETUP + TEARDOWN) }
      end
      output = capture do |term|
        settle(term)
        Asekii::Terminal.restore
      end
      output.gsub(SIZE_ASK, "").should eq(SETUP + TEARDOWN)
    end

    it "keeps escape sequences from parallel writers intact" do
      output = capture do |term|
        swarm(8) do |writer|
          200.times { term.color(writer, "rgb:00/00/00") }
        end
        settle(term)
      end
      body  = output.gsub(SIZE_ASK, "").lchop(SETUP).rchop(TEARDOWN)
      codes = body.scan(/\e\]21;(\d)=rgb:00\/00\/00\e\\/)
      codes.size.should eq(1600)
      codes.sum(&.[0].bytesize).should eq(body.bytesize)
      codes.map(&.[1]).tally.values.should eq([200] * 8)
    end

    it "keeps a multi-part transfer contiguous among parallel transfers" do
      payload = Bytes.new(Asekii::Terminal::RAW_CHUNK * 3 + 1, 65_u8)
      output = capture do |term|
        swarm(4) do |index|
          20.times { term.drag_data(index + 1, payload) }
        end
        settle(term)
      end
      marks = output.scan(/\e\]72;t=e:y=(\d):m=([01])/).map { |match| {match[1], match[2]} }
      marks.size.should eq(4 * 20 * 5)
      marks.each_slice(5) do |stream|
        stream.map(&.[0]).uniq.size.should eq(1)
        stream.map(&.[1]).should eq(["1", "1", "1", "1", "0"])
      end
    end

    it "routes every reply to its own caller under parallel queries" do
      settings = plain
      settings.query_timeout = 5.seconds
      reply = ->(match : Regex::MatchData) do
        match[1]?.try { |mode| "\e[?#{mode};#{mode.to_i.even? ? 1 : 4}$y" } || SIZE_ANSWER
      end
      capture(settings, pattern: /\e\[\?(\d+)\$p|\e\[14t/, reply: reply) do |term|
        swarm(8) do |index|
          25.times do |round|
            mode = 10000 + index * 100 + round
            term.supports?(mode).should eq(mode.even?)
            term.window_size.should eq(Asekii::Event::Size.new(800, 600))
          end
        end
      end
    end

    it "keeps suspend, resume and output whole under parallel callers" do
      output = capture do |term|
        settle(term)
        swarm(8) do |index|
          50.times do |round|
            term.suspend
            term.print "<#{index}.#{round}>"
            term.resume
          end
        end
        settle(term)
      end
      tokens = output.scan(/<\d+\.\d+>/).map(&.[0])
      tokens.size.should eq(400)
      tokens.uniq.size.should eq(400)
      output.gsub(/<\d+\.\d+>/, "").gsub(SIZE_ASK, "").should match(cycles(""))
    end

    it "writes nothing after restore whatever races with it" do
      output = capture do |term|
        settle(term)
        swarm(8) do |index|
          40.times do |round|
            term.suspend
            Asekii::Terminal.restore if index == 0 && round == 20
            term.resume
          end
        end
      end
      output.gsub(SIZE_ASK, "").should match(cycles("(?:#{Regex.escape(TEARDOWN)})?"))
    end

    it "tears down once when closed from several fibers at once" do
      output = capture do |term|
        settle(term)
        swarm(8) { |_index| term.close }
        term.closed?.should be_true
      end
      output.gsub(SIZE_ASK, "").should eq(SETUP + TEARDOWN)
    end

    it "delivers events in order when its own fibers run in parallel" do
      keys = Array.new(3000) { |index| 'a' + index % 26 }
      capture(context: POOL) do |term, feed|
        feed << keys.join { |key| tap(key) }
        feed.flush
        seen = Array.new(6000) { await(term, Asekii::Event::Key) }.select(&.press?).map(&.code)
        seen.should eq(keys.map(&.ord))
      end
    end
  end

  describe "as a child process on a terminal" do
    it "restores the terminal when terminated by a signal" do
      rest, status = child("signal") do |process|
        raw?(process.pty.termios).should be_true
        process.terminate
      end
      rest.should end_with("\e]72;t=A\e\\" + TEARDOWN)
      status.exit_code.should eq(128 + Signal::TERM.value)
    end

    it "restores the terminal when the process exits without closing" do
      rest, status = child("exit") { }
      rest.should end_with("\e]72;t=A\e\\" + TEARDOWN)
      status.exit_code.should eq(3)
    end

    it "suspends on SIGTSTP with the terminal cooked and resumes raw on SIGCONT" do
      rest, status = child("signal") do |process|
        process.signal(Signal::TSTP)
        drain(process.io, "\e[?1049l").should eq(TEARDOWN)
        stopped?(process, true).should be_true
        raw?(process.pty.termios).should be_false
        process.signal(Signal::CONT)
        drain(process.io, "1000x600").should eq(SETUP + "SIZE 30x100 1000x600")
        stopped?(process, false).should be_true
        raw?(process.pty.termios).should be_true
        process.terminate
      end
      rest.should end_with(TEARDOWN)
      status.exit_code.should eq(128 + Signal::TERM.value)
    end

    it "stops itself on Ctrl-Z and comes back on continue" do
      {"signal", "unhooked"}.each do |scenario|
        child(scenario) do |process|
          process.io << "\u001a"
          drain(process.io, "\e[?1049l").should eq(TEARDOWN)
          stopped?(process, true).should be_true
          raw?(process.pty.termios).should be_false
          process.signal(Signal::CONT)
          drain(process.io, "1000x600").should eq(SETUP + "SIZE 30x100 1000x600")
          stopped?(process, false).should be_true
          raw?(process.pty.termios).should be_true
          process.kill
        end
      end
    end

    it "turns a window size change into a resize event" do
      child("bare") do |process|
        process.pty.winsize = window(40, 120, 1200, 800)
        drain(process.io, "800").should end_with("SIZE 40x120 1200x800")
        process.kill
      end
    end
  end
end
