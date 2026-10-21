# src/asekii-term/terminal/graphics.cr
module Asekii::Event
  record Ack, image : UInt32, number : UInt32, placement : UInt32, message : String do
    def ok? : Bool
      message == "OK"
    end

    def error : String?
      message unless ok?
    end
  end
end

class Asekii::Terminal
  lib LibTerm
    fun shm_open(name : LibC::Char*, flags : LibC::Int, mode : LibC::ModeT) : LibC::Int
  end

  enum Format
    Text         =   0
    Indexed      =   8
    IndexedAlpha =  16
    RGB          =  24
    RGBA         =  32
    PNG          = 100
  end

  enum Medium
    Direct
    File
    TempFile
    SharedMemory
  end

  enum Quiet
    None
    Ok
    All
  end

  enum Delete
    Visible
    Id
    Number
    Cursor
    Frames
    Cell
    CellZ
    Range
    Column
    Row
    Z
  end

  enum Playback
    Stop    = 1
    Loading
    Loop
  end

  MEDIA = {
    Medium::Direct       => 'd',
    Medium::File         => 'f',
    Medium::TempFile     => 't',
    Medium::SharedMemory => 's',
  }

  DELETES = {
    Delete::Visible => 'a',
    Delete::Id      => 'i',
    Delete::Number  => 'n',
    Delete::Cursor  => 'c',
    Delete::Frames  => 'f',
    Delete::Cell    => 'p',
    Delete::CellZ   => 'q',
    Delete::Range   => 'r',
    Delete::Column  => 'x',
    Delete::Row     => 'y',
    Delete::Z       => 'z',
  }

  record Pixels, data : Bytes | IO, format : Format = Format::RGBA, width : Int32 = 0, height : Int32 = 0, medium : Medium = Medium::Direct, compress : Bool = false, size : Int32 = 0, offset : Int32 = 0 do
    def self.png(data : Bytes | IO, compress : Bool = false) : Pixels
      new(data, Format::PNG, compress: compress)
    end

    def self.rgba(data : Bytes | IO, width : Int32, height : Int32, compress : Bool = false) : Pixels
      new(data, Format::RGBA, width, height, compress: compress)
    end

    def self.rgb(data : Bytes | IO, width : Int32, height : Int32, compress : Bool = false) : Pixels
      new(data, Format::RGB, width, height, compress: compress)
    end

    def self.at(path : String, medium : Medium = Medium::File, format : Format = Format::PNG, width : Int32 = 0, height : Int32 = 0, compress : Bool = false, size : Int32 = 0, offset : Int32 = 0) : Pixels
      new(path.to_slice, format, width, height, medium, compress, size, offset)
    end

    def self.temp(data : Bytes, format : Format = Format::PNG, width : Int32 = 0, height : Int32 = 0) : Pixels
      path = File.tempname("tty-graphics-protocol-", ".bin")
      File.write(path, data, perm: 0o600)
      at(path, Medium::TempFile, format, width, height)
    end

    def raster : Raster?
      source = data
      bytes = case source
              in IO then source.getb_to_end
              in Bytes
                if medium.direct?
                  source
                else
                  path = String.new(source)
                  path = "/dev/shm#{path}" if medium.shared_memory?
                  File.read(path).to_slice
                end
              end
      bytes = bytes[offset.clamp(0, bytes.size), size.clamp(0, bytes.size - offset.clamp(0, bytes.size))] if !medium.direct? && size > 0
      case format
      when .rgb?  then Raster.rgb(bytes, width, height)
      when .rgba? then Raster.rgba(bytes, width, height)
      when .png?  then Raster.png(bytes)
      end
    rescue IO::Error | File::Error
      nil
    end

    def self.shared(data : Bytes, format : Format = Format::PNG, width : Int32 = 0, height : Int32 = 0) : Pixels
      name = "/tty-graphics-protocol-#{UUID.random}"
      {% if flag?(:linux) %}
        File.write("/dev/shm#{name}", data, perm: 0o600)
      {% elsif flag?(:win32) %}
        raise NotImplementedError.new("shared memory transmission")
      {% else %}
        fd = LibTerm.shm_open(name, LibC::O_CREAT | LibC::O_EXCL | LibC::O_RDWR, 0o600)
        raise IO::Error.from_errno("shm_open") if fd < 0
        begin
          raise IO::Error.from_errno("ftruncate") if LibC.ftruncate(fd, data.size) != 0
          unless data.empty?
            memory = LibC.mmap(nil, data.size, LibC::PROT_READ | LibC::PROT_WRITE, LibC::MAP_SHARED, fd, 0)
            raise IO::Error.from_errno("mmap") if memory == LibC::MAP_FAILED
            data.copy_to(memory.as(UInt8*), data.size)
            LibC.munmap(memory, data.size)
          end
        ensure
          LibC.close(fd)
        end
      {% end %}
      at(name, Medium::SharedMemory, format, width, height)
    end
  end

  record Placement, id : UInt32 = 0, x : Int32 = 0, y : Int32 = 0, width : Int32 = 0, height : Int32 = 0, offset_x : Int32 = 0, offset_y : Int32 = 0, columns : Int32 = 0, rows : Int32 = 0, z : Int32 = 0, hold_cursor : Bool = false, placeholder : Bool = false, parent : UInt32 = 0, parent_placement : UInt32 = 0, shift_x : Int32 = 0, shift_y : Int32 = 0

  def self.placeholder(id : UInt32, columns : Int32, rows : Int32, placement : UInt32 = 0, compact : Bool = false) : Array(String)
    high = (id >> 24).to_i
    wire = Bytewire.new(128)
    Array.new(rows) do |row|
      wire.reset
      wire.str("\e[38;2;").int3(((id >> 16) & 255).to_i32!).semi.int3(((id >> 8) & 255).to_i32!).semi.int3((id & 255).to_i32!).char('m')
      if placement != 0
        wire.str("\e[58;2;").int3(((placement >> 16) & 255).to_i32!).semi.int3(((placement >> 8) & 255).to_i32!).semi.int3((placement & 255).to_i32!).char('m')
      end
      columns.times do |column|
        wire.char(UnicodePlaceholder::CHAR)
        next if compact && column > 0
        wire.char(UnicodePlaceholder.mark(row))
        next if compact && high == 0
        wire.char(UnicodePlaceholder.mark(column))
        wire.char(UnicodePlaceholder.mark(high)) if high > 0
      end
      wire.str("\e[39m")
      wire.str("\e[59m") if placement != 0
      String.new(wire.written)
    end
  end

  def self.place_code(id : UInt32 = 0, number : UInt32 = 0, placement : Placement = Placement.new, quiet : Quiet = Quiet::None) : String
    build do |wire|
      KittyGraphics.place(wire, id: id, number: number, quiet: quiet.value, placement: placement.id,
        x: placement.x, y: placement.y, width: placement.width, height: placement.height,
        offset_x: placement.offset_x, offset_y: placement.offset_y, columns: placement.columns, rows: placement.rows,
        z: placement.z, hold_cursor: placement.hold_cursor, placeholder: placement.placeholder,
        parent: placement.parent, parent_placement: placement.parent_placement,
        shift_x: placement.shift_x, shift_y: placement.shift_y)
    end
  end

  def self.delete_code(target : Delete = Delete::Visible, free : Bool = false, id : UInt32 = 0, number : UInt32 = 0, placement : UInt32 = 0, x : Int32 = 0, y : Int32 = 0, z : Int32 = 0) : String
    letter = DELETES[target]
    letter = free ? letter.upcase : letter
    build { |wire| KittyGraphics.delete(wire, letter, id: id, number: number, placement: placement, x: x, y: y, z: z) }
  end

  protected def self.place_control(id : UInt32, number : UInt32, placement : Placement, quiet : Quiet) : String
    merge(',', keys(',', {'a', 'p'}, {'i', id}, {'I', number}, {'q', quiet.value}), placed(placement))
  end

  protected def self.placed(placement : Placement) : String
    build { |wire| KittyGraphics.placement_keys(wire, placement: placement.id, x: placement.x, y: placement.y, width: placement.width, height: placement.height, offset_x: placement.offset_x, offset_y: placement.offset_y, columns: placement.columns, rows: placement.rows, z: placement.z, hold_cursor: placement.hold_cursor, placeholder: placement.placeholder, parent: placement.parent, parent_placement: placement.parent_placement, shift_x: placement.shift_x, shift_y: placement.shift_y) }.lchop
  end

  LOCAL_MIN = 16384

  def medium : Medium
    value = @medium.get
    value < 0 ? Medium::Direct : Medium.from_value(value)
  end

  def probe_media(limit : Time::Span = @config.query_timeout) : Medium
    found = Medium::Direct
    {% unless flag?(:win32) %}
      {Medium::SharedMemory, Medium::TempFile}.each do |candidate|
        pixels = begin
          candidate.shared_memory? ? Pixels.shared(Bytes.new(3), Format::RGB, 1, 1) : Pixels.temp(Bytes.new(3), Format::RGB, 1, 1)
        rescue IO::Error | File::Error
          next
        end
        accepted = image_query(pixels, limit: limit).try(&.ok?) || false
        discard(pixels)
        if accepted
          found = candidate
          break
        end
      end
    {% end %}
    @medium.set(found.value)
    found
  end

  def image(pixels : Pixels, id : UInt32 = 0, number : UInt32 = 0, placement : Placement? = nil, quiet : Quiet = Quiet::None, transient : Bool = false, limit : Time::Span = @config.query_timeout) : Event::Ack?
    head, source = load(localize(pixels))
    draw(image_control(head, id, number, placement, quiet, transient), source, id, number, quiet, limit)
  end

  def image_code(pixels : Pixels, id : UInt32 = 0, number : UInt32 = 0, placement : Placement? = nil, quiet : Quiet = Quiet::All, transient : Bool = false) : String
    head, source = load(localize(pixels))
    encode(image_control(head, id, number, placement, quiet, transient), source, quiet)
  end

  def image_query(pixels : Pixels, id : UInt32 = 31, limit : Time::Span = @config.query_timeout) : Event::Ack?
    head, source = load(pixels)
    draw(merge(',', keys(',', {'a', 'q'}, {'i', id}), head), source, id, 0_u32, Quiet::None, limit, probe: true)
  end

  def supports_graphics?(limit : Time::Span = @config.query_timeout) : Bool
    image_query(Pixels.rgb(Bytes.new(3), 1, 1), limit: limit).try(&.ok?) || false
  end

  def supports_indexed?(limit : Time::Span = @config.query_timeout) : Bool
    image_query(Pixels.new(Bytes.new(1), Format::Indexed, 1, 1), limit: limit).try(&.ok?) || false
  end

  ITERM_TERMS = {"iterm", "wezterm", "mintty", "konsole", "rio", "tabby", "warp"}

  def supports_sixel?(limit : Time::Span = @config.query_timeout) : Bool
    attributes(limit).try(&.sixel?) || false
  end

  def image_protocol(limit : Time::Span = @config.query_timeout) : ImageProtocol
    return ImageProtocol::Kitty if supports_graphics?(limit)
    return ImageProtocol::Sixel if supports_sixel?(limit)
    return ImageProtocol::Iterm if identity(limit).try(&.matches?(ITERM_TERMS))
    ImageProtocol::None
  end

  def sixel_code(pixels : Pixels, columns : Int32 = 0, rows : Int32 = 0) : String
    raster = pixels.raster || return ""
    width = @cell_width.get
    height = @cell_height.get
    raster = raster.scale(columns * width, rows * height) if columns > 0 && rows > 0 && width > 0 && height > 0
    raster.to_sixel
  end

  def sixel(pixels : Pixels, columns : Int32 = 0, rows : Int32 = 0) : Nil
    code = sixel_code(pixels, columns, rows)
    @output.send(code) unless code.empty?
  end

  def inline_image_code(pixels : Pixels, columns : Int32 = 0, rows : Int32 = 0) : String
    source = pixels.data
    png = if pixels.format.png? && pixels.medium.direct? && source.is_a?(Bytes)
            source
          else
            pixels.raster.try(&.to_png) || return ""
          end
    Raster.iterm(png, columns, rows)
  end

  def inline_image(pixels : Pixels, columns : Int32 = 0, rows : Int32 = 0) : Nil
    code = inline_image_code(pixels, columns, rows)
    @output.send(code) unless code.empty?
  end

  def place(id : UInt32 = 0, number : UInt32 = 0, placement : Placement = Placement.new, quiet : Quiet = Quiet::None, limit : Time::Span = @config.query_timeout) : Event::Ack?
    draw(Asekii::Terminal.place_control(id, number, placement, quiet), Bytes.empty, id, number, quiet, limit)
  end

  def delete_images(target : Delete = Delete::Visible, free : Bool = false, id : UInt32 = 0, number : UInt32 = 0, placement : UInt32 = 0, x : Int32 = 0, y : Int32 = 0, z : Int32 = 0) : Nil
    code = Asekii::Terminal.delete_code(target, free, id, number, placement, x, y, z)
    exclusive(Family::Graphics) { @output.send(code) }
  end

  def frame(pixels : Pixels, id : UInt32 = 0, number : UInt32 = 0, x : Int32 = 0, y : Int32 = 0, base : Int32 = 0, edit : Int32 = 0, gap : Int32 = 0, replace : Bool = false, background : UInt32 = 0, quiet : Quiet = Quiet::None, limit : Time::Span = @config.query_timeout) : Event::Ack?
    head, source = load(localize(pixels))
    draw(frame_control(head, id, number, x, y, base, edit, gap, replace, background, quiet), source, id, number, quiet, limit, "a=f")
  end

  def frame_code(pixels : Pixels, id : UInt32 = 0, number : UInt32 = 0, x : Int32 = 0, y : Int32 = 0, base : Int32 = 0, edit : Int32 = 0, gap : Int32 = 0, replace : Bool = false, background : UInt32 = 0, quiet : Quiet = Quiet::All) : String
    head, source = load(localize(pixels))
    encode(frame_control(head, id, number, x, y, base, edit, gap, replace, background, quiet), source, quiet, "a=f")
  end

  def animate(id : UInt32 = 0, number : UInt32 = 0, state : Playback? = nil, current : Int32 = 0, loops : Int32 = 0, target : Int32 = 0, gap : Int32 = 0, quiet : Quiet = Quiet::None) : Nil
    code = Asekii::Terminal.animate_code(id, number, state, current, loops, target, gap, quiet)
    exclusive(Family::Graphics) { @output.send(code) }
  end

  def self.animate_code(id : UInt32 = 0, number : UInt32 = 0, state : Playback? = nil, current : Int32 = 0, loops : Int32 = 0, target : Int32 = 0, gap : Int32 = 0, quiet : Quiet = Quiet::All) : String
    control = keys(',', {'a', 'a'}, {'i', id}, {'I', number}, {'q', quiet.value}, {'s', state.try(&.value) || 0}, {'c', current}, {'v', loops}, {'r', target}, {'z', gap})
    build { |wire| wire.apc.char('G').str(control).st }
  end

  def compose(source : Int32, target : Int32, id : UInt32 = 0, number : UInt32 = 0, width : Int32 = 0, height : Int32 = 0, source_x : Int32 = 0, source_y : Int32 = 0, x : Int32 = 0, y : Int32 = 0, replace : Bool = false, quiet : Quiet = Quiet::None, limit : Time::Span = @config.query_timeout) : Event::Ack?
    draw(Asekii::Terminal.compose_control(source, target, id, number, width, height, source_x, source_y, x, y, replace, quiet), Bytes.empty, id, number, quiet, limit)
  end

  def self.compose_code(source : Int32, target : Int32, id : UInt32 = 0, number : UInt32 = 0, width : Int32 = 0, height : Int32 = 0, source_x : Int32 = 0, source_y : Int32 = 0, x : Int32 = 0, y : Int32 = 0, replace : Bool = false, quiet : Quiet = Quiet::All) : String
    control = compose_control(source, target, id, number, width, height, source_x, source_y, x, y, replace, quiet)
    build { |wire| wire.apc.char('G').str(control).st }
  end

  protected def self.compose_control(source : Int32, target : Int32, id : UInt32, number : UInt32, width : Int32, height : Int32, source_x : Int32, source_y : Int32, x : Int32, y : Int32, replace : Bool, quiet : Quiet) : String
    keys(',', {'a', 'c'}, {'i', id}, {'I', number}, {'q', quiet.value}, {'r', source}, {'c', target}, {'w', width}, {'h', height}, {'X', source_x}, {'Y', source_y}, {'x', x}, {'y', y}, {'C', replace})
  end

  private def image_control(head : String, id : UInt32, number : UInt32, placement : Placement?, quiet : Quiet, transient : Bool) : String
    merge(',', keys(',', {'a', placement ? 'T' : 't'}, {'i', id}, {'I', number}, {'q', quiet.value}, {'N', transient}), head, placement ? placed(placement) : "")
  end

  private def frame_control(head : String, id : UInt32, number : UInt32, x : Int32, y : Int32, base : Int32, edit : Int32, gap : Int32, replace : Bool, background : UInt32, quiet : Quiet) : String
    merge(',', keys(',', {'a', 'f'}, {'i', id}, {'I', number}, {'q', quiet.value}, {'x', x}, {'y', y}, {'c', base}, {'r', edit}, {'z', gap}, {'X', replace}, {'C', replace}, {'Y', background}), head)
  end

  private def placed(placement : Placement) : String
    Asekii::Terminal.placed(placement)
  end

  private def localize(pixels : Pixels) : Pixels
    return pixels unless pixels.medium.direct?
    data = pixels.data
    return pixels unless data.is_a?(Bytes) && data.size >= LOCAL_MIN
    case medium
    when .shared_memory? then Pixels.shared(data, pixels.format, pixels.width, pixels.height)
    when .temp_file?     then Pixels.temp(data, pixels.format, pixels.width, pixels.height)
    else                      pixels
    end
  rescue IO::Error | File::Error | NotImplementedError
    pixels
  end

  private def discard(pixels : Pixels) : Nil
    data = pixels.data
    return unless data.is_a?(Bytes)
    path = String.new(data)
    path = "/dev/shm#{path}" if pixels.medium.shared_memory?
    File.delete?(path)
  rescue File::Error
  end

  private def load(pixels : Pixels) : {String, Bytes | IO}
    data = pixels.data
    size = pixels.size
    if pixels.compress && pixels.medium.direct?
      raw = data.is_a?(IO) ? data.getb_to_end : data
      size = raw.size if pixels.format.png?
      packed = IO::Memory.new
      Compress::Zlib::Writer.open(packed, &.write(raw))
      data = packed.to_slice
    end
    control = keys(',', {'f', pixels.format.value}, {'t', MEDIA[pixels.medium]}, {'s', pixels.width}, {'v', pixels.height}, {'S', size}, {'O', pixels.offset}, {'o', pixels.compress ? 'z' : 0})
    {control, data}
  end

  private def draw(control : String, source : Bytes | IO, id : UInt32, number : UInt32, quiet : Quiet, limit : Time::Span, action : String = "", probe : Bool = false) : Event::Ack?
    key = number != 0 ? "I#{number}" : "i#{id}"
    wait = quiet.none? && (id != 0 || number != 0)
    waiter = exclusive(Family::Graphics) do
      pending = nil
      whole = probe ? Bytewire.new(256) : nil
      first = true
      chunks(control, source, quiet, action) do |code|
        if whole
          whole.str(code)
        elsif first && wait
          pending = enqueue(Query::Graphics, code, key)
        else
          @output.send(code)
        end
        first = false
      end
      whole ? enqueue(Query::Graphics, String.new(whole.written), key, true) : pending
    end
    waiter.try { |channel| await(channel, limit).as?(Event::Ack) }
  end

  private def encode(control : String, source : Bytes | IO, quiet : Quiet, action : String = "") : String
    String.build do |text|
      chunks(control, source, quiet, action) { |code| text << code }
    end
  end

  private def chunks(control : String, source : Bytes | IO, quiet : Quiet, action : String, & : String ->) : Nil
    more = merge(',', action, keys(',', {'q', quiet.value}))
    first = true
    blocks(source) do |chunk, last|
      yield Asekii::Terminal.build { |wire|
        wire.apc.char('G').str(merge(',', first ? control : more, first && last ? "" : "m=#{last ? 0 : 1}"))
        wire.semi.base64(chunk) unless chunk.empty?
        wire.st
      }
      first = false
    end
  end
end
