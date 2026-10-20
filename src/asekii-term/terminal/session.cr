# src/asekii-term/terminal/session.cr
class Asekii::Terminal
  SCREEN      = {"\e[?1049h", "\e[?1049l"}
  CELL_SIZE   = "\e[16t"
  WINDOW_SIZE = "\e[14t"

  SIGNALS = {% if flag?(:win32) %}
              [::Signal::INT]
            {% else %}
              [::Signal::INT, ::Signal::TERM, ::Signal::HUP, ::Signal::QUIT]
            {% end %}

  @@open = Sync::Exclusive(Array(Asekii::Terminal)).new([] of Asekii::Terminal)
  @@hooked = Atomic(Bool).new(false)

  def self.restore : Nil
    @@open.lock(&.dup).each(&.restore)
  end

  def self.suspend : Nil
    @@open.lock(&.dup).each(&.suspend)
  end

  def self.resume : Nil
    @@open.lock(&.dup).each(&.resume)
  end

  def self.refresh : Nil
    @@open.lock(&.dup).each(&.refresh)
  end

  def self.open(config : Config = Config.new, input : IO::FileDescriptor = STDIN, output : IO::FileDescriptor = STDOUT, & : Asekii::Terminal ->)
    term = new(config, input, output)
    begin
      yield term
    ensure
      term.close
    end
  end

  @cell_width = Atomic(Int32).new(0)
  @cell_height = Atomic(Int32).new(0)
  @rows = Atomic(Int32).new(0)
  @cols = Atomic(Int32).new(0)
  @sighted = Atomic(Bool).new(true)
  @setup = ""
  @saved : TTY::Termios?
  @suspended = Atomic(Bool).new(false)
  @teardown : String
  @restored = Atomic(Bool).new(false)
  @features = Atomic(Int32).new(Feature::All.value)
  @medium = Atomic(Int32).new(-1)

  CONTEXT = Fiber::ExecutionContext::Concurrent.new("asekii.term")

  lib LibTerm
    fun dup(fd : LibC::Int) : LibC::Int
    fun raise(signal : LibC::Int) : LibC::Int
  end

  def context : Fiber::ExecutionContext::Concurrent
    CONTEXT
  end

  def initialize(@config : Config = Config.new, @input : IO::FileDescriptor = STDIN, @io : IO::FileDescriptor = STDOUT)
    ident(@config.clipboard_id)
    @events = Channel(Event::Input).new(@config.event_buffer)
    @output = Channel(Output).new(256)
    @raw = Channel(Event::Raw).new(256)
    @pending = Channel(Request).new(256)
    @serving = Channel(Array(String) | Int32).new(1024)
    @stop = Channel(Nil).new
    @reader_done = Channel(Nil).new
    @writer_done = Channel(Nil).new
    @mutexes = Family.values.map { Sync::Mutex.new(:reentrant) }
    @credentials = @config.app_name.try do |name|
      ":pw=#{Base64.strict_encode(UUID.random.to_s)}:name=#{Base64.strict_encode(name)}"
    end || ""
    @mux = keys(':', {'i', @config.dnd_id})
    @passthrough = Passthrough.for(@config.multiplexer)
    @source = IO::FileDescriptor.new(duplicate(@input))
    setup_engine
    screen = @config.alternate_screen ? SCREEN : {"", ""}
    @teardown = @config.leave + screen[1]
    @saved = capture
    raw
    measure
    register
    @output.send(screen[0])
    CONTEXT.spawn(name: "term.writer") { run_writer }
    CONTEXT.spawn(name: "term.reader") { run_reader }
    CONTEXT.spawn(name: "term.engine") { run_engine }
    CONTEXT.spawn(name: "term.server") { run_server }
    found = survey
    @features.set(found.value)
    @wire.synchronize do
      @teardown = @config.leave + FEATURES.reverse.join { |mode| mode.switch(found.includes?(mode.feature), false) } + screen[1]
      @setup = screen[0] + FEATURES.join { |mode| mode.switch(found.includes?(mode.feature), true) } + sizing + @config.enter
    end
    @output.send(@setup.lchop(screen[0]))
  end

  private def duplicate(input : IO::FileDescriptor) : Int32
    fd = LibTerm.dup(input.fd)
    raise IO::Error.from_errno("dup") if fd < 0
    fd
  end

  private def register : Nil
    @@open.lock(&.push(self))
    return if !@config.signals || @@hooked.swap(true)
    at_exit { Asekii::Terminal.restore }
    SIGNALS.each do |signal|
      signal.trap do
        Asekii::Terminal.restore
        exit 128 + signal.value
      end
    end
    {% unless flag?(:win32) %}
      ::Signal::TSTP.trap do
        Asekii::Terminal.suspend
        Process.signal(::Signal::STOP, Process.pid)
      end
      ::Signal::CONT.trap { Asekii::Terminal.resume }
      ::Signal::WINCH.trap { Asekii::Terminal.refresh }
    {% end %}
  end

  private def capture : TTY::Termios?
    TTY::Termios.get(@input) if @input.tty?
  rescue TTY::Error
  end

  private def measure : Event::Resize?
    size = TTY::Winsize.get(@io)
    span(size.rows.to_i, size.cols.to_i, size.ypixel.to_i, size.xpixel.to_i)
  rescue TTY::Error
  end

  private def span(rows : Int32, cols : Int32, height : Int32, width : Int32) : Event::Resize?
    return unless cols > 0 && rows > 0
    @rows.set(rows)
    @cols.set(cols)
    @sighted.set(width > 0 && height > 0)
    @cell_width.set(width // cols) if width > 0
    @cell_height.set(height // rows) if height > 0
    width = cols * @cell_width.get if width <= 0
    height = rows * @cell_height.get if height <= 0
    Event::Resize.new(rows, cols, height, width)
  end

  private def blind? : Bool
    @cols.get > 0 && (@cell_width.get <= 0 || @cell_height.get <= 0)
  end

  private def sizing : String
    blind? ? CELL_SIZE + WINDOW_SIZE : CELL_SIZE
  end

  private def resolve(width : Int32, height : Int32) : Nil
    return unless width > 0 && height > 0
    return if width == @cell_width.get && height == @cell_height.get
    @cell_width.set(width)
    @cell_height.set(height)
    rows = @rows.get
    cols = @cols.get
    push Event::Resize.new(rows, cols, rows * height, cols * width) if rows > 0 && cols > 0
  end

  private def requery : Nil
    @output.send(sizing) unless @sighted.get
  end

  private def raw : Nil
    @saved.try(&.raw.set(@input))
  rescue TTY::Error
  end

  private def cooked : Nil
    @saved.try(&.set(@input))
  rescue TTY::Error
  end

  private def park : Nil
    if @@hooked.get
      signal_group(::Signal::TSTP)
    else
      suspend
      signal_group(::Signal::STOP)
      LibTerm.raise(::Signal::STOP.value)
      resume
    end
  end

  private def signal_group(signal : ::Signal) : Nil
    TTY::Session.signal_process_group(0, signal)
  rescue TTY::Error
  end

  def refresh : Nil
    return if features.resize? || closed?
    measure.try do |resize|
      push resize
      requery
    end
  rescue Channel::ClosedError
  end

  def suspend : Nil
    @wire.synchronize do
      next if @restored.get || @suspended.swap(true)
      outward(indicators_off)
      outward(@teardown)
      @io.flush
      cooked
    end
  rescue IO::Error
  end

  def resume : Nil
    resumed = @wire.synchronize do
      next false if @restored.get || !@suspended.swap(false)
      raw
      outward(@setup)
      outward(indicators_on)
      @io.flush
      true
    end
    return unless resumed
    measure.try do |resize|
      select
      when @raw.send(resize)
      else
      end
    end
    select
    when @raw.send(Event::Resume.new)
    else
    end
  rescue IO::Error | Channel::ClosedError
  end

  def features : Feature
    Feature.new(@features.get)
  end

  protected def restore : Nil
    @wire.synchronize do
      next if @restored.swap(true)
      outward(dnd_code("t=A")) if @accepting.get
      outward(dnd_code("t=o:x=2")) if @offering.get
      outward(indicators_off)
      outward(@teardown)
      @io.flush
      cooked
    end
  rescue IO::Error
  end

  def close : Nil
    return unless @stop.close
    @output.close
    @writer_done.receive?
    restore
    @@open.lock(&.delete(self))
    @pending.close
    @serving.close
    @events.close
    @source.close rescue nil
    @reader_done.receive?
  end

  def closed? : Bool
    @stop.closed?
  end

  def supports?(mode : Int32) : Bool?
    request(Query::Mode, "\e[?#{mode}$p", key: mode.to_s).as?(Int32).try { |state| !state.in?(0, 4) }
  end

  def query_visibility : Nil
    @output.send("\e[?998n")
  end

  def query_color_scheme : Nil
    if features.color_scheme?
      @output.send("\e[?996n")
    else
      @scheme_asked.set(true)
      @output.send("\e]11;?\e\\")
    end
  end

  def window_size(limit : Time::Span = @config.query_timeout) : Event::Size?
    request(Query::Window, "\e[14t", limit).as?(Event::Size)
  end

  def cell_size(limit : Time::Span = @config.query_timeout) : Event::Size?
    request(Query::Cell, "\e[16t", limit).as?(Event::Size)
  end

  private def survey : Feature
    return Feature::All unless @config.detect
    deadline = clock + @config.query_timeout
    waiters = FEATURES.map { |mode| {mode, enqueue(Query::Mode, mode.probe, mode.key, true)} }
    waiters.reduce(Feature::None) do |found, (mode, waiter)|
      state = await(waiter, {deadline - clock, Time::Span.zero}.max).as?(Int32) || 0
      state.in?(0, 4) ? found : found | mode.feature
    end
  end
end
