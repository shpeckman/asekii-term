# src/asekii/render/plane.cr
module Asekii::Render
  record Placeholder, row : Int32, col : Int32, high : Int32 do
    def self.of(glyph : UInt32) : Placeholder?
      return nil unless Graphemes.pooled?(glyph)
      bytes = Graphemes.bytes(glyph)
      point, size = TermWidth::Utf8.decode(bytes, 0)
      return nil unless point == UnicodePlaceholder::CHAR.ord.to_u32 && size < bytes.size
      row, size = mark(bytes, size)
      return nil unless row && size < bytes.size
      col, size = mark(bytes, size)
      return nil unless col
      high = 0
      if size < bytes.size
        found, size = mark(bytes, size)
        high = found || return nil
      end
      size == bytes.size ? new(row, col, high) : nil
    end

    private def self.mark(bytes : Bytes, offset : Int32) : Tuple(Int32?, Int32)
      point, size = TermWidth::Utf8.decode(bytes, offset)
      {UnicodePlaceholder.index?(point.to_i32), offset + size}
    end

    def follows?(other : Placeholder) : Bool
      @row == other.row && @col == other.col + 1 && @high == other.high
    end
  end

  enum Layer
    Top
    Bottom
  end

  class Plane
    include Canvas

    MAX_PLACEMENT = 0xFFFFFF_u32

    getter cols      : Int32
    getter rows      : Int32
    getter x         : Int32
    getter y         : Int32
    getter parent    : Plane?
    getter children  : Array(Plane)
    getter sprites   : Array(Sprite)
    getter serial    : UInt32
    getter opacity   : UInt8
    getter base_cell : Cell
    getter fg        : Paint
    getter bg        : Paint
    getter? visible  : Bool
    getter? disposed : Bool
    getter? clip     : Bool
    getter bounds    : Tuple(Int32, Int32, Int32, Int32)?

    @resized : (Plane -> Nil)?

    def initialize(@pile : Pile, @parent : Plane?, cols : Int32, rows : Int32,
                   @x : Int32 = 0, @y : Int32 = 0)
      @cols      = Math.max(cols, 0)
      @rows      = Math.max(rows, 0)
      @cells     = Slice(Cell).new(@cols * @rows, Cell::EMPTY)
      @children  = [] of Plane
      @sprites   = [] of Sprite
      @serial    = @pile.serial
      @opacity   = 255_u8
      @base_cell = Cell::EMPTY
      @fg        = Paint.foreground
      @bg        = Paint::NONE
      @visible   = true
      @disposed  = false
      @clip      = false
      @bounds    = nil
      @resized   = nil
      @left      = 0
      @top       = 0
      @right     = 0
      @bottom    = 0
      @parent.try(&.children.<<(self))
    end

    def inspect(io : IO) : Nil
      io << "#<Asekii::Render::Plane #" << @serial << ' ' << @cols << 'x' << @rows << " at " << @x << ',' << @y
      io << " hidden" unless @visible
      io << " disposed" if @disposed
      io << '>'
    end

    def plane(cols : Int32, rows : Int32, x : Int32 = 0, y : Int32 = 0, z : Layer = Layer::Top) : Plane
      @pile.plane(cols, rows, x, y, z, self)
    end

    def fg=(value) : Paint
      @fg = Paint.fg(value)
    end

    def bg=(value) : Paint
      @bg = Paint.bg(value)
    end

    def abs_x : Int32
      (@parent.try(&.abs_x) || 0) + @x
    end

    def abs_y : Int32
      (@parent.try(&.abs_y) || 0) + @y
    end

    def shown? : Bool
      @visible && !@disposed && (@parent.try(&.shown?) != false)
    end

    def strength : Float32
      (@opacity / 255.0_f32) * (@parent.try(&.strength) || 1.0_f32)
    end

    def z : Int32
      @pile.index(self)
    end

    def covers?(col : Int32, row : Int32) : Bool
      left = abs_x
      top  = abs_y
      col >= left && col < left + @cols && row >= top && row < top + @rows
    end

    def clip=(value : Bool) : Bool
      unless value == @clip
        @clip = value
        scar
      end
      value
    end

    def bounds=(value : Tuple(Int32, Int32, Int32, Int32)?) : Tuple(Int32, Int32, Int32, Int32)?
      unless value == @bounds
        @bounds = value
        scar
      end
      value
    end

    def window : Tuple(Int32, Int32, Int32, Int32)
      left   = abs_x
      top    = abs_y
      right  = left + @cols
      bottom = top + @rows

      if limit = @parent.try(&.reach)
        left   = Math.max(left, limit[0])
        top    = Math.max(top, limit[1])
        right  = Math.min(right, limit[2])
        bottom = Math.min(bottom, limit[3])
      end

      if limit = @bounds
        left   = Math.max(left, limit[0])
        top    = Math.max(top, limit[1])
        right  = Math.min(right, limit[2])
        bottom = Math.min(bottom, limit[3])
      end

      {left, top, right, bottom}
    end

    def shows?(col : Int32, row : Int32) : Bool
      left, top, right, bottom = window
      col >= left && col < right && row >= top && row < bottom
    end

    protected def reach : Tuple(Int32, Int32, Int32, Int32)?
      @clip ? window : @parent.try(&.reach)
    end

    def [](x : Int32, y : Int32) : Cell
      inside?(x, y) ? @cells.unsafe_fetch(y * @cols + x) : Cell::EMPTY
    end

    @[AlwaysInline]
    def cell(x : Int32, y : Int32) : Cell
      @cells.unsafe_fetch(y * @cols + x)
    end

    def base(glyph : Char? = nil, fg = nil, bg = nil, attrs : Attr = Attr::None, line = nil) : Nil
      @base_cell = Cell.new(glyph ? glyph.ord.to_u32 : 0_u32, ink(fg), field(bg), attrs, line: rule(line))
      mark(0, 0, @cols, @rows)
    end

    def put(x : Int32, y : Int32, text : String, fg = nil, bg = nil, attrs : Attr = Attr::None,
            line = nil, link : String? = nil) : Int32
      target = link ? Links.intern(link) : 0_u32
      return 0 if y < 0 || y >= @rows
      front = ink(fg)
      back  = field(bg)
      under = rule(line)
      col   = x
      Graphemes.each(text) do |cluster, width|
        break if col >= @cols
        next if width == 0_u8 || control?(cluster)
        span = width.to_i
        if col >= 0
          if col + span <= @cols
            write(col, y, Graphemes.intern(cluster), front, back, attrs, span, under, target)
          else
            write(col, y, 0x20_u32, front, back, attrs, 1, under, target)
          end
        end
        col += span
      end
      col - x
    end

    def fill(x : Int32, y : Int32, cols : Int32, rows : Int32, glyph : Char? = nil,
             fg = nil, bg = nil, attrs : Attr = Attr::None, line = nil, link : String? = nil) : Nil
      target = link ? Links.intern(link) : 0_u32
      left   = Math.max(x, 0)
      top    = Math.max(y, 0)
      right  = Math.min(x + cols, @cols)
      bottom = Math.min(y + rows, @rows)
      return if left >= right || top >= bottom
      stamp = glyph ? glyph.ord.to_u32 : 0_u32
      front = ink(fg)
      back  = field(bg)
      under = rule(line)
      row   = top
      while row < bottom
        col = left
        while col < right
          sever(col, row)
          index = row * @cols + col
          @cells.unsafe_put(index, Cell.new(stamp, front, @pile.merge(@cells.unsafe_fetch(index).bg, back),
            attrs, line: under, link: target))
          col += 1
        end
        row += 1
      end
      mark(left, top, right, bottom)
    end

    def fill(glyph : Char? = nil, fg = nil, bg = nil, attrs : Attr = Attr::None,
             line = nil, link : String? = nil) : Nil
      fill(0, 0, @cols, @rows, glyph, fg, bg, attrs, line, link)
    end

    def stroke(x : Int32, y : Int32, stroke : Stroke, fg = nil, bg = nil) : Nil
      return unless inside?(x, y)
      sever(x, y)
      index = y * @cols + x
      @cells.unsafe_put(index, Cell.new(Strokes.intern(stroke), ink(fg),
        @pile.merge(@cells.unsafe_fetch(index).bg, field(bg)), flags: Cell::STROKE))
      mark(x, y, x + 1, y + 1)
    end

    def erase(x : Int32, y : Int32, cols : Int32, rows : Int32) : Nil
      left   = Math.max(x, 0)
      top    = Math.max(y, 0)
      right  = Math.min(x + cols, @cols)
      bottom = Math.min(y + rows, @rows)
      return if left >= right || top >= bottom
      (top...bottom).each do |row|
        (left...right).each do |col|
          sever(col, row)
          @cells.unsafe_put(row * @cols + col, Cell::EMPTY)
        end
      end
      mark(left, top, right, bottom)
    end

    def erase : Nil
      @cells.fill(Cell::EMPTY)
      mark(0, 0, @cols, @rows)
    end

    def scroll(lines : Int32) : Nil
      return if lines == 0 || @rows == 0 || @cols == 0
      count = lines.abs
      return erase if count >= @rows
      kept = (@rows - count) * @cols
      if lines > 0
        @cells[count * @cols, kept].move_to(@cells[0, kept])
        @cells[kept, count * @cols].fill(Cell::EMPTY)
      else
        @cells[0, kept].move_to(@cells[count * @cols, kept])
        @cells[0, count * @cols].fill(Cell::EMPTY)
      end
      heal
      mark(0, 0, @cols, @rows)
      left = abs_x
      @pile.scrolled(abs_y, @rows, lines) if shown? && left <= 0 && left + @cols >= @pile.cols
    end

    def image(x : Int32, y : Int32, image_id : UInt32, columns : Int32, rows : Int32,
              placement : UInt32? = nil, window : Tuple(Int32, Int32, Int32, Int32)? = nil) : Nil
      if columns > UnicodePlaceholder::LIMIT || rows > UnicodePlaceholder::LIMIT
        raise ArgumentError.new("placeholder extent exceeds the diacritic table")
      end
      if placement && placement > MAX_PLACEMENT
        raise ArgumentError.new("placeholder placement ids are limited to 24 bits")
      end
      tone  = Paint.rgb(image_id & 0xFFFFFF_u32)
      under = placement ? Paint.rgb(placement) : Paint::NONE
      high  = (image_id >> 24).to_i32!
      rows.times do |row|
        columns.times do |col|
          next unless inside?(x + col, y + row)
          if bounds = window
            next unless bounds[0] <= x + col < bounds[2] && bounds[1] <= y + row < bounds[3]
          end
          sever(x + col, y + row)
          index = (y + row) * @cols + x + col
          @cells.unsafe_put(index, Cell.new(Plane.placeholder(row, col, high), tone,
            @pile.merge(@cells.unsafe_fetch(index).bg, @bg), Attr::None, flags: Cell::EXACT, line: under))
        end
      end
      mark(x, y, x + columns, y + rows)
    end

    @@placeholders = Sync::Exclusive(Hash(Int32, UInt32)).new({} of Int32 => UInt32)

    def self.placeholder(row : Int32, col : Int32, high : Int32) : UInt32
      key = (row << 20) | (col << 10) | high
      @@placeholders.lock do |found|
        found[key] ||= Graphemes.intern(UnicodePlaceholder.cell(row, col, high))
      end
    end

    def sprite(image_id : UInt32, x : Int32, y : Int32, columns : Int32, rows : Int32,
               width : Int32 = 0, height : Int32 = 0) : Sprite
      sprite = Sprite.new(self, @pile, image_id, @pile.serial, x, y,
        Math.max(columns, 0), Math.max(rows, 0), width, height)
      unless @disposed
        @sprites << sprite
        @pile.enlist(sprite)
        @pile.damage(abs_x + x, abs_y + y, columns, rows)
      end
      sprite
    end

    def picture(raster : Raster, x : Int32, y : Int32, columns : Int32, rows : Int32) : Sprite
      sprite = sprite(0_u32, x, y, columns, rows, raster.width, raster.height)
      sprite.picture = raster
      sprite
    end

    def cursor(x : Int32, y : Int32) : Nil
      @pile.caret = Pile::Caret.new(self, x, y) unless @disposed
    end

    def hide_cursor : Nil
      @pile.caret = nil if @pile.caret.try(&.plane.same?(self))
    end

    def move(x : Int32, y : Int32) : Nil
      return if x == @x && y == @y
      scar
      @x = x
      @y = y
      scar
    end

    def resize(cols : Int32, rows : Int32) : Nil
      cols = Math.max(cols, 0)
      rows = Math.max(rows, 0)
      return if cols == @cols && rows == @rows
      scar
      cells = Slice(Cell).new(cols * rows, Cell::EMPTY)
      keep  = Math.min(cols, @cols)
      Math.min(rows, @rows).times do |row|
        @cells[row * @cols, keep].copy_to(cells[row * cols, keep])
      end
      @cells = cells
      @cols  = cols
      @rows  = rows
      heal
      scar
      @children.dup.each(&.follow)
    end

    def on_resize(&block : Plane -> Nil) : Nil
      @resized = block
    end

    def opacity=(value : Float64) : Float64
      level = (value.clamp(0.0, 1.0) * 255).round.to_u8
      unless level == @opacity
        @opacity = level
        scar
      end
      value
    end

    def visible=(value : Bool) : Bool
      unless value == @visible
        @visible = value
        scar
      end
      value
    end

    def to_top : Nil
      @pile.reorder(self, @pile.planes.size - 1)
    end

    def to_bottom : Nil
      @pile.reorder(self, 0)
    end

    def raise_one : Nil
      @pile.reorder(self, z + 1)
    end

    def lower_one : Nil
      @pile.reorder(self, z - 1)
    end

    def above(other : Plane) : Nil
      @pile.place(self, other, 1)
    end

    def below(other : Plane) : Nil
      @pile.place(self, other, 0)
    end

    def reparent(parent : Plane?) : Nil
      return if parent.same?(@parent) || parent.same?(self)
      scar
      @parent.try(&.children.delete(self))
      @parent = parent
      parent.try(&.children.<<(self))
      scar
    end

    def dispose : Nil
      return if @disposed
      @children.dup.each(&.dispose)
      @sprites.dup.each(&.dispose)
      hide_cursor
      scar
      @disposed = true
      @parent.try(&.children.delete(self))
      @pile.remove(self)
      @cells = Slice(Cell).empty
      @cols  = 0
      @rows  = 0
    end

    def dirty? : Bool
      @right > @left
    end

    def dirty : Tuple(Int32, Int32, Int32, Int32)
      {@left, @top, @right, @bottom}
    end

    def clean : Nil
      @left   = 0
      @top    = 0
      @right  = 0
      @bottom = 0
    end

    def scar : Nil
      return if @disposed
      @pile.damage(abs_x, abs_y, @cols, @rows)
      @children.each(&.scar)
    end

    protected def follow : Nil
      @resized.try(&.call(self))
    end

    @[AlwaysInline]
    private def inside?(x : Int32, y : Int32) : Bool
      x >= 0 && x < @cols && y >= 0 && y < @rows
    end

    private def ink(value) : Paint
      value.nil? ? @fg : Paint.fg(value)
    end

    private def field(value) : Paint
      value.nil? ? @bg : Paint.bg(value)
    end

    private def rule(value) : Paint
      value.nil? ? Paint::NONE : Paint.fg(value)
    end

    private def control?(cluster : Bytes) : Bool
      first = cluster.unsafe_fetch(0)
      first < 0x20_u8 || first == 0x7F_u8 ||
        (first == 0xC2_u8 && cluster.size > 1 && cluster.unsafe_fetch(1) < 0xA0_u8)
    end

    private def write(col : Int32, row : Int32, glyph : UInt32, fg : Paint, bg : Paint, attrs : Attr,
                      span : Int32, line : Paint, link : UInt32) : Nil
      span.times { |across| sever(col + across, row) }
      span.times do |across|
        index = row * @cols + col + across
        @cells.unsafe_put(index, Cell.new(across == 0 ? glyph : 0_u32, fg,
          @pile.merge(@cells.unsafe_fetch(index).bg, bg), attrs, span.to_u8, across.to_u8,
          across == 0 ? 0_u8 : Cell::CONT, line, link))
      end
      mark(col, row, col + span, row + 1)
    end

    private def sever(col : Int32, row : Int32) : Nil
      cell = @cells.unsafe_fetch(row * @cols + col)
      return unless cell.block?
      left = col - cell.dx
      cell.span.to_i.times do |across|
        next unless inside?(left + across, row)
        index = row * @cols + left + across
        @cells.unsafe_put(index, @cells.unsafe_fetch(index).blanked)
      end
      mark(left, row, left + cell.span, row + 1)
    end

    private def heal : Nil
      @rows.times do |row|
        @cols.times do |col|
          index = row * @cols + col
          cell  = @cells.unsafe_fetch(index)
          next unless cell.block?
          @cells.unsafe_put(index, cell.blanked) unless whole?(col - cell.dx, row, cell)
        end
      end
    end

    private def whole?(left : Int32, row : Int32, cell : Cell) : Bool
      span = cell.span.to_i
      return false unless inside?(left, row) && inside?(left + span - 1, row)
      span.times do |across|
        part = @cells.unsafe_fetch(row * @cols + left + across)
        return false unless part.span == cell.span && part.dx == across && part.cont? == (across > 0)
      end
      true
    end

    private def mark(left : Int32, top : Int32, right : Int32, bottom : Int32) : Nil
      left   = Math.max(left, 0)
      top    = Math.max(top, 0)
      right  = Math.min(right, @cols)
      bottom = Math.min(bottom, @rows)
      return if left >= right || top >= bottom
      if dirty?
        @left   = Math.min(@left, left)
        @top    = Math.min(@top, top)
        @right  = Math.max(@right, right)
        @bottom = Math.max(@bottom, bottom)
      else
        @left   = left
        @top    = top
        @right  = right
        @bottom = bottom
        @pile.touch
      end
    end
  end
end
