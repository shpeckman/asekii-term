# src/asekii-term/terminal/dnd.cr
module Asekii::Event
  @[Flags]
  enum Operation
    Copy
    Move
  end

  record Drop, kind : Kind, col : Int32, row : Int32, x : Int32, y : Int32, operations : Operation, mimes : Array(String)? do
    enum Kind
      Move
      Leave
      Land
    end
  end

  record Drag, kind : Kind, col : Int32 = 0, row : Int32 = 0, x : Int32 = 0, y : Int32 = 0, index : Int32 = 0, operation : Operation = Operation::None, canceled : Bool = false, error : String? = nil do
    enum Kind
      Gesture
      Started
      Accepted
      Action
      Dropped
      Finished
      DataRequest
      FileRequest
      Error
    end
  end

  record DropData, data : Bytes, flag : Int32 = 0, error : String? = nil, entry : Bool = false do
    def ok? : Bool
      error.nil?
    end

    def text : String
      String.new(data)
    end

    def remote? : Bool
      !entry && flag == 1
    end

    def symlink? : Bool
      entry && flag == 1
    end

    def directory? : Bool
      entry && flag != 0 && flag != 1
    end

    def handle : Int32
      flag
    end

    def entries : Array(String)
      text.split('\0', remove_empty: true)
    end

    def uris : Array(String)
      text.lines.map(&.strip).reject { |line| line.empty? || line.starts_with?('#') }
    end
  end
end

class Asekii::Terminal
  MACHINE_KEY = "tty-dnd-protocol-machine-id"
  DND         =   72
  WIRE_CHUNK  = 4096

  private class Chain
    getter meta = {} of String => String
    getter text = Bytewire.new(128)
    getter data = Bytewire.new(256)
    @carry   = ""
    @scratch = Bytewire.new(4096)

    def decode(payload : String, sink : IO?, final : Bool) : Nil
      @carry += payload
      size = final ? @carry.bytesize : @carry.bytesize & ~3
      return if size == 0
      encoded = @carry.byte_slice(0, size)
      @carry  = @carry.byte_slice(size)
      if sink
        @scratch.reset
        @scratch.decode64(encoded)
        sink.write(@scratch.written)
      else
        @data.decode64(encoded)
      end
    end
  end

  def self.machine_id : String?
    raw = {% if flag?(:darwin) %}
            `ioreg -rd1 -c IOPlatformExpertDevice`[/"IOPlatformUUID" = "([^"]+)"/, 1]?
          {% elsif flag?(:win32) %}
            `reg query HKLM\\SOFTWARE\\Microsoft\\Cryptography /v MachineGuid`[/REG_SZ\s+(\S+)/, 1]?
          {% else %}
            File.read("/etc/machine-id").rstrip
          {% end %}
    raw.try { |id| "1:#{OpenSSL::HMAC.hexdigest(:sha256, MACHINE_KEY, id)}" }
  rescue IO::Error
    nil
  end

  def self.uri_list(paths : Enumerable(String | Path)) : String
    build do |wire|
      paths.each do |path|
        full = Path.new(path).expand
        wire.str("file://").str(URI.encode_path(full.to_s))
        wire.char('/') if Dir.exists?(full) && !full.to_s.ends_with?('/')
        wire.str("\r\n")
      end
    end
  end

  @chains = {} of String => Chain
  @chain  = ""
  @mux : String
  @accepting = Atomic(Bool).new(false)
  @offering  = Atomic(Bool).new(false)

  def dnd_support(limit : Time::Span = @config.query_timeout) : Hash(String, String)?
    dnd_request(Query::DndSupport, "t=q", limit, probe: true).as?(Hash(String, String))
  end

  def supports_dnd?(limit : Time::Span = @config.query_timeout) : Bool
    !dnd_support(limit).nil?
  end

  def accept_drops(*mimes, remote : Bool = false) : Nil
    @accepting.set(true)
    machine = Asekii::Terminal.machine_id if remote
    exclusive(Family::Dnd) do
      dnd("t=a", mimes.join(' '))
      dnd("t=a:x=1", machine) if machine
    end
  end

  def stop_drops : Nil
    @accepting.set(false)
    dnd("t=A")
  end

  def drop_reply(operation : Event::Operation = Event::Operation::None, *mimes) : Nil
    dnd(keys(':', {'t', 'm'}, {'o', operation.value}), mimes.join(' '))
  end

  def drop_data(index : Int32, entry : Int32 = 0, into : IO? = nil, limit : Time::Span = @config.transfer_timeout) : Event::DropData?
    dnd_request(Query::DropData, keys(':', {'t', 'r'}, {'x', index}, {'y', entry}), limit, "#{index}:#{entry}:0", sink: into).as?(Event::DropData)
  end

  def drop_entry(handle : Int32, index : Int32, into : IO? = nil, limit : Time::Span = @config.transfer_timeout) : Event::DropData?
    dnd_request(Query::DropData, keys(':', {'t', 'r'}, {'Y', handle}, {'x', index}), limit, "#{index}:0:#{handle}", sink: into).as?(Event::DropData)
  end

  def drop_close(handle : Int32) : Nil
    dnd(keys(':', {'t', 'r'}, {'Y', handle}))
  end

  def drop_finish(operation : Event::Operation = Event::Operation::None) : Nil
    dnd("t=r:o=#{operation.value}")
  end

  def drop_save(index : Int32, entry : Int32, destination : Path | String, limit : Time::Span = @config.transfer_timeout) : Bool
    save(Path.new(destination), limit, ->(file : IO) { drop_data(index, entry, file, limit) })
  end

  private def save(destination : Path, limit : Time::Span, fetch : IO -> Event::DropData?) : Bool
    data = File.open(destination, "w") { |file| fetch.call(file) }
    unless data && data.ok?
      File.delete?(destination)
      return false
    end
    return true unless data.symlink? || data.directory?
    listing = File.read(destination)
    File.delete(destination)
    if data.symlink?
      File.symlink(listing, destination)
      return true
    end
    Dir.mkdir_p(destination)
    names = listing.split('\0', remove_empty: true)
    saved = names.each_with_index(1).all? do |name, number|
      next false if name.includes?('/') || name == ".." || name == "."
      save(destination / name, limit, ->(file : IO) { drop_entry(data.handle, number, file, limit) })
    end
    drop_close(data.handle)
    saved
  end

  def offer_drags(remote : Bool = false) : Nil
    @offering.set(true)
    machine = Asekii::Terminal.machine_id if remote
    dnd("t=o:x=1", machine || "")
  end

  def stop_drags : Nil
    @offering.set(false)
    dnd("t=o:x=2")
  end

  def drag_offer(operations : Event::Operation, *mimes : String) : Nil
    dnd(keys(':', {'t', 'o'}, {'o', operations.value}), mimes.join(' '))
  end

  def drag_presend(index : Int32, data : Bytes | IO) : Nil
    dnd_stream(keys(':', {'t', 'p'}, {'x', index}), data)
  end

  def drag_image(number : Int32, data : Bytes | IO, format : Format, width : Int32, height : Int32, opacity : Int32 = 0) : Nil
    dnd_stream(keys(':', {'t', 'p'}, {'x', -number}, {'y', format.value}, {'X', width}, {'Y', height}, {'o', opacity}), data)
  end

  def drag_text(number : Int32, text : String, numerator : Int32 = 1, denominator : Int32 = 1, opacity : Int32 = 0) : Nil
    drag_image(number, text.to_slice, Format::Text, numerator, denominator, opacity)
  end

  def drag_show(index : Int32) : Nil
    dnd(keys(':', {'t', 'P'}, {'x', index}))
  end

  def drag_start(limit : Time::Span = @config.transfer_timeout) : String?
    dnd_request(Query::DragStart, "t=P:x=-1", limit).as?(String)
  end

  def drag_data(index : Int32, data : Bytes | IO) : Nil
    dnd_stream(keys(':', {'t', 'e'}, {'y', index}), data)
  end

  def drag_fail(index : Int32, name : String, description : String? = nil) : Nil
    dnd(keys(':', {'t', 'E'}, {'y', index}), merge(':', name, description || ""))
  end

  def drag_abort(name : String, description : String? = nil) : Nil
    dnd("t=E", merge(':', name, description || ""))
  end

  def drag_cancel : Nil
    dnd("t=E:y=-1")
  end

  def drag_entry(index : Int32, data : Bytes | IO, flag : Int32 = 0, parent : Int32 = 0, child : Int32 = 0) : Nil
    dnd_stream(keys(':', {'t', 'k'}, {'x', index}, {'X', flag}, {'Y', parent}, {'y', child}), data)
  end

  def drag_files(paths : Enumerable(String | Path)) : String
    list = paths.map { |path| Path.new(path).expand.to_s }.to_a
    @serving.send(list)
    Asekii::Terminal.uri_list(list)
  end

  def drag_path(index : Int32, path : Path | String) : Nil
    exclusive(Family::Dnd) do
      queue = Deque({Path, Int32, Int32}).new
      queue << {Path.new(path), 0, 0}
      handle = 1
      while item = queue.shift?
        target, parent, child = item
        info = File.info(target, follow_symlinks: false)
        if info.symlink?
          drag_entry(index, File.readlink(target).to_slice, 1, parent, child)
        elsif info.directory?
          handle += 1
          names = Dir.children(target).select do |name|
            kind = File.info(target / name, follow_symlinks: false)
            kind.file? || kind.directory? || kind.symlink?
          end.sort!
          names.each_with_index(1) { |name, number| queue << {target / name, handle, number} }
          drag_entry(index, names.join('\0').to_slice, handle, parent, child)
        elsif info.file?
          File.open(target) { |file| drag_entry(index, file, 0, parent, child) }
        elsif parent == 0
          drag_abort("EINVAL")
        end
      end
    end
  rescue error : IO::Error
    drag_abort(error.os_error.try(&.to_s) || "EIO")
  end

  private def dnd(meta : String, payload : String = "") : Nil
    exclusive(Family::Dnd) { @output.send(dnd_code(meta, payload)) }
  end

  private def dnd_stream(meta : String, source : Bytes | IO) : Nil
    head = merge(':', meta, @mux)
    exclusive(Family::Dnd) do
      blocks(source) do |chunk, _|
        unless chunk.empty?
          @output.send(Asekii::Terminal.build { |wire| wire.osc(DND).str(head).str(":m=1;").base64(chunk).st })
        end
      end
      @output.send(Asekii::Terminal.build { |wire| wire.osc(DND).str(head).str(":m=0").st })
    end
  end

  private def dnd_request(query : Query, meta : String, limit : Time::Span, key : String = "", probe : Bool = false, sink : IO? = nil) : Reply
    await(exclusive(Family::Dnd) { enqueue(query, dnd_code(meta), key, probe, sink) }, limit)
  end

  private def dnd_code(meta : String, payload : String = "") : String
    head = merge(':', meta, @mux)
    Asekii::Terminal.build do |wire|
      offset = 0
      while payload.bytesize - offset > WIRE_CHUNK
        wire.osc(DND).str(head).str(":m=1;").str(payload.byte_slice(offset, WIRE_CHUNK)).st
        offset += WIRE_CHUNK
      end
      wire.osc(DND).str(head)
      wire.semi.str(payload.byte_slice(offset)) if offset < payload.bytesize
      wire.st
    end
  end

  private def run_server : Nil
    paths = [] of String
    while message = @serving.receive?
      case message
      in Array(String)
        paths = message
      in Int32
        next if paths.empty?
        path = paths[message - 1]?
        path ? drag_path(message, path) : drag_abort("ENOENT")
      end
    end
  rescue Channel::ClosedError
  end

  private def chained(meta : Hash(String, String), payload : String) : Nil
    if type = meta["t"]?
      @chain = type.in?("r", "R") ? "r:#{number(meta, "x")}:#{number(meta, "y")}:#{number(meta, "Y")}" : type
    end
    name  = @chain
    chain = @chains.put_if_absent(name) { Chain.new }
    chain.meta.merge!(meta)
    final = meta["m"]? != "1"
    if chain.meta["t"]? == "r"
      chain.decode(payload, peek(Query::DropData, name.lchop("r:")).try(&.sink), final)
    else
      chain.text.str(payload)
    end
    return unless final
    @chains.delete(name)
    dispatch(chain.meta, String.new(chain.text.written), chain.data.written.dup)
  end

  private def dispatch(meta : Hash(String, String), payload : String, data : Bytes) : Nil
    col = number(meta, "x")
    row = number(meta, "y")
    case type = meta["t"]?
    when "m", "M"
      kind = type == "M" ? Event::Drop::Kind::Land : (col < 0 ? Event::Drop::Kind::Leave : Event::Drop::Kind::Move)
      push Event::Drop.new(kind, col, row, number(meta, "X"), number(meta, "Y"), Event::Operation.new(number(meta, "o") & 3), payload.presence.try(&.split))
    when "r", "R"
      entry = meta.has_key?("y") || meta.has_key?("Y")
      reply = type == "r" ? Event::DropData.new(data, number(meta, "X"), entry: entry) : Event::DropData.new(Bytes.empty, error: payload, entry: entry)
      route(Query::DropData, reply, "#{col}:#{row}:#{number(meta, "Y")}")
    when "o"
      push Event::Drag.new(:gesture, col, row, number(meta, "X"), number(meta, "Y"))
    when "e"
      case col
      when 1 then push Event::Drag.new(:accepted, index: row)
      when 2 then push Event::Drag.new(:action, operation: Event::Operation.new(number(meta, "o") & 3))
      when 3 then push Event::Drag.new(:dropped)
      when 4 then push Event::Drag.new(:finished, canceled: row == 1)
      when 5 then push Event::Drag.new(:data_request, index: row)
      end
    when "E"
      route(Query::DragStart, payload) || push(payload == "OK" ? Event::Drag.new(:started) : Event::Drag.new(:error, error: payload))
    when "k"
      push Event::Drag.new(:file_request, index: col)
      @serving.send(col)
    when "q"
      route(Query::DndSupport, fields(payload))
    end
  end
end
