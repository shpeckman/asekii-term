# src/asekii/render/bitmap.cr
module Asekii::Render
  class Bitmap
    record Rect, x : Int32, y : Int32, width : Int32, height : Int32

    getter width  : Int32
    getter height : Int32
    getter data   : Bytes

    def initialize(width : Int32 = 0, height : Int32 = 0)
      @width  = Math.max(width, 0)
      @height = Math.max(height, 0)
      @data   = Bytes.new(@width * @height * 4)
    end

    def self.rgba(rgb : UInt32, alpha : UInt8 = 255_u8) : UInt32
      ((rgb & 0xFFFFFF_u32) << 8) | alpha.to_u32
    end

    def resize(width : Int32, height : Int32) : Bool
      width  = Math.max(width, 0)
      height = Math.max(height, 0)
      return false if width == @width && height == @height
      @width  = width
      @height = height
      @data   = Bytes.new(@width * @height * 4)
      true
    end

    def empty? : Bool
      @width == 0 || @height == 0
    end

    def clear(rgba : UInt32 = 0_u32) : Nil
      if rgba == 0_u32
        @data.fill(0_u8)
      else
        fill(0, 0, @width, @height, rgba)
      end
    end

    def copy_from(other : Bitmap) : Nil
      resize(other.width, other.height)
      other.data.copy_to(@data)
    end

    def ==(other : Bitmap) : Bool
      @width == other.width && @height == other.height && @data == other.data
    end

    @[AlwaysInline]
    def [](x : Int32, y : Int32) : UInt32
      return 0_u32 unless 0 <= x < @width && 0 <= y < @height
      at = (y * @width + x) * 4
      (@data.unsafe_fetch(at).to_u32 << 24) | (@data.unsafe_fetch(at + 1).to_u32 << 16) |
        (@data.unsafe_fetch(at + 2).to_u32 << 8) | @data.unsafe_fetch(at + 3).to_u32
    end

    @[AlwaysInline]
    def []=(x : Int32, y : Int32, rgba : UInt32) : UInt32
      return rgba unless 0 <= x < @width && 0 <= y < @height
      at = (y * @width + x) * 4
      @data.unsafe_put(at, (rgba >> 24).to_u8!)
      @data.unsafe_put(at + 1, (rgba >> 16).to_u8!)
      @data.unsafe_put(at + 2, (rgba >> 8).to_u8!)
      @data.unsafe_put(at + 3, rgba.to_u8!)
      rgba
    end

    def fill(x : Int32, y : Int32, width : Int32, height : Int32, rgba : UInt32) : Nil
      left   = Math.max(x, 0)
      top    = Math.max(y, 0)
      right  = Math.min(x + width, @width)
      bottom = Math.min(y + height, @height)
      return if left >= right || top >= bottom
      alpha = rgba & 0xFF_u32
      row   = top
      while row < bottom
        col = left
        while col < right
          alpha == 255_u32 ? (self[col, row] = rgba) : blend(col, row, rgba, 1.0_f32)
          col += 1
        end
        row += 1
      end
    end

    def blend(x : Int32, y : Int32, rgba : UInt32, coverage : Float32) : Nil
      return unless 0 <= x < @width && 0 <= y < @height
      top = (rgba & 0xFF_u32).to_f32 / 255.0_f32 * coverage.clamp(0.0_f32, 1.0_f32)
      return if top <= 0.0_f32
      at    = (y * @width + x) * 4
      below = @data.unsafe_fetch(at + 3).to_f32 / 255.0_f32
      rest  = below * (1.0_f32 - top)
      total = top + rest
      3.times do |channel|
        over  = ((rgba >> (24 - channel * 8)) & 0xFF_u32).to_f32
        under = @data.unsafe_fetch(at + channel).to_f32
        @data.unsafe_put(at + channel, ((over * top + under * rest) / total).round.clamp(0.0_f32, 255.0_f32).to_u8)
      end
      @data.unsafe_put(at + 3, (total * 255.0_f32).round.clamp(0.0_f32, 255.0_f32).to_u8)
    end

    def line(x0 : Float64, y0 : Float64, x1 : Float64, y1 : Float64, rgba : UInt32, thickness : Float64 = 1.0) : Nil
      return unless x0.finite? && y0.finite? && x1.finite? && y1.finite?
      half   = Math.max(thickness, 0.5) / 2.0
      reach  = half + 1.0
      left   = Math.max((Math.min(x0, x1) - reach).floor.to_i, 0)
      right  = Math.min((Math.max(x0, x1) + reach).ceil.to_i, @width - 1)
      top    = Math.max((Math.min(y0, y1) - reach).floor.to_i, 0)
      bottom = Math.min((Math.max(y0, y1) + reach).ceil.to_i, @height - 1)
      return if left > right || top > bottom
      dx     = x1 - x0
      dy     = y1 - y0
      length = dx * dx + dy * dy
      row    = top
      while row <= bottom
        py  = row + 0.5
        col = left
        while col <= right
          px    = col + 0.5
          along = length > 0.0 ? (((px - x0) * dx + (py - y0) * dy) / length).clamp(0.0, 1.0) : 0.0
          ex    = x0 + along * dx - px
          ey    = y0 + along * dy - py
          gap   = Math.sqrt(ex * ex + ey * ey)
          cover = (half + 0.5 - gap).clamp(0.0, 1.0)
          blend(col, row, rgba, cover.to_f32) if cover > 0.0
          col += 1
        end
        row += 1
      end
    end

    def disc(cx : Float64, cy : Float64, radius : Float64, rgba : UInt32) : Nil
      return unless cx.finite? && cy.finite? && radius > 0.0
      left   = Math.max((cx - radius - 1.0).floor.to_i, 0)
      right  = Math.min((cx + radius + 1.0).ceil.to_i, @width - 1)
      top    = Math.max((cy - radius - 1.0).floor.to_i, 0)
      bottom = Math.min((cy + radius + 1.0).ceil.to_i, @height - 1)
      row    = top
      while row <= bottom
        col = left
        while col <= right
          gap   = Math.hypot(col + 0.5 - cx, row + 0.5 - cy)
          cover = (radius + 0.5 - gap).clamp(0.0, 1.0)
          blend(col, row, rgba, cover.to_f32) if cover > 0.0
          col += 1
        end
        row += 1
      end
    end

    def arc(cx : Float64, cy : Float64, radius : Float64, thickness : Float64, start : Float64, sweep : Float64,
            rgba : UInt32) : Nil
      return unless radius > 0.0 && sweep != 0.0
      half   = thickness / 2.0
      outer  = radius + half + 1.0
      left   = Math.max((cx - outer).floor.to_i, 0)
      right  = Math.min((cx + outer).ceil.to_i, @width - 1)
      top    = Math.max((cy - outer).floor.to_i, 0)
      bottom = Math.min((cy + outer).ceil.to_i, @height - 1)
      turn   = Math::PI * 2
      span   = sweep.abs.clamp(0.0, turn)
      origin = sweep < 0.0 ? start + sweep : start
      row    = top
      while row <= bottom
        col = left
        while col <= right
          px    = col + 0.5 - cx
          py    = row + 0.5 - cy
          gap   = (Math.hypot(px, py) - radius).abs
          cover = (half + 0.5 - gap).clamp(0.0, 1.0)
          if cover > 0.0
            angle = (Math.atan2(py, px) - origin) % turn
            angle += turn if angle < 0.0
            blend(col, row, rgba, cover.to_f32) if angle <= span
          end
          col += 1
        end
        row += 1
      end
    end

    def crop(rect : Rect) : Bytes
      Bitmap.crop(@data, @width, rect, 4)
    end

    def changes(other : Bitmap) : Rect?
      return Rect.new(0, 0, @width, @height) unless other.width == @width && other.height == @height
      Bitmap.changes(@data, other.data, @width, Rect.new(0, 0, @width, @height), 4)
    end

    def regions(other : Bitmap, tile : Int32 = TILE, limit : Int32 = REGIONS) : Array(Rect)
      return [Rect.new(0, 0, @width, @height)] unless other.width == @width && other.height == @height
      Bitmap.regions(@data, other.data, @width, @height, 4, tile, limit)
    end

    TILE    = 32
    REGIONS = 16

    def self.crop(data : Bytes, width : Int32, rect : Rect, channels : Int32) : Bytes
      Asekii::Raster.crop(data, width, rect.x, rect.y, rect.width, rect.height, channels)
    end

    def self.changes(fresh : Bytes, stale : Bytes, width : Int32, within : Rect, channels : Int32) : Rect?
      stride = within.width * channels
      top    = -1
      bottom = -1
      within.height.times do |step|
        at = ((within.y + step) * width + within.x) * channels
        next if fresh[at, stride] == stale[at, stride]
        top    = within.y + step if top < 0
        bottom = within.y + step
      end
      return nil if top < 0
      left  = within.x + within.width
      right = within.x - 1
      (top..bottom).each do |row|
        base = row * width * channels
        col  = within.x
        while col < left
          break unless same?(fresh, stale, base + col * channels, channels)
          col += 1
        end
        left = col if col < left
        col  = within.x + within.width - 1
        while col > right
          break unless same?(fresh, stale, base + col * channels, channels)
          col -= 1
        end
        right = col if col > right
      end
      Rect.new(left, top, right - left + 1, bottom - top + 1)
    end

    def self.regions(fresh : Bytes, stale : Bytes, width : Int32, height : Int32, channels : Int32,
                     tile : Int32 = TILE, limit : Int32 = REGIONS) : Array(Rect)
      whole  = changes(fresh, stale, width, Rect.new(0, 0, width, height), channels) || return [] of Rect
      tile   = Math.max(tile, 1)
      across = (width + tile - 1) // tile
      down   = (height + tile - 1) // tile
      dirty  = Slice(Bool).new(across * down, false)
      (whole.y...whole.y + whole.height).each do |row|
        base = row * width * channels
        band = (row // tile) * across
        (whole.x // tile..(whole.x + whole.width - 1) // tile).each do |column|
          next if dirty.unsafe_fetch(band + column)
          left = column * tile
          span = Math.min(tile, width - left) * channels
          at   = base + left * channels
          dirty.unsafe_put(band + column, true) unless fresh[at, span] == stale[at, span]
        end
      end
      open  = [] of Rect
      found = [] of Rect
      down.times do |band|
        runs   = [] of Rect
        column = 0
        while column < across
          unless dirty.unsafe_fetch(band * across + column)
            column += 1
            next
          end
          first = column
          while column < across && dirty.unsafe_fetch(band * across + column)
            column += 1
          end
          runs << Rect.new(first, band, column - first, 1)
        end
        kept = [] of Rect
        runs.each do |run|
          if index = open.index { |above| above.x == run.x && above.width == run.width && above.y + above.height == band }
            above = open.delete_at(index)
            kept << Rect.new(above.x, above.y, above.width, above.height + 1)
          else
            kept << run
          end
        end
        found.concat(open)
        open = kept
      end
      found.concat(open)
      return [whole] if found.size > limit
      rects = found.compact_map do |cells|
        left = cells.x * tile
        top  = cells.y * tile
        span = Rect.new(left, top, Math.min(cells.width * tile, width - left), Math.min(cells.height * tile, height - top))
        changes(fresh, stale, width, span, channels)
      end
      area = rects.sum { |rect| rect.width * rect.height }
      area * 4 >= whole.width * whole.height * 3 ? [whole] : rects
    end

    @[AlwaysInline]
    private def self.same?(fresh : Bytes, stale : Bytes, at : Int32, channels : Int32) : Bool
      channels.times do |channel|
        return false unless fresh.unsafe_fetch(at + channel) == stale.unsafe_fetch(at + channel)
      end
      true
    end

    def shift(other : Bitmap, limit : Int32) : Int32?
      return nil unless other.width == @width && other.height == @height
      (1..Math.min(limit, @width - 1)).each do |step|
        kept  = (@width - step) * 4
        match = true
        @height.times do |row|
          base = row * @width * 4
          unless @data[base, kept] == other.data[base + step * 4, kept]
            match = false
            break
          end
        end
        return step if match
      end
      nil
    end
  end
end
