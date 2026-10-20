# src/asekii-term/render/pile.cr
module Asekii::Render
  class Pile
    private struct Accum
      LOCK = 0.999_f32

      getter amount : Float32
      getter paint : Paint
      getter? pure : Bool

      def initialize
        @c0 = 0.0_f32
        @c1 = 0.0_f32
        @c2 = 0.0_f32
        @amount = 0.0_f32
        @pure = false
        @paint = Paint::NONE
      end

      @[AlwaysInline]
      def locked? : Bool
        @amount >= LOCK
      end

      @[AlwaysInline]
      def empty? : Bool
        @amount == 0.0_f32
      end

      def add(paint : Paint, level : Float32, palette : Palette, space : BlendSpace) : Nil
        if @amount == 0.0_f32 && level >= LOCK
          @pure = true
          @paint = paint
          @amount = 1.0_f32
          return
        end
        coords = ColorSpace.coords(Pile.rgb(paint, palette), space)
        weight = (1.0_f32 - @amount) * level
        @c0 += weight * coords[0]
        @c1 += weight * coords[1]
        @c2 += weight * coords[2]
        @amount += weight
      end

      def finish(backdrop : ColorSpace::Triple, palette : Palette, space : BlendSpace) : UInt32
        return Pile.rgb(@paint, palette) if @pure
        rest = 1.0_f32 - @amount
        ColorSpace.rgb({@c0 + rest * backdrop[0], @c1 + rest * backdrop[1], @c2 + rest * backdrop[2]}, space)
      end

      def sum(palette : Palette, space : BlendSpace) : ColorSpace::Triple
        return ColorSpace.coords(Pile.rgb(@paint, palette), space) if @pure
        {@c0, @c1, @c2}
      end

      def coords(backdrop : ColorSpace::Triple, palette : Palette, space : BlendSpace) : ColorSpace::Triple
        return ColorSpace.coords(Pile.rgb(@paint, palette), space) if @pure
        rest = 1.0_f32 - @amount
        {@c0 + rest * backdrop[0], @c1 + rest * backdrop[1], @c2 + rest * backdrop[2]}
      end
    end

    private record Block, x : Int32, y : Int32, span : Int32

    record Caret, plane : Plane, x : Int32, y : Int32
    record Shift, top : Int32, bottom : Int32, lines : Int32

    getter planes : Array(Plane)
    getter sprites : Array(Sprite)
    getter retired : Array(Sprite)
    getter shifts : Array(Shift)
    getter cols : Int32
    getter rows : Int32
    getter tiles : Slice(Tile)
    getter caret : Caret?

    getter stroke_images : StrokeImages

    BAND_MIN = 4096

    property notify : (-> Nil)?
    property merger : (Paint, Paint -> Paint)?
    property workers : Fiber::ExecutionContext?
    property bands : Int32

    @palette : Palette
    @terminal : Palette
    @themes : Themes?
    @backdrop : ColorSpace::Triple

    def initialize(cols : Int32, rows : Int32)
      @cols = Math.max(cols, 0)
      @rows = Math.max(rows, 0)
      @planes = [] of Plane
      @sprites = [] of Sprite
      @retired = [] of Sprite
      @shifts = [] of Shift
      @tiles = Slice(Tile).new(@cols * @rows, Tile::BLANK)
      @low = Slice(Int32).new(@rows, @cols)
      @high = Slice(Int32).new(@rows, 0)
      @caret = nil
      @notify = nil
      @merger = nil
      @serial = 0_u32
      @stack = [] of Plane
      @lefts = [] of Int32
      @tops = [] of Int32
      @windows = [] of Tuple(Int32, Int32, Int32, Int32)
      @powers = [] of Float32
      @row = [] of Int32
      @blocks = [] of Block
      @palette = Palette.stock
      @terminal = @palette
      @themes = nil
      @backdrop = {0.0_f32, 0.0_f32, 0.0_f32}
      @space = BlendSpace::Linear
      @depth = ColorDepth::TrueColor
      @indexed = true
      @snap = false
      @stroke_images = StrokeImages.new
      @workers = nil
      @bands = 0
      @slots = [] of Array(Int32)
      @pieces = [] of Array(Block)
      @stroke_images.landed = -> { damage_all }
    end

    def inspect(io : IO) : Nil
      io << "#<Asekii::Render::Pile " << @cols << 'x' << @rows << " planes=" << @planes.size << " sprites=" << @sprites.size << '>'
    end

    def self.rgb(paint : Paint, palette : Palette) : UInt32
      case paint.kind
      in Paint::Kind::Foreground then palette.fg
      in Paint::Kind::Background then palette.bg
      in Paint::Kind::Index      then palette[paint.value]
      in Paint::Kind::RGB        then paint.value
      in Paint::Kind::Role       then palette.fg
      in Paint::Kind::Spec       then palette.fg
      end
    end

    def self.fuse(under : Paint, over : Paint, palette : Palette, space : BlendSpace) : Paint
      top = over.alpha / 255.0_f32
      rest = under.alpha / 255.0_f32 * (1.0_f32 - top)
      total = top + rest
      above = ColorSpace.coords(rgb(over, palette), space)
      below = ColorSpace.coords(rgb(under, palette), space)
      coords = {(above[0] * top + below[0] * rest) / total, (above[1] * top + below[1] * rest) / total,
                (above[2] * top + below[2] * rest) / total}
      Paint.rgb(ColorSpace.rgb(coords, space), (total * 255.0_f32).round.clamp(0.0_f32, 255.0_f32).to_u8)
    end

    def merge(under : Paint, over : Paint) : Paint
      return under if over.clear?
      return over if over.alpha == 255_u8 || under.clear?
      if merger = @merger
        merger.call(under, over)
      else
        Pile.fuse(under, over, @palette, @space)
      end
    end

    def serial : UInt32
      @serial += 1_u32
    end

    def plane(cols : Int32, rows : Int32, x : Int32 = 0, y : Int32 = 0,
              z : Layer = Layer::Top, parent : Plane? = nil) : Plane
      plane = Plane.new(self, parent, cols, rows, x, y)
      z.top? ? @planes.push(plane) : @planes.unshift(plane)
      plane.scar
      plane
    end

    def remove(plane : Plane) : Nil
      @planes.delete(plane)
    end

    def enlist(sprite : Sprite) : Nil
      @sprites << sprite
    end

    def retire(sprite : Sprite) : Nil
      @sprites.delete(sprite)
      @retired << sprite
      touch
    end

    def caret=(caret : Caret?) : Caret?
      @caret = caret
      touch
      caret
    end

    def caret_position : Tuple(Int32, Int32)?
      caret = @caret || return nil
      plane = caret.plane
      return nil unless plane.shown? && caret.x >= 0 && caret.x < plane.cols && caret.y >= 0 && caret.y < plane.rows
      col = plane.abs_x + caret.x
      row = plane.abs_y + caret.y
      return nil unless col >= 0 && col < @cols && row >= 0 && row < @rows
      return nil unless plane.shows?(col, row)
      depth = index(plane) + 1
      while depth < @planes.size
        other = @planes.unsafe_fetch(depth)
        depth += 1
        next unless other.shown? && other.opacity > 0_u8 && other.shows?(col, row)
        cell = other[col - other.abs_x, row - other.abs_y]
        base = other.base_cell
        return nil if cell.inked? || base.inked? || !cell.bg.clear? || !base.bg.clear?
      end
      {col, row}
    end

    def scrolled(top : Int32, rows : Int32, lines : Int32) : Nil
      first = Math.max(top, 0)
      last = Math.min(top + rows, @rows)
      @shifts << Shift.new(first, last, lines) if last - first > lines.abs
    end

    def widen(row : Int32) : Nil
      @low.unsafe_put(row, 0)
      @high.unsafe_put(row, @cols)
    end

    def index(plane : Plane) : Int32
      @planes.index(plane) || -1
    end

    def reorder(plane : Plane, index : Int32) : Nil
      return unless @planes.delete(plane)
      @planes.insert(index.clamp(0, @planes.size), plane)
      plane.scar
    end

    def place(plane : Plane, other : Plane, offset : Int32) : Nil
      return if plane.same?(other) || !@planes.delete(plane)
      @planes.insert((index(other) + offset).clamp(0, @planes.size), plane)
      plane.scar
    end

    def resize(cols : Int32, rows : Int32) : Nil
      @cols = Math.max(cols, 0)
      @rows = Math.max(rows, 0)
      @tiles = Slice(Tile).new(@cols * @rows, Tile::BLANK)
      @low = Slice(Int32).new(@rows, @cols)
      @high = Slice(Int32).new(@rows, 0)
      damage_all
    end

    def touch : Nil
      @notify.try(&.call)
    end

    def damage(x : Int32, y : Int32, cols : Int32, rows : Int32) : Nil
      left = Math.max(x, 0)
      right = Math.min(x + cols, @cols)
      top = Math.max(y, 0)
      bottom = Math.min(y + rows, @rows)
      return if left >= right || top >= bottom
      row = top
      while row < bottom
        @low.unsafe_put(row, left) if left < @low.unsafe_fetch(row)
        @high.unsafe_put(row, right) if right > @high.unsafe_fetch(row)
        row += 1
      end
      touch
    end

    def damage_all : Nil
      damage(0, 0, @cols, @rows)
    end

    def damaged? : Bool
      @planes.any?(&.dirty?) || @rows.times.any? { |row| @high.unsafe_fetch(row) > @low.unsafe_fetch(row) }
    end

    @[AlwaysInline]
    def span(row : Int32) : Tuple(Int32, Int32)
      {@low.unsafe_fetch(row), @high.unsafe_fetch(row)}
    end

    def settle : Nil
      @low.fill(@cols)
      @high.fill(0)
      @shifts.clear
    end

    def tile(x : Int32, y : Int32) : Tile
      x >= 0 && x < @cols && y >= 0 && y < @rows ? @tiles.unsafe_fetch(y * @cols + x) : Tile::BLANK
    end

    def top_at(col : Int32, row : Int32) : Plane?
      @planes.reverse_each do |plane|
        return plane if plane.shown? && plane.shows?(col, row)
      end
      nil
    end

    def compose(themes : Themes, space : BlendSpace) : Nil
      absorb
      stack
      @themes = themes
      @palette = themes.palette
      @terminal = themes.terminal
      @space = space
      @depth = themes.depth
      @indexed = themes.indexed?
      @snap = themes.snap?
      @backdrop = ColorSpace.coords(@palette.bg, space)
      @blocks.clear
      workers = @workers
      if workers && @bands > 1 && @depth.true_color? && !@snap && damaged_cells >= BAND_MIN
        banded(workers, Math.min(@bands, Math.max(@rows // 4, 1)))
      else
        sweep(0, @rows, @row, @blocks)
      end
      @blocks.each { |block| verify(block) }
      @stroke_images.dispatch
    end

    private def damaged_cells : Int32
      total = 0
      @rows.times do |row|
        gap = @high.unsafe_fetch(row) - @low.unsafe_fetch(row)
        total += gap if gap > 0
      end
      total
    end

    private def sweep(first : Int32, last : Int32, slots : Array(Int32), blocks : Array(Block)) : Nil
      row = first
      while row < last
        low, high = span(row)
        if low < high
          gather(row, low, high, slots)
          col = low
          while col < high
            index = row * @cols + col
            fresh = resolve(col, row, slots)
            stale = @tiles.unsafe_fetch(index)
            note(col, row, stale, blocks) if stale.block?
            note(col, row, fresh, blocks) if fresh.block?
            @tiles.unsafe_put(index, fresh)
            col += 1
          end
        end
        row += 1
      end
    end

    private def banded(workers : Fiber::ExecutionContext, count : Int32) : Nil
      themes = @themes.not_nil!
      themes.resolve(Roles.count - 1) if Roles.count > 0
      while @slots.size < count
        @slots << [] of Int32
        @pieces << [] of Block
      end
      step = (@rows + count - 1) // count
      group = WaitGroup.new(count)
      failures = Array(Exception?).new(count, nil)
      count.times do |band|
        first = Math.min(band * step, @rows)
        last = Math.min(first + step, @rows)
        slots = @slots.unsafe_fetch(band)
        blocks = @pieces.unsafe_fetch(band)
        blocks.clear
        workers.spawn(name: "asekii.compose") do
          sweep(first, last, slots, blocks)
        rescue error
          failures[band] = error
        ensure
          group.done
        end
      end
      group.wait
      count.times { |band| @blocks.concat(@pieces.unsafe_fetch(band)) }
      failures.each { |failure| raise failure if failure }
    end

    private def absorb : Nil
      @planes.each do |plane|
        next unless plane.dirty?
        left, top, right, bottom = plane.dirty
        plane.clean
        next unless plane.shown?
        damage(plane.abs_x + left, plane.abs_y + top, right - left, bottom - top)
      end
    end

    private def stack : Nil
      @stack.clear
      @lefts.clear
      @tops.clear
      @windows.clear
      @powers.clear
      @planes.reverse_each do |plane|
        next unless plane.shown?
        power = plane.strength
        next if power <= 0.0_f32
        plane.sprites.each(&.settle(@cols, @rows, @stack.size)) unless plane.sprites.empty?
        @stack << plane
        @lefts << plane.abs_x
        @tops << plane.abs_y
        @windows << plane.window
        @powers << power
      end
      @sprites.each do |sprite|
        sprite.settle(@cols, @rows, 0) unless sprite.plane.shown? && sprite.plane.strength > 0.0_f32
      end
    end

    private def gather(row : Int32, low : Int32, high : Int32, slots : Array(Int32)) : Nil
      slots.clear
      @stack.size.times do |slot|
        left, top, right, bottom = @windows.unsafe_fetch(slot)
        next if row < top || row >= bottom
        next if high <= left || low >= right
        slots << slot
      end
    end

    @[AlwaysInline]
    private def grounded(paint : Paint) : Paint
      if paint.role?
        found = @themes.not_nil!.resolve(paint.value.to_i32!)
        Paint.new(found.kind, found.value, paint.alpha)
      elsif paint.spec?
        @themes.not_nil!.resolve_spec(Specs[paint.value], @palette)
      else
        paint
      end
    end

    private def high_contrast_ink(shade : UInt32) : UInt32
      themes = @themes.not_nil!
      fg = @palette.fg
      bg = @palette.bg
      black = 0x000000_u32
      white = 0xFFFFFF_u32
      fg_ratio = themes.contrast(fg, shade)
      bg_ratio = themes.contrast(bg, shade)
      black_ratio = themes.contrast(black, shade)
      white_ratio = themes.contrast(white, shade)
      best = fg_ratio >= bg_ratio ? fg : bg
      extreme = black_ratio >= white_ratio ? black : white
      best_ratio = Math.max(fg_ratio, bg_ratio)
      extreme_ratio = Math.max(black_ratio, white_ratio)
      extreme_ratio > best_ratio ? extreme : best
    end

    private def resolve(col : Int32, row : Int32, slots : Array(Int32)) : Tile
      ink = Accum.new
      field = Accum.new
      rule = Accum.new
      glyph = 0_u32
      attrs = Attr::None
      span = 1_u8
      dx = 0_u8
      flags = 0_u8
      owner = 0_u32
      exact = 0_u32
      under = 0_u32
      link = 0_u32
      found = false
      fixed = false
      lined = false
      hole = false
      etched = 0_u32
      above = Accum.new
      stroke = Paint::NONE
      inner = Paint::NONE
      edge = 0.0_f32
      body = 0.0_f32
      weight = 1.0_f32
      index = 0
      count = slots.size
      while index < count
        slot = slots.unsafe_fetch(index)
        index += 1
        plane = @stack.unsafe_fetch(slot)
        edges = @windows.unsafe_fetch(slot)
        next if col < edges[0] || col >= edges[2]
        x = col - @lefts.unsafe_fetch(slot)
        if etched == 0_u32 && !plane.sprites.empty? && field.empty? && plane.sprites.any?(&.covers?(col, row))
          hole = true
          break
        end
        cell = plane.cell(x, row - @tops.unsafe_fetch(slot))
        cell = cell.lettered if cell.stroke? && !@stroke_images.ready?
        base = plane.base_cell
        power = @powers.unsafe_fetch(slot)
        link = cell.link if link == 0_u32 && !found
        unless found
          source = cell.inked? ? cell : base
          if source.inked?
            found = true
            if source.stroke?
              etched = source.glyph
              owner = plane.serial
              stroke = grounded(source.fg)
              inner = grounded(source.bg)
              edge = source.fg.alpha / 255.0_f32 * power
              body = source.bg.alpha / 255.0_f32 * power
              weight = power
              above = field
              field = Accum.new
              next
            end
            glyph = source.glyph
            attrs = source.attrs
            span = source.span
            dx = source.dx
            flags = source.cont? ? Tile::CONT : 0_u8
            owner = plane.serial
            link = source.link if link == 0_u32
            if source.exact?
              fixed = true
              flags |= Tile::EXACT
              exact = source.fg.value
              under = source.line.value
            end
            unless source.line.clear?
              lined = true
              rule = ink
              level = source.line.alpha / 255.0_f32 * power
              rule.add(grounded(source.line), level, @palette, @space) if level > 0.0_f32 && !rule.locked?
            end
            level = source.fg.alpha / 255.0_f32 * power
            ink.add(grounded(source.fg), level, @palette, @space) if level > 0.0_f32 && !ink.locked?
          end
        end
        back = cell.bg.clear? ? base.bg : cell.bg
        level = back.alpha / 255.0_f32 * power
        if level > 0.0_f32
          tone = grounded(back)
          field.add(tone, level, @palette, @space)
          ink.add(tone, level, @palette, @space) unless ink.locked?
          rule.add(tone, level, @palette, @space) if lined && !rule.locked?
          break if field.locked?
        end
      end
      return etch(etched, owner, link, above, field, stroke, inner, edge, body, weight) unless etched == 0_u32
      bg_kind, bg = if hole
                      {Tile::Kind::Default, 0_u32}
                    elsif field.empty?
                      encode(Paint.background, false)
                    elsif field.pure?
                      encode(field.paint, false)
                    else
                      encode(field.finish(@backdrop, @palette, @space))
                    end
      shown = attrs & ~Attr::HighContrast
      plain = flags & Tile::CONT != 0_u8 || !found || ((glyph == 0_u32 || glyph == 0x20_u32) && (shown & Tile::LINES).none?)
      fg_kind, fg = if plain
                      {Tile::Kind::Default, 0_u32}
                    elsif fixed
                      {Tile::Kind::RGB, exact}
                    elsif attrs.high_contrast?
                      shade = field.empty? ? @palette.bg : field.finish(@backdrop, @palette, @space)
                      encode(high_contrast_ink(shade))
                    elsif ink.pure?
                      encode(ink.paint, true)
                    else
                      encode(ink.finish(@backdrop, @palette, @space))
                    end
      line_kind, line = if plain || !lined
                          {Tile::Kind::Default, 0_u32}
                        elsif fixed
                          {Tile::Kind::RGB, under}
                        elsif rule.pure? && rule.paint.kind.index?
                          encode(rule.paint, true)
                        else
                          encode(rule.finish(@backdrop, @palette, @space))
                        end
      Tile.new(glyph, fg, bg, shown, fg_kind, bg_kind, span, dx, flags, owner,
        line, line_kind, link)
    end

    private def etch(id : UInt32, owner : UInt32, link : UInt32, above : Accum, below : Accum, stroke : Paint,
                     inner : Paint, edge : Float32, body : Float32, power : Float32) : Tile
      under = below.empty? ? @backdrop : below.coords(@backdrop, @palette, @space)
      lit = above.sum(@palette, @space)
      keep = 1.0_f32 - above.amount
      tone = Pile.rgb(stroke, @palette)
      shade = Pile.rgb(inner, @palette)
      ink = ColorSpace.coords(tone, @space)
      fill = ColorSpace.lerp(under, ColorSpace.coords(shade, @space), body)
      outside = seen(lit, keep, under)
      filled = seen(lit, keep, fill)
      edged = seen(lit, keep, ColorSpace.lerp(under, ink, edge))
      shape = Strokes[id]
      if shape.tinted?
        return tint(id, shape, owner, link, above, under, lit, keep, tone, ink, edge, inner, body, power, outside, edged)
      end
      cell = shape.fill == Stroke::Corner::All
      if above.empty? && !@stroke_images.exact?
        inked = StrokeImages.level(edge)
        bodied = shape.fill.none? ? 0_u8 : StrokeImages.level(body)
        slot = @indexed && @stroke_images.indexed? && !shape.blank? && (cell || bodied == 0_u8) ? StrokeImages.slot(stroke) : nil
        if slot
          key = StrokeImages::Key.new(id, @space, StrokeImages::Mode::Indexed, 0_u32, 0_u32,
            (slot << 8) | inked, 0_u32, !(inked == 0_u8 || inked == 255_u8))
          back = cell ? filled : outside
        else
          fading = !(inked == 0_u8 || inked == 255_u8) || !(bodied == 0_u8 || bodied == 255_u8)
          key = StrokeImages::Key.new(id, @space, StrokeImages::Mode::Clear, 0_u32,
            bodied == 0_u8 ? 0_u32 : Bitmap.rgba(shade, bodied), shape.blank? ? 0_u32 : Bitmap.rgba(tone, inked), 0_u32, fading)
          back = outside
        end
      else
        key = StrokeImages::Key.new(id, @space, StrokeImages::Mode::Baked, outside, filled, edged,
          seen(lit, keep, ColorSpace.lerp(fill, ink, edge)), true)
        back = cell ? filled : outside
      end
      bg_kind, bg = encode(back)
      if image = @stroke_images.image(key)
        return Tile.new(StrokeImages::GLYPH, image, bg, Attr::None, Tile::Kind::RGB, bg_kind, owner: owner, link: link)
      end
      fg_kind, fg = encode(shape.blank? ? filled : edged)
      bg_kind, bg = encode(cell && !shape.blank? ? filled : outside)
      Tile.new(shape.glyph.ord.to_u32, fg, bg, Attr::None, fg_kind, bg_kind, owner: owner, link: link)
    end

    private def tint(id : UInt32, shape : Stroke, owner : UInt32, link : UInt32, above : Accum,
                     under : ColorSpace::Triple, lit : ColorSpace::Triple, keep : Float32, tone : UInt32,
                     ink : ColorSpace::Triple, edge : Float32, inner : Paint, body : Float32, power : Float32,
                     outside : UInt32, edged : UInt32) : Tile
      colours = StaticArray(UInt32, 4).new(0_u32)
      levels = StaticArray(Float32, 4).new(0.0_f32)
      Stroke::QUARTERS.each_with_index do |corner, slot|
        next unless shape.fill.includes?(corner)
        paint = shape.tones[corner]
        if paint.clear?
          colours[slot] = Pile.rgb(inner, @palette)
          levels[slot] = body
        else
          found = grounded(paint)
          colours[slot] = Pile.rgb(found, @palette)
          levels[slot] = found.alpha / 255.0_f32 * power
        end
      end
      seens = StaticArray(UInt32, 4).new do |slot|
        seen(lit, keep, ColorSpace.lerp(under, ColorSpace.coords(colours[slot], @space), levels[slot]))
      end
      if above.empty? && !@stroke_images.exact?
        inked = StrokeImages.level(edge)
        steps = StaticArray(UInt8, 4).new { |slot| StrokeImages.level(levels[slot]) }
        fading = !(inked == 0_u8 || inked == 255_u8) || steps.any? { |step| !(step == 0_u8 || step == 255_u8) }
        tints = {0, 1, 2, 3}.map { |slot| steps[slot] == 0_u8 ? 0_u32 : Bitmap.rgba(colours[slot], steps[slot]) }
        key = StrokeImages::Key.new(id, @space, StrokeImages::Mode::Tinted, 0_u32, 0_u32,
          Bitmap.rgba(tone, inked), 0_u32, fading, tints)
      else
        key = StrokeImages::Key.new(id, @space, StrokeImages::Mode::Mixed, outside, 0_u32, seen(lit, keep, ink),
          (edge.clamp(0.0_f32, 1.0_f32) * 255.0_f32).round.to_u32, true, {seens[0], seens[1], seens[2], seens[3]})
      end
      bg_kind, bg = encode(outside)
      if image = @stroke_images.image(key)
        return Tile.new(StrokeImages::GLYPH, image, bg, Attr::None, Tile::Kind::RGB, bg_kind, owner: owner, link: link)
      end
      if shape.blank?
        fg_kind, fg = encode(covering(shape, seens, outside))
        bg_kind, bg = encode(outside)
      else
        fg_kind, fg = encode(edged)
        bg_kind, bg = encode(dominant(shape, seens, outside))
      end
      Tile.new(shape.glyph.ord.to_u32, fg, bg, Attr::None, fg_kind, bg_kind, owner: owner, link: link)
    end

    private def covering(shape : Stroke, seens : StaticArray(UInt32, 4), outside : UInt32) : UInt32
      Stroke::QUARTERS.each_with_index do |corner, slot|
        return seens[slot] if shape.fill.includes?(corner)
      end
      outside
    end

    private def dominant(shape : Stroke, seens : StaticArray(UInt32, 4), outside : UInt32) : UInt32
      best = outside
      count = 0
      Stroke::QUARTERS.each_with_index do |corner, slot|
        next unless shape.fill.includes?(corner)
        shared = 0
        Stroke::QUARTERS.each_with_index do |other, index|
          shared += 1 if shape.fill.includes?(other) && seens[index] == seens[slot]
        end
        next unless shared > count
        count = shared
        best = seens[slot]
      end
      count * 2 >= Stroke::QUARTERS.size ? best : outside
    end

    @[AlwaysInline]
    private def seen(lit : ColorSpace::Triple, keep : Float32, color : ColorSpace::Triple) : UInt32
      ColorSpace.rgb({lit[0] + keep * color[0], lit[1] + keep * color[1], lit[2] + keep * color[2]}, @space)
    end

    private def encode(paint : Paint, ink : Bool) : Tuple(Tile::Kind, UInt32)
      case paint.kind
      when .foreground?
        return {Tile::Kind::Default, 0_u32} if ink && @indexed
        encode(@palette.fg)
      when .background?
        return {Tile::Kind::Default, 0_u32} if !ink && @indexed
        encode(@palette.bg)
      when .index?
        return encode(@palette[paint.value]) unless @indexed
        if @depth.ansi16? && paint.value >= Palette::CUBE
          {Tile::Kind::Index, @terminal.nearest(@palette[paint.value], Palette::CUBE).to_u32}
        else
          {Tile::Kind::Index, paint.value}
        end
      else
        encode(paint.value)
      end
    end

    private def encode(rgb : UInt32) : Tuple(Tile::Kind, UInt32)
      if @depth.true_color? && !@snap
        {Tile::Kind::RGB, rgb}
      else
        {Tile::Kind::Index, @terminal.nearest(rgb, @depth.ansi16? ? Palette::CUBE : Palette::SIZE).to_u32}
      end
    end

    private def note(col : Int32, row : Int32, tile : Tile, blocks : Array(Block)) : Nil
      block = Block.new(col - tile.dx, row, tile.span.to_i)
      blocks << block unless blocks.last? == block
    end

    private def verify(block : Block) : Nil
      sound = intact?(block)
      owner = sound ? @tiles.unsafe_fetch(block.y * @cols + block.x).owner : 0_u32
      block.span.times do |across|
        col = block.x + across
        next if col < 0 || col >= @cols
        index = block.y * @cols + col
        tile = @tiles.unsafe_fetch(index)
        next unless tile.span == block.span && tile.dx == across && tile.cont? == (across > 0)
        broken = !(sound && tile.owner == owner)
        next if broken == tile.broken?
        @tiles.unsafe_put(index, tile.with_broken(broken))
        @low.unsafe_put(block.y, col) if col < @low.unsafe_fetch(block.y)
        @high.unsafe_put(block.y, col + 1) if col + 1 > @high.unsafe_fetch(block.y)
      end
    end

    private def intact?(block : Block) : Bool
      return false if block.x < 0 || block.x + block.span > @cols
      head = @tiles.unsafe_fetch(block.y * @cols + block.x)
      return false if head.cont? || head.span != block.span
      (1...block.span).each do |across|
        tile = @tiles.unsafe_fetch(block.y * @cols + block.x + across)
        return false unless tile.cont? && tile.owner == head.owner
        return false unless tile.dx == across && tile.span == block.span
      end
      true
    end
  end
end
