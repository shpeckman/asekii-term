# src/asekii-term/common/raster.cr
require "bytewire"
require "compress/zlib"
require "digest/crc32"

module Asekii
  enum ImageProtocol
    None
    Kitty
    Sixel
    Iterm

    def inline? : Bool
      sixel? || iterm?
    end
  end

  struct Raster
    PNG_SIGNATURE = Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    PNG_CHANNELS  = {0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}
    ADAM7         = { {0, 0, 8, 8}, {4, 0, 8, 8}, {0, 4, 4, 8}, {2, 0, 4, 4}, {0, 2, 2, 4}, {1, 0, 2, 2}, {0, 1, 1, 2} }
    COLORS        =    255
    OPAQUE        = 128_u8
    CLEAR         = 255_u8
    SHADES        =  32768
    RUN_MIN       =      4

    getter data   : Bytes
    getter width  : Int32
    getter height : Int32

    def initialize(@data : Bytes, @width : Int32, @height : Int32)
    end

    def same?(other : Raster?) : Bool
      return false unless other
      @data.to_unsafe == other.data.to_unsafe && @data.size == other.data.size && @width == other.width && @height == other.height
    end

    def self.rgba(data : Bytes, width : Int32, height : Int32) : Raster?
      return if width <= 0 || height <= 0 || data.size < width * height * 4
      new(data[0, width * height * 4], width, height)
    end

    def self.rgb(data : Bytes, width : Int32, height : Int32) : Raster?
      return if width <= 0 || height <= 0 || data.size < width * height * 3
      pixels = Bytes.new(width * height * 4)
      (width * height).times do |index|
        pixels[index * 4] = data.unsafe_fetch(index * 3)
        pixels[index * 4 + 1] = data.unsafe_fetch(index * 3 + 1)
        pixels[index * 4 + 2] = data.unsafe_fetch(index * 3 + 2)
        pixels[index * 4 + 3] = 255_u8
      end
      new(pixels, width, height)
    end

    def self.png(source : Bytes) : Raster?
      return unless source.size > 8 && source[0, 8] == PNG_SIGNATURE
      offset    = 8
      width     = 0
      height    = 0
      depth     = 0
      kind      = -1
      interlace = 0
      palette   = Bytes.empty
      alphas    = Bytes.empty
      key       = Bytes.empty
      packed    = IO::Memory.new
      while offset + 8 <= source.size
        length = IO::ByteFormat::BigEndian.decode(UInt32, source[offset, 4]).to_i
        name   = String.new(source[offset + 4, 4])
        start  = offset + 8
        return if length < 0 || start + length > source.size
        body = source[start, length]
        case name
        when "IHDR"
          return if length < 13
          width     = IO::ByteFormat::BigEndian.decode(UInt32, body[0, 4]).to_i
          height    = IO::ByteFormat::BigEndian.decode(UInt32, body[4, 4]).to_i
          depth     = body[8].to_i
          kind      = body[9].to_i
          interlace = body[12].to_i
        when "PLTE" then palette = body
        when "tRNS"
          kind == 3 ? (alphas = body) : (key = body)
        when "IDAT" then packed.write(body)
        when "IEND" then break
        end
        offset = start + length + 4
      end
      channels = PNG_CHANNELS[kind]? || return
      return if width <= 0 || height <= 0 || !depth.in?(1, 2, 4, 8, 16)
      return if depth < 8 && !kind.in?(0, 3)
      return if depth == 16 && kind == 3
      inflated = Compress::Zlib::Reader.open(IO::Memory.new(packed.to_slice)) { |reader| reader.getb_to_end }
      pixels   = Bytes.new(width * height * 4)
      bits     = channels * depth
      step     = Math.max(bits // 8, 1)
      cursor   = 0
      passes   = interlace == 1 ? ADAM7 : { {0, 0, 1, 1} }
      passes.each do |(left, top, dx, dy)|
        cols = left >= width ? 0 : (width - left + dx - 1) // dx
        rows = top >= height ? 0 : (height - top + dy - 1) // dy
        next if cols == 0 || rows == 0
        stride   = (cols * bits + 7) // 8
        previous = Bytes.new(stride)
        current  = Bytes.new(stride)
        rows.times do |row|
          return if cursor + 1 + stride > inflated.size
          filter = inflated[cursor]
          inflated[cursor + 1, stride].copy_to(current)
          cursor += 1 + stride
          unfilter(filter, current, previous, step) || return
          y = top + row * dy
          cols.times do |col|
            x = left + col * dx
            texel(current, col, depth, kind, palette, alphas, key, pixels, (y * width + x) * 4)
          end
          previous, current = current, previous
        end
      end
      new(pixels, width, height)
    rescue IO::Error | Compress::Zlib::Error | IndexError
      nil
    end

    private def self.unfilter(filter : UInt8, row : Bytes, above : Bytes, step : Int32) : Bool
      case filter
      when 0
      when 1
        (step...row.size).each { |index| row[index] = row[index] &+ row[index - step] }
      when 2
        row.size.times { |index| row[index] = row[index] &+ above[index] }
      when 3
        row.size.times do |index|
          left = index >= step ? row[index - step].to_i : 0
          row[index] = row[index] &+ ((left + above[index].to_i) // 2).to_u8
        end
      when 4
        row.size.times do |index|
          left   = index >= step ? row[index - step].to_i : 0
          corner = index >= step ? above[index - step].to_i : 0
          row[index] = row[index] &+ paeth(left, above[index].to_i, corner).to_u8
        end
      else
        return false
      end
      true
    end

    private def self.paeth(left : Int32, up : Int32, corner : Int32) : Int32
      guess = left + up - corner
      a     = (guess - left).abs
      b     = (guess - up).abs
      c     = (guess - corner).abs
      a <= b && a <= c ? left : b <= c ? up : corner
    end

    private def self.sample(row : Bytes, index : Int32, depth : Int32) : Int32
      case depth
      when  8 then row[index].to_i
      when 16 then (row[index * 2].to_i << 8) | row[index * 2 + 1].to_i
      else
        bit = index * depth
        (row[bit >> 3].to_i >> (8 - depth - (bit & 7))) & ((1 << depth) - 1)
      end
    end

    private def self.texel(row : Bytes, col : Int32, depth : Int32, kind : Int32, palette : Bytes, alphas : Bytes,
                           key : Bytes, pixels : Bytes, at : Int32) : Nil
      shift = depth == 16 ? 8 : 0
      peak  = (1 << depth) - 1
      case kind
      when 0
        value = sample(row, col, depth)
        gray  = depth < 8 ? value * 255 // peak : value >> shift
        clear = key.size >= 2 && value == ((key[0].to_i << 8) | key[1].to_i)
        put(pixels, at, gray, gray, gray, clear ? 0 : 255)
      when 2
        r = sample(row, col * 3, depth)
        g = sample(row, col * 3 + 1, depth)
        b = sample(row, col * 3 + 2, depth)
        clear = key.size >= 6 && r == ((key[0].to_i << 8) | key[1].to_i) &&
                g == ((key[2].to_i << 8) | key[3].to_i) && b == ((key[4].to_i << 8) | key[5].to_i)
        put(pixels, at, r >> shift, g >> shift, b >> shift, clear ? 0 : 255)
      when 3
        index = sample(row, col, depth)
        if index * 3 + 2 < palette.size
          alpha = index < alphas.size ? alphas[index].to_i : 255
          put(pixels, at, palette[index * 3].to_i, palette[index * 3 + 1].to_i, palette[index * 3 + 2].to_i, alpha)
        end
      when 4
        gray = sample(row, col * 2, depth) >> shift
        put(pixels, at, gray, gray, gray, sample(row, col * 2 + 1, depth) >> shift)
      when 6
        put(pixels, at, sample(row, col * 4, depth) >> shift, sample(row, col * 4 + 1, depth) >> shift,
          sample(row, col * 4 + 2, depth) >> shift, sample(row, col * 4 + 3, depth) >> shift)
      end
    end

    private def self.put(pixels : Bytes, at : Int32, r : Int32, g : Int32, b : Int32, a : Int32) : Nil
      pixels[at] = r.to_u8!
      pixels[at + 1] = g.to_u8!
      pixels[at + 2] = b.to_u8!
      pixels[at + 3] = a.to_u8!
    end

    def self.crop(data : Bytes, width : Int32, x : Int32, y : Int32, cols : Int32, rows : Int32, channels : Int32) : Bytes
      bytes  = Bytes.new(cols * rows * channels)
      stride = cols * channels
      rows.times do |row|
        source = ((y + row) * width + x) * channels
        data[source, stride].copy_to(bytes[row * stride, stride])
      end
      bytes
    end

    def crop(x : Int32, y : Int32, width : Int32, height : Int32) : Raster
      left = x.clamp(0, @width - 1)
      top  = y.clamp(0, @height - 1)
      cols = width.clamp(1, @width - left)
      rows = height.clamp(1, @height - top)
      return self if left == 0 && top == 0 && cols == @width && rows == @height
      Raster.new(Raster.crop(@data, @width, left, top, cols, rows, 4), cols, rows)
    end

    def scale(width : Int32, height : Int32) : Raster
      width  = Math.max(width, 1)
      height = Math.max(height, 1)
      return self if width == @width && height == @height
      wide = Slice(Float32).new(@width * @height * 4)
      (@width * @height).times do |index|
        alpha = @data.unsafe_fetch(index * 4 + 3) / 255.0_f32
        wide[index * 4] = @data.unsafe_fetch(index * 4) * alpha
        wide[index * 4 + 1] = @data.unsafe_fetch(index * 4 + 1) * alpha
        wide[index * 4 + 2] = @data.unsafe_fetch(index * 4 + 2) * alpha
        wide[index * 4 + 3] = alpha * 255.0_f32
      end
      across = Raster.resample(wide, @width, @height, width, true)
      down   = Raster.resample(across, width, @height, height, false)
      pixels = Bytes.new(width * height * 4)
      (width * height).times do |index|
        alpha = down[index * 4 + 3]
        if alpha <= 0.0_f32
          next
        end
        lift = 255.0_f32 / alpha
        pixels[index * 4] = (down[index * 4] * lift).round.clamp(0, 255).to_u8
        pixels[index * 4 + 1] = (down[index * 4 + 1] * lift).round.clamp(0, 255).to_u8
        pixels[index * 4 + 2] = (down[index * 4 + 2] * lift).round.clamp(0, 255).to_u8
        pixels[index * 4 + 3] = alpha.round.clamp(0, 255).to_u8
      end
      Raster.new(pixels, width, height)
    end

    protected def self.resample(source : Slice(Float32), cols : Int32, rows : Int32, size : Int32, horizontal : Bool) : Slice(Float32)
      length  = horizontal ? cols : rows
      ratio   = length / size
      support = Math.max(ratio, 1.0)
      target  = horizontal ? Slice(Float32).new(size * rows * 4) : Slice(Float32).new(cols * size * 4)
      size.times do |position|
        center = (position + 0.5) * ratio - 0.5
        first  = Math.max((center - support).floor.to_i + 1, 0)
        last   = Math.min((center + support).ceil.to_i - 1, length - 1)
        last   = first if last < first
        weights = Array(Float32).new(last - first + 1) do |offset|
          distance = ((first + offset - center) / support).abs
          Math.max(1.0 - distance, 0.0).to_f32
        end
        total = weights.sum
        if total <= 0.0_f32
          weights = Array(Float32).new(last - first + 1, 0.0_f32)
          weights[(center.round.to_i - first).clamp(0, weights.size - 1)] = 1.0_f32
          total = 1.0_f32
        end
        other = horizontal ? rows : cols
        other.times do |line|
          r = g = b = a = 0.0_f32
          weights.each_with_index do |weight, offset|
            next if weight == 0.0_f32
            at = horizontal ? (line * cols + first + offset) * 4 : ((first + offset) * cols + line) * 4
            r += source.unsafe_fetch(at) * weight
            g += source.unsafe_fetch(at + 1) * weight
            b += source.unsafe_fetch(at + 2) * weight
            a += source.unsafe_fetch(at + 3) * weight
          end
          at = horizontal ? (line * size + position) * 4 : (position * cols + line) * 4
          target[at] = r / total
          target[at + 1] = g / total
          target[at + 2] = b / total
          target[at + 3] = a / total
        end
      end
      target
    end

    def to_png : Bytes
      rows = IO::Memory.new(@height * (@width * 4 + 1))
      @height.times do |row|
        rows.write_byte(0_u8)
        rows.write(@data[row * @width * 4, @width * 4])
      end
      packed = IO::Memory.new
      Compress::Zlib::Writer.open(packed) { |writer| writer.write(rows.to_slice) }
      header = IO::Memory.new(13)
      header.write_bytes(@width.to_u32, IO::ByteFormat::BigEndian)
      header.write_bytes(@height.to_u32, IO::ByteFormat::BigEndian)
      header.write(Bytes[8, 6, 0, 0, 0])
      result = IO::Memory.new
      result.write(PNG_SIGNATURE)
      Raster.chunk(result, "IHDR", header.to_slice)
      Raster.chunk(result, "IDAT", packed.to_slice)
      Raster.chunk(result, "IEND", Bytes.empty)
      result.to_slice
    end

    protected def self.chunk(io : IO, name : String, body : Bytes) : Nil
      io.write_bytes(body.size.to_u32, IO::ByteFormat::BigEndian)
      io.write(name.to_slice)
      io.write(body)
      crc = Digest::CRC32.update(name.to_slice, Digest::CRC32.initial)
      crc = Digest::CRC32.update(body, crc) unless body.empty?
      io.write_bytes(crc, IO::ByteFormat::BigEndian)
    end

    def to_sixel : String
      wire = Bytewire.new(Math.max(@width * @height // 2, 256))
      sixel(wire)
      String.new(wire.written)
    end

    def sixel(wire : Bytewire) : Nil
      palette, indices = quantize
      wire.dcs.str("0;1;0q\"1;1;").int(@width).semi.int(@height)
      palette.each_with_index do |rgb, index|
        wire.char('#').int(index).str(";2;")
          .int(Raster.percent(rgb >> 16)).semi.int(Raster.percent(rgb >> 8)).semi.int(Raster.percent(rgb))
      end
      count = palette.size
      masks = Bytes.new(Math.max(count, 1) * @width)
      used  = Slice(Bool).new(Math.max(count, 1), false)
      order = [] of Int32
      bands = (@height + 5) // 6
      bands.times do |band|
        6.times do |line|
          y = band * 6 + line
          break if y >= @height
          bit = (1 << line).to_u8
          @width.times do |x|
            index = indices.unsafe_fetch(y * @width + x)
            next if index == CLEAR
            slot = index.to_i
            unless used[slot]
              used[slot] = true
              order << slot
            end
            masks[slot * @width + x] |= bit
          end
        end
        order.each_with_index do |slot, position|
          wire.char('$') unless position == 0
          wire.char('#').int(slot)
          Raster.runs(wire, masks[slot * @width, @width])
          masks[slot * @width, @width].fill(0_u8)
          used[slot] = false
        end
        order.clear
        wire.char('-') unless band == bands - 1
      end
      wire.st
    end

    protected def self.percent(channel : UInt32) : Int32
      ((channel & 0xff) * 100 + 127).to_i // 255
    end

    protected def self.runs(wire : Bytewire, row : Bytes) : Nil
      stop = row.size
      while stop > 0 && row[stop - 1] == 0
        stop -= 1
      end
      index = 0
      while index < stop
        value = row[index]
        count = 1
        while index + count < stop && row[index + count] == value
          count += 1
        end
        glyph = (value &+ 63_u8).unsafe_chr
        if count >= RUN_MIN
          wire.char('!').int(count).char(glyph)
        else
          count.times { wire.char(glyph) }
        end
        index += count
      end
    end

    private struct Box
      getter shades : Array(Int32)
      getter weight : Int64
      getter axis   : Int32
      getter score  : Int64

      def initialize(@shades : Array(Int32), counts : Slice(Int32))
        @weight = @shades.sum(0_i64) { |shade| counts[shade].to_i64 }
        lows    = StaticArray(Int32, 3).new(31)
        highs   = StaticArray(Int32, 3).new(0)
        @shades.each do |shade|
          3.times do |axis|
            value = Raster.channel(shade, axis)
            lows[axis] = value if value < lows[axis]
            highs[axis] = value if value > highs[axis]
          end
        end
        @axis  = (0..2).max_by { |axis| highs[axis] - lows[axis] }
        spread = highs[@axis] - lows[@axis]
        @score = @shades.size < 2 ? 0_i64 : @weight * (spread + 1)
      end
    end

    private def quantize : Tuple(Array(UInt32), Bytes)
      counts = Slice(Int32).new(SHADES, 0)
      sums   = Slice(Int64).new(SHADES * 3, 0_i64)
      pixels = @width * @height
      pixels.times do |index|
        next if @data.unsafe_fetch(index * 4 + 3) < OPAQUE
        r     = @data.unsafe_fetch(index * 4).to_i
        g     = @data.unsafe_fetch(index * 4 + 1).to_i
        b     = @data.unsafe_fetch(index * 4 + 2).to_i
        shade = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
        counts[shade] += 1
        sums[shade * 3] += r
        sums[shade * 3 + 1] += g
        sums[shade * 3 + 2] += b
      end
      present = (0...SHADES).select { |shade| counts[shade] > 0 }
      boxes   = present.empty? ? [] of Box : [Box.new(present, counts)]
      while boxes.size < COLORS
        best = boxes.each_index.max_by? { |position| boxes[position].score } || break
        break if boxes[best].score == 0
        box    = boxes.delete_at(best)
        axis   = box.axis
        shades = box.shades.sort_by { |shade| Raster.channel(shade, axis) }
        seen   = 0_i64
        cut    = 1
        shades.each_with_index do |shade, position|
          seen += counts[shade]
          if seen * 2 >= box.weight
            cut = (position + 1).clamp(1, shades.size - 1)
            break
          end
        end
        boxes << Box.new(shades[0, cut], counts)
        boxes << Box.new(shades[cut..], counts)
      end
      table   = Slice(UInt8).new(SHADES, CLEAR)
      palette = [] of UInt32
      boxes.each do |box|
        r = g = b = 0_i64
        box.shades.each do |shade|
          r += sums[shade * 3]
          g += sums[shade * 3 + 1]
          b += sums[shade * 3 + 2]
        end
        slot = palette.size.to_u8
        box.shades.each { |shade| table[shade] = slot }
        weight = Math.max(box.weight, 1_i64)
        palette << (((r // weight).to_u32 << 16) | ((g // weight).to_u32 << 8) | (b // weight).to_u32)
      end
      indices = Bytes.new(pixels, CLEAR)
      pixels.times do |index|
        next if @data.unsafe_fetch(index * 4 + 3) < OPAQUE
        r = @data.unsafe_fetch(index * 4).to_i
        g = @data.unsafe_fetch(index * 4 + 1).to_i
        b = @data.unsafe_fetch(index * 4 + 2).to_i
        indices[index] = table[((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)]
      end
      {palette, indices}
    end

    protected def self.channel(shade : Int32, axis : Int32) : Int32
      (shade >> (10 - axis * 5)) & 31
    end

    def self.iterm(png : Bytes, columns : Int32 = 0, rows : Int32 = 0) : String
      wire = Bytewire.new(Bytewire.bound_base64(png) + 160)
      wire.osc(1337).str("File=inline=1;size=").int(png.size)
      wire.str(";width=").str(columns > 0 ? columns.to_s : "auto")
      wire.str(";height=").str(rows > 0 ? rows.to_s : "auto")
      wire.str(";preserveAspectRatio=0;doNotMoveCursor=1:").base64(png).byte(0x07_u8)
      String.new(wire.written)
    end
  end
end
