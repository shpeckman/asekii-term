# src/asekii/render/stroke_images.cr
module Asekii::Render
  class StrokeImages
    FIRST  = 0x00F0_0000_u32
    LAST   = 0x00FF_FFFF_u32
    LIMIT  =            1024
    CHUNK  =            4096
    LEVELS =              15
    GLYPH  = Graphemes.intern(UnicodePlaceholder.cell(0, 0))

    enum Mode : UInt8
      Baked
      Clear
      Indexed
      Tinted
      Mixed
    end

    FORMATS    = {Mode::Baked => 24, Mode::Clear => 32, Mode::Indexed => 16, Mode::Tinted => 32, Mode::Mixed => 24}
    SLOTS      = 248_u32
    FOREGROUND = 249_u32
    BACKGROUND = 248_u32

    alias Tints = Tuple(UInt32, UInt32, UInt32, UInt32)

    UNTINTED = {0_u32, 0_u32, 0_u32, 0_u32}

    record Key, stroke : UInt32, space : BlendSpace, mode : Mode, outside : UInt32, filled : UInt32,
      edged : UInt32, both : UInt32, transient : Bool, tints : Tints = UNTINTED

    alias Offload = Proc(Proc(Bytes), Proc(Bytes, Nil), Nil)

    getter cell_width  : Int32
    getter cell_height : Int32

    property offload  : Offload?
    property landed   : (-> Nil)?
    property? exact   : Bool
    property? indexed : Bool

    def initialize
      @cell_width  = 0
      @cell_height = 0
      @masks       = Sync::Exclusive(Hash({UInt32, Int32, Int32}, Bytes)).new({} of {UInt32, Int32, Int32} => Bytes)
      @quarters    = Sync::Exclusive(Hash({UInt32, Int32, Int32}, Bytes)).new({} of {UInt32, Int32, Int32} => Bytes)
      @lock        = Sync::Mutex.new
      @ids         = {} of Key => UInt32
      @keys        = {} of UInt32 => Key
      @ready       = Set(UInt32).new
      @requests    = [] of {UInt32, Key}
      @queue       = [] of Bytes
      @serial      = FIRST
      @generation  = 0
      @purge       = false
      @offload     = nil
      @landed      = nil
      @exact       = false
      @indexed     = false
    end

    def self.slot(paint : Paint) : UInt32?
      case paint.kind
      when .foreground? then FOREGROUND
      when .background? then BACKGROUND
      when .index?      then paint.value < SLOTS ? paint.value : nil
      end
    end

    def self.level(alpha : Float32) : UInt8
      ((alpha.clamp(0.0_f32, 1.0_f32) * LEVELS).round / LEVELS * 255.0_f32).round.to_u8
    end

    def ready? : Bool
      @cell_width > 0 && @cell_height > 0
    end

    def size : Int32
      @lock.synchronize { @keys.size }
    end

    def pending? : Bool
      @lock.synchronize { !@queue.empty? }
    end

    def resize(width : Int32, height : Int32) : Bool
      return false if width == @cell_width && height == @cell_height
      @lock.synchronize do
        @cell_width  = Math.max(width, 0)
        @cell_height = Math.max(height, 0)
        @generation += 1
        @ids.clear
        @ready.clear
        @requests.clear
        @queue.clear
        @purge = true
      end
      @masks.lock(&.clear)
      @quarters.lock(&.clear)
      true
    end

    def image(key : Key) : UInt32?
      @lock.synchronize do
        if id = @ids[key]?
          next @ready.includes?(id) ? id : nil
        end
        id = allocate
        @ids[key] = id
        @keys[id] = key
        if @offload
          @requests << {id, key}
          next nil
        end
        @queue << encode(id, key, @cell_width, @cell_height)
        @ready << id
        id
      end
    end

    def dispatch : Nil
      offload = @offload || return
      requests = @lock.synchronize do
        taken = @requests.dup
        @requests.clear
        taken
      end
      return if requests.empty?
      width      = @cell_width
      height     = @cell_height
      generation = @generation
      requests.each do |id, key|
        offload.call(-> { encode(id, key, width, height) }, ->(payload : Bytes) { land(generation, id, payload) })
      end
    end

    def upload(target : Bytewire) : Nil
      @lock.synchronize do
        @queue.each { |payload| target.bytes(payload) }
        @queue.clear
      end
    end

    def reap(front : Slice(Tile)) : Array(UInt32)
      return [] of UInt32 unless @purge || size > LIMIT
      live = Set(UInt32).new
      front.each do |tile|
        live << tile.fg if tile.glyph == GLYPH && tile.fg_kind.rgb?
      end
      @lock.synchronize do
        @purge = false
        doomed = @keys.keys.reject! { |id| live.includes?(id) || (@ids[@keys[id]]? == id && !@ready.includes?(id)) }
        doomed.each do |id|
          key = @keys.delete(id)
          @ids.delete(key) if key && @ids[key]? == id
          @ready.delete(id)
        end
        doomed
      end
    end

    def delete(target : Bytewire, ids : Array(UInt32)) : Nil
      return if ids.empty?
      sorted = ids.sort
      first  = sorted.first
      last   = first
      sorted.each_with_index do |id, index|
        next if index == 0
        if id == last + 1_u32
          last = id
          next
        end
        erase(target, first, last)
        first = id
        last  = id
      end
      erase(target, first, last)
    end

    def clear(target : Bytewire) : Nil
      KittyGraphics.delete(target, 'R', x: FIRST.to_i32, y: LAST.to_i32, quiet: true)
      forget
    end

    def forget : Nil
      @lock.synchronize do
        @generation += 1
        @ids.clear
        @keys.clear
        @ready.clear
        @requests.clear
        @queue.clear
        @serial = FIRST
        @purge  = false
      end
    end

    private def erase(target : Bytewire, first : UInt32, last : UInt32) : Nil
      if first == last
        KittyGraphics.delete(target, 'I', id: first, quiet: true)
      else
        KittyGraphics.delete(target, 'R', x: first.to_i32, y: last.to_i32, quiet: true)
      end
    end

    private def land(generation : Int32, id : UInt32, payload : Bytes) : Nil
      live = @lock.synchronize do
        next false unless generation == @generation && @keys.has_key?(id)
        @ready << id
        @queue << payload
        true
      end
      return unless live
      @landed.try(&.call)
    end

    private def allocate : UInt32
      loop do
        id      = @serial
        @serial = id == LAST ? FIRST : id + 1_u32
        return id unless @keys.has_key?(id)
      end
    end

    private def mask(stroke : UInt32, width : Int32, height : Int32) : Bytes
      slot = {stroke, width, height}
      if found = @masks.lock { |masks| masks[slot]? }
        return found
      end
      made = Strokes[stroke].mask(width, height)
      @masks.lock { |masks| masks[slot] ||= made }
    end

    private def quarters(stroke : UInt32, width : Int32, height : Int32) : Bytes
      shape = Strokes.intern(Strokes[stroke].shape)
      slot  = {shape, width, height}
      if found = @quarters.lock { |cache| cache[slot]? }
        return found
      end
      made = Strokes[shape].quarters(width, height)
      @quarters.lock { |cache| cache[slot] ||= made }
    end

    private def encode(id : UInt32, key : Key, width : Int32, height : Int32) : Bytes
      data = case key.mode
             in .clear?   then clear_pixels(key, width, height)
             in .baked?   then baked_pixels(key, width, height)
             in .indexed? then indexed_pixels(key, width, height)
             in .tinted?  then tinted_pixels(key, width, height)
             in .mixed?   then mixed_pixels(key, width, height)
             end
      packed = IO::Memory.new
      Compress::Zlib::Writer.open(packed, &.write(data))
      wire  = Bytewire.new(packed.size * 4 // 3 + 256)
      first = true
      Bytewire.base64_chunks(packed.to_slice, CHUNK) do |chunk, more|
        wire.apc.char('G')
        if first
          wire.str("a=T,U=1,q=2,o=z,f=").int(FORMATS[key.mode]).str(",s=").int(width).str(",v=").int(height)
          wire.str(",i=").int(id).str(",c=1,r=1")
          wire.str(",N=1") if key.transient
          wire.str(",m=1") if more
        else
          wire.str("q=2,m=").int(more ? 1 : 0)
        end
        wire.semi.base64(chunk).st
        first = false
      end
      wire.written.dup
    end

    private def baked_pixels(key : Key, width : Int32, height : Int32) : Bytes
      mask    = mask(key.stroke, width, height)
      space   = key.space
      outside = ColorSpace.coords(key.outside, space)
      filled  = ColorSpace.coords(key.filled, space)
      edged   = ColorSpace.coords(key.edged, space)
      both    = ColorSpace.coords(key.both, space)
      shades  = {} of UInt16 => UInt32
      count   = width * height
      data    = Bytes.new(count * 3)
      count.times do |index|
        s     = mask.unsafe_fetch(index * 2)
        f     = mask.unsafe_fetch(index * 2 + 1)
        shade = shades[(s.to_u16 << 8) | f] ||= baked(key, s, f, outside, filled, edged, both)
        data.unsafe_put(index * 3, ColorSpace.red(shade))
        data.unsafe_put(index * 3 + 1, ColorSpace.green(shade))
        data.unsafe_put(index * 3 + 2, ColorSpace.blue(shade))
      end
      data
    end

    private def baked(key : Key, s : UInt8, f : UInt8, outside : ColorSpace::Triple, filled : ColorSpace::Triple,
                      edged : ColorSpace::Triple, both : ColorSpace::Triple) : UInt32
      if s == 0_u8
        return key.outside if f == 0_u8
        return key.filled if f == 255_u8
      elsif s == 255_u8
        return key.edged if f == 0_u8
        return key.both if f == 255_u8
      end
      across = f / 255.0_f32
      down   = s / 255.0_f32
      plain  = ColorSpace.lerp(outside, filled, across)
      inked  = ColorSpace.lerp(edged, both, across)
      ColorSpace.rgb(ColorSpace.lerp(plain, inked, down), key.space)
    end

    private def indexed_pixels(key : Key, width : Int32, height : Int32) : Bytes
      mask  = mask(key.stroke, width, height)
      slot  = (key.edged >> 8).to_u8!
      inked = (key.edged & 0xFF_u32).to_i32
      count = width * height
      data  = Bytes.new(count * 2)
      count.times do |index|
        data.unsafe_put(index * 2, slot)
        data.unsafe_put(index * 2 + 1, (mask.unsafe_fetch(index * 2).to_i32 * inked // 255).to_u8)
      end
      data
    end

    private def clear_pixels(key : Key, width : Int32, height : Int32) : Bytes
      mask   = mask(key.stroke, width, height)
      space  = key.space
      ink    = ColorSpace.coords(key.edged >> 8, space)
      fill   = ColorSpace.coords(key.filled >> 8, space)
      inked  = (key.edged & 0xFF_u32).to_f32 / 255.0_f32
      filled = (key.filled & 0xFF_u32).to_f32 / 255.0_f32
      shades = {} of UInt16 => UInt32
      count  = width * height
      data   = Bytes.new(count * 4)
      count.times do |index|
        s     = mask.unsafe_fetch(index * 2)
        f     = mask.unsafe_fetch(index * 2 + 1)
        shade = shades[(s.to_u16 << 8) | f] ||= clear(s, f, ink, fill, inked, filled, space)
        data.unsafe_put(index * 4, (shade >> 24).to_u8!)
        data.unsafe_put(index * 4 + 1, (shade >> 16).to_u8!)
        data.unsafe_put(index * 4 + 2, (shade >> 8).to_u8!)
        data.unsafe_put(index * 4 + 3, shade.to_u8!)
      end
      data
    end

    private def tinted_pixels(key : Key, width : Int32, height : Int32) : Bytes
      cover  = quarters(key.stroke, width, height)
      space  = key.space
      ink    = ColorSpace.coords(key.edged >> 8, space)
      inked  = (key.edged & 0xFF_u32).to_f32 / 255.0_f32
      tints  = StaticArray(ColorSpace::Triple, 4).new { |slot| ColorSpace.coords(key.tints[slot] >> 8, space) }
      levels = StaticArray(Float32, 4).new { |slot| (key.tints[slot] & 0xFF_u32).to_f32 / 255.0_f32 }
      shades = {} of UInt64 => UInt32
      count  = width * height
      data   = Bytes.new(count * 4)
      count.times do |index|
        shade = shades[packed(cover, index)] ||= tinted(cover, index, ink, inked, tints, levels, space)
        data.unsafe_put(index * 4, (shade >> 24).to_u8!)
        data.unsafe_put(index * 4 + 1, (shade >> 16).to_u8!)
        data.unsafe_put(index * 4 + 2, (shade >> 8).to_u8!)
        data.unsafe_put(index * 4 + 3, shade.to_u8!)
      end
      data
    end

    private def tinted(cover : Bytes, index : Int32, ink : ColorSpace::Triple, inked : Float32,
                       tints : StaticArray(ColorSpace::Triple, 4), levels : StaticArray(Float32, 4),
                       space : BlendSpace) : UInt32
      top    = cover.unsafe_fetch(index * 5) / 255.0_f32 * inked
      keep   = 1.0_f32 - top
      red    = top * ink[0]
      green  = top * ink[1]
      blue   = top * ink[2]
      amount = 0.0_f32
      4.times do |slot|
        share = cover.unsafe_fetch(index * 5 + 1 + slot) / 255.0_f32 * levels[slot]
        next if share <= 0.0_f32
        tint = tints[slot]
        amount += share
        red += keep * share * tint[0]
        green += keep * share * tint[1]
        blue += keep * share * tint[2]
      end
      total = top + keep * Math.min(amount, 1.0_f32)
      return 0_u32 if total <= 0.0_f32
      alpha = (total * 255.0_f32).round.clamp(0.0_f32, 255.0_f32).to_u32
      (ColorSpace.rgb({red / total, green / total, blue / total}, space) << 8) | alpha
    end

    private def mixed_pixels(key : Key, width : Int32, height : Int32) : Bytes
      cover   = quarters(key.stroke, width, height)
      space   = key.space
      outside = ColorSpace.coords(key.outside, space)
      ink     = ColorSpace.coords(key.edged, space)
      edge    = key.both.to_f32 / 255.0_f32
      tints   = StaticArray(ColorSpace::Triple, 4).new { |slot| ColorSpace.coords(key.tints[slot], space) }
      shades  = {} of UInt64 => UInt32
      count   = width * height
      data    = Bytes.new(count * 3)
      count.times do |index|
        shade = shades[packed(cover, index)] ||= mixed(cover, index, outside, ink, edge, tints, space)
        data.unsafe_put(index * 3, ColorSpace.red(shade))
        data.unsafe_put(index * 3 + 1, ColorSpace.green(shade))
        data.unsafe_put(index * 3 + 2, ColorSpace.blue(shade))
      end
      data
    end

    private def mixed(cover : Bytes, index : Int32, outside : ColorSpace::Triple, ink : ColorSpace::Triple,
                      edge : Float32, tints : StaticArray(ColorSpace::Triple, 4), space : BlendSpace) : UInt32
      rest  = 1.0_f32
      red   = 0.0_f32
      green = 0.0_f32
      blue  = 0.0_f32
      4.times do |slot|
        share = cover.unsafe_fetch(index * 5 + 1 + slot) / 255.0_f32
        next if share <= 0.0_f32
        tint = tints[slot]
        rest -= share
        red += share * tint[0]
        green += share * tint[1]
        blue += share * tint[2]
      end
      rest = Math.max(rest, 0.0_f32)
      base = {red + rest * outside[0], green + rest * outside[1], blue + rest * outside[2]}
      ColorSpace.rgb(ColorSpace.lerp(base, ink, cover.unsafe_fetch(index * 5) / 255.0_f32 * edge), space)
    end

    @[AlwaysInline]
    private def packed(cover : Bytes, index : Int32) : UInt64
      offset = index * 5
      value  = 0_u64
      5.times { |step| value = (value << 8) | cover.unsafe_fetch(offset + step) }
      value
    end

    private def clear(s : UInt8, f : UInt8, ink : ColorSpace::Triple, fill : ColorSpace::Triple, inked : Float32,
                      filled : Float32, space : BlendSpace) : UInt32
      top   = s / 255.0_f32 * inked
      under = f / 255.0_f32 * filled
      rest  = under * (1.0_f32 - top)
      total = top + rest
      return 0_u32 if total <= 0.0_f32
      mixed = ColorSpace.lerp(fill, ink, top / total)
      alpha = (total * 255.0_f32).round.clamp(0.0_f32, 255.0_f32).to_u32
      (ColorSpace.rgb(mixed, space) << 8) | alpha
    end
  end
end
