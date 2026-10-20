# src/asekii/terminal/wire.cr
module Asekii::Event
  alias Raw = Key | Mouse | Resize | Focus | Visibility | ColorScheme | Paste | Notification | Drop | Drag | Ack | Resume

  alias Input = Raw | TextInput | KeyCommand | Lock | TypingMetric | KeyGesture | Binding | MouseGesture
end

class Asekii::Terminal
  ST         = "\e\\"
  ATTRIBUTES = "\e[c"
  RAW_CHUNK  = 3072
  POLL       = 100.milliseconds
  SWEEP      = 64
  IDENT      = /\A[a-zA-Z0-9_\-+.]+\z/
  STARTED    = Time.instant

  enum Query
    Shape
    Color
    ClipboardRead
    ClipboardWrite
    Mode
    Attributes
    Window
    Cell
    Graphics
    NotifySupport
    NotifyAlive
    DndSupport
    DropData
    DragStart
    Version
    Device
    Palette
  end

  enum Family
    Clipboard
    Graphics
    Notify
    Dnd
  end

  alias Reply = String | Int32 | Bool | Status | Clipboard | Event::Size | Event::Ack | Event::DropData | Array(String) | Palette | Attributes | Device | Hash(String, String) | Hash(String, Array(String)) | Nil

  record Request, query : Query, key : String, sequence : String, waiter : Channel(Reply), probe : Bool, sink : IO? = nil

  alias Output = String | Request

  protected def self.build(& : Bytewire ->) : String
    wire = Bytewire.new(128)
    yield wire
    String.new(wire.written)
  end

  protected def self.keys(separator : Char, *pairs) : String
    build do |wire|
      pairs.each do |name, value|
        next if value == 0 || value == false
        wire.char(separator) unless wire.empty?
        wire.put(name).byte(0x3d_u8).put(value == true ? 1 : value)
      end
    end
  end

  protected def self.merge(separator : Char, *parts : String) : String
    build do |wire|
      parts.each do |part|
        next if part.empty?
        wire.char(separator) unless wire.empty?
        wire.str(part)
      end
    end
  end

  getter events : Channel(Event::Input)
  getter output : Channel(Output)

  @mutexes : Array(Sync::Mutex)
  @wire    = Sync::Mutex.new
  @waiting = {} of {Query, String} => Deque(Request)

  def print(*objects) : Nil
    @output.send(objects.join)
  end

  def <<(object) : self
    @output.send(object.to_s)
    self
  end

  def write(bytes : Bytes) : Nil
    return if bytes.empty? || @restored.get || @suspended.get
    @wire.synchronize do
      outward(bytes)
      @io.flush
    end
  end

  private def outward(data : String) : Nil
    outward(data.to_slice)
  end

  private def outward(data : Bytes) : Nil
    return if data.empty?
    if passthrough = @passthrough
      passthrough.pass(data, @io)
    else
      @io.write(data)
    end
  end

  private def ident(value : String) : String
    raise ArgumentError.new("invalid identifier: #{value.inspect}") unless value.matches?(IDENT)
    value
  end

  private def exclusive(family : Family, &)
    @mutexes[family.value].synchronize { yield }
  end

  private def blocks(source : Bytes, size : Int32 = RAW_CHUNK, & : Bytes, Bool ->) : Nil
    return yield Bytes.empty, true if source.empty?
    Bytewire.base64_chunks(source, (size // 3) * 4) do |chunk, more|
      yield chunk, !more
    end
  end

  private def blocks(source : IO, size : Int32 = RAW_CHUNK, & : Bytes, Bool ->) : Nil
    held = nil
    each_block(source, size) do |slice|
      held.try { |previous| yield previous, false }
      held = slice.dup
    end
    yield held || Bytes.empty, true
  end

  private def each_block(source : IO, size : Int32, & : Bytes ->) : Nil
    buffer = Bytes.new(size)
    loop do
      filled = 0
      while filled < size
        count = source.read(buffer[filled..])
        break if count == 0
        filled += count
      end
      yield buffer[0, filled] if filled > 0
      break if filled < size
    end
  end

  private def keys(separator : Char, *pairs) : String
    Asekii::Terminal.keys(separator, *pairs)
  end

  private def merge(separator : Char, *parts : String) : String
    Asekii::Terminal.merge(separator, *parts)
  end

  private def request(query : Query, sequence : String, limit : Time::Span = @config.query_timeout, key : String = "", probe : Bool = false) : Reply
    await(enqueue(query, sequence, key, probe), limit)
  end

  private def enqueue(query : Query, sequence : String, key : String = "", probe : Bool = false, sink : IO? = nil) : Channel(Reply)
    waiter = Channel(Reply).new(2)
    @output.send(Request.new(query, key, sequence, waiter, probe, sink))
    waiter
  end

  private def await(waiter : Channel(Reply), limit : Time::Span) : Reply
    select
    when reply = waiter.receive
      reply
    when timeout(limit)
      nil
    end
  ensure
    waiter.close
  end

  private def admit : Nil
    loop do
      select
      when request = @pending.receive?
        return unless request
        @waiting.put_if_absent({request.query, request.key}) { Deque(Request).new } << request
      else
        return
      end
    end
  end

  private def peek(query : Query, key : String = "") : Request?
    admit
    queue = @waiting[{query, key}]? || return
    while request = queue.first?
      return request unless request.waiter.closed?
      queue.shift
    end
  end

  private def sweep : Nil
    @waiting.reject! { |_, queue| queue.all?(&.waiter.closed?) }
  end

  private def route(query : Query, reply : Reply, key : String = "", strict : Bool = false) : Bool
    admit
    slot      = {query, key}
    queue     = @waiting[slot]? || return false
    delivered = false
    while request = queue.shift?
      delivered = deliver(request.waiter, reply)
      break if delivered || strict
    end
    @waiting.delete(slot) if queue.empty?
    delivered
  end

  private def deliver(waiter : Channel(Reply), reply : Reply) : Bool
    return false if waiter.closed?
    waiter.send(reply)
    true
  rescue Channel::ClosedError
    false
  end

  private def run_writer : Nil
    while item = @output.receive?
      transmit(item)
      loop do
        select
        when more = @output.receive?
          break unless more
          transmit(more)
        else
          break
        end
      end
      @wire.synchronize { @io.flush }
    end
  rescue IO::Error | Channel::ClosedError
  ensure
    @output.close
    @writer_done.close
  end

  private def transmit(item : Output) : Nil
    case item
    in String
      @wire.synchronize { outward(item) }
    in Request
      @pending.send(item)
      @pending.send(item.copy_with(query: Query::Attributes, key: "")) if item.probe
      @wire.synchronize do
        outward(item.sequence)
        outward(ATTRIBUTES) if item.probe
      end
    end
  end

  private def run_reader : Nil
    buffer = Bytes.new(4096)
    passes = 0
    until @stop.closed?
      @source.read_timeout = @state.escape? || @state.ss3? ? POLL : nil
      count = begin
        @source.read(buffer)
      rescue IO::TimeoutError
        idle
        next
      end
      break if count == 0
      admit
      buffer[0, count].each { |byte| feed(byte) }
      passes += 1
      sweep if passes % SWEEP == 0
    end
  rescue Channel::ClosedError | IO::Error
  ensure
    @raw.close
    @reader_done.close
  end

  private def push(event : Event::Raw) : Nil
    @raw.send(event)
  end

  private def clock : Time::Span
    Time.instant - STARTED
  end
end
