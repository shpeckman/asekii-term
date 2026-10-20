# src/asekii/render/stroke.cr
module Asekii::Render
  struct Stroke
    enum Piece : UInt8
      Top
      Bottom
      Left
      Right
      TopLeft
      TopRight
      BottomLeft
      BottomRight
    end

    enum Fill : UInt8
      Cell
      Inside
      Outside
      None
    end

    @[Flags]
    enum Arm : UInt8
      North
      East
      South
      West
    end

    @[Flags]
    enum Corner : UInt8
      NorthWest
      NorthEast
      SouthWest
      SouthEast
    end

    enum Node : UInt8
      None
      Filled
      Hollow
    end

    enum Fade : UInt8
      None
      North
      East
      South
      West
    end

    enum Line : UInt8
      Light
      Heavy
      Double
      None
    end

    @[Flags]
    enum Mirror : UInt8
      X
      Y
    end

    struct Tones
      NONE = new

      getter north_west : Paint
      getter north_east : Paint
      getter south_west : Paint
      getter south_east : Paint

      def initialize(@north_west : Paint = Paint::NONE, @north_east : Paint = Paint::NONE,
                     @south_west : Paint = Paint::NONE, @south_east : Paint = Paint::NONE)
      end

      def self.sides(west : Paint, east : Paint) : Tones
        new(west, east, west, east)
      end

      def [](corner : Corner) : Paint
        case corner
        when .north_west? then @north_west
        when .north_east? then @north_east
        when .south_west? then @south_west
        else                   @south_east
        end
      end

      def none? : Bool
        @north_west.clear? && @north_east.clear? && @south_west.clear? && @south_east.clear?
      end

      def_equals_and_hash north_west, north_east, south_west, south_east
    end

    record Shape, arms : Arm, bend : Corner, inside : Corner, mirror : Mirror
    record Branch, arms : Arm, bends : Corner, node : Node, fade : Fade

    private record Arc, corner : Corner, flip_x : Bool, flip_y : Bool, cx : Float32, cy : Float32,
      radius : Float32, ox : Float32, oy : Float32

    QUARTERS   = StaticArray[Corner::NorthWest, Corner::NorthEast, Corner::SouthWest, Corner::SouthEast]
    VERTICAL   = Arm::North | Arm::South
    HORIZONTAL = Arm::East | Arm::West
    CENTRE     = 128_u8
    SAMPLES    =      4

    PIECES = StaticArray[
      Shape.new(HORIZONTAL, Corner::None, Corner::SouthWest | Corner::SouthEast, Mirror::None),
      Shape.new(HORIZONTAL, Corner::None, Corner::NorthWest | Corner::NorthEast, Mirror::Y),
      Shape.new(VERTICAL, Corner::None, Corner::NorthEast | Corner::SouthEast, Mirror::None),
      Shape.new(VERTICAL, Corner::None, Corner::NorthWest | Corner::SouthWest, Mirror::X),
      Shape.new(Arm::East | Arm::South, Corner::SouthEast, Corner::SouthEast, Mirror::None),
      Shape.new(Arm::West | Arm::South, Corner::SouthWest, Corner::SouthWest, Mirror::X),
      Shape.new(Arm::North | Arm::East, Corner::NorthEast, Corner::NorthEast, Mirror::Y),
      Shape.new(Arm::North | Arm::West, Corner::NorthWest, Corner::NorthWest, Mirror::X | Mirror::Y),
    ]

    LINES = StaticArray[' ', '╵', '╶', '└', '╷', '│', '┌', '├', '╴', '┘', '─', '┴', '┐', '┤', '┬', '┼']

    HEAVY = StaticArray[' ', '╹', '╺', '┗', '╻', '┃', '┏', '┣', '╸', '┛', '━', '┻', '┓', '┫', '┳', '╋']

    DOUBLE = StaticArray[' ', '║', '═', '╚', '║', '║', '╔', '╠', '═', '╝', '═', '╩', '╗', '╣', '╦', '╬']

    QUADS = StaticArray[' ', '▘', '▝', '▀', '▖', '▌', '▞', '▛', '▗', '▚', '▐', '▜', '▄', '▙', '▟', '█']

    GLYPHS = {Line::Light => LINES, Line::Heavy => HEAVY, Line::Double => DOUBLE}

    CURVES = {
      Corner::NorthWest => '╯',
      Corner::NorthEast => '╰',
      Corner::SouthWest => '╮',
      Corner::SouthEast => '╭',
    }

    BENDS = {
      Corner::NorthWest => Arm::North | Arm::West,
      Corner::NorthEast => Arm::North | Arm::East,
      Corner::SouthWest => Arm::South | Arm::West,
      Corner::SouthEast => Arm::South | Arm::East,
    }

    NODES = StaticArray[
      Arm::None, Arm::East, Arm::West, HORIZONTAL, Arm::South, Arm::North, VERTICAL,
      Arm::East | Arm::South, Arm::West | Arm::South, Arm::North | Arm::East, Arm::North | Arm::West,
      VERTICAL | Arm::East, VERTICAL | Arm::West, HORIZONTAL | Arm::South, HORIZONTAL | Arm::North,
      VERTICAL | HORIZONTAL,
    ]

    BRANCH_FIRST = 0xF5D0
    BRANCH_LAST  = 0xF60D

    BRANCHES = begin
      table = [
        Branch.new(HORIZONTAL, Corner::None, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::None, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::None, Node::None, Fade::East),
        Branch.new(HORIZONTAL, Corner::None, Node::None, Fade::West),
        Branch.new(VERTICAL, Corner::None, Node::None, Fade::South),
        Branch.new(VERTICAL, Corner::None, Node::None, Fade::North),
        Branch.new(Arm::None, Corner::SouthEast, Node::None, Fade::None),
        Branch.new(Arm::None, Corner::SouthWest, Node::None, Fade::None),
        Branch.new(Arm::None, Corner::NorthEast, Node::None, Fade::None),
        Branch.new(Arm::None, Corner::NorthWest, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::NorthEast, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::SouthEast, Node::None, Fade::None),
        Branch.new(Arm::None, Corner::NorthEast | Corner::SouthEast, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::NorthWest, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::SouthWest, Node::None, Fade::None),
        Branch.new(Arm::None, Corner::NorthWest | Corner::SouthWest, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::SouthWest, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::SouthEast, Node::None, Fade::None),
        Branch.new(Arm::None, Corner::SouthEast | Corner::SouthWest, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::NorthWest, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::NorthEast, Node::None, Fade::None),
        Branch.new(Arm::None, Corner::NorthEast | Corner::NorthWest, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::NorthWest | Corner::NorthEast, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::SouthWest | Corner::SouthEast, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::SouthWest | Corner::NorthWest, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::NorthEast | Corner::SouthEast, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::NorthWest | Corner::SouthEast, Node::None, Fade::None),
        Branch.new(VERTICAL, Corner::NorthEast | Corner::SouthWest, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::NorthWest | Corner::SouthEast, Node::None, Fade::None),
        Branch.new(HORIZONTAL, Corner::NorthEast | Corner::SouthWest, Node::None, Fade::None),
      ]
      NODES.each do |arms|
        table << Branch.new(arms, Corner::None, Node::Filled, Fade::None)
        table << Branch.new(arms, Corner::None, Node::Hollow, Fade::None)
      end
      table
    end

    getter arms   : Arm
    getter bends  : Corner
    getter node   : Node
    getter fade   : Fade
    getter fill   : Corner
    getter mirror : Mirror
    getter tones  : Tones
    getter width  : UInt8
    getter x      : UInt8
    getter y      : UInt8
    getter line   : Line

    def initialize(*, @arms : Arm = Arm::None, @bends : Corner = Corner::None, @node : Node = Node::None,
                   @fade : Fade = Fade::None, @fill : Corner = Corner::All, width : Int = 1,
                   position : Float64 = 0.5, x : Float64 = position, y : Float64 = position,
                   @mirror : Mirror = Mirror::None, @tones : Tones = Tones::NONE, @line : Line = Line::Light)
      @width = width.clamp(1, 255).to_u8
      @x     = Stroke.place(x)
      @y     = Stroke.place(y)
      settle
    end

    def self.new(piece : Piece, round : Bool = false, width : Int = 1, position : Float64 = 0.5,
                 fill : Fill = Fill::Cell) : Stroke
      shape  = PIECES.unsafe_fetch(piece.value)
      curved = round && !shape.bend.none?
      new(arms: curved ? Arm::None : shape.arms, bends: curved ? shape.bend : Corner::None,
        fill: region(fill, shape.inside), width: width, position: position, mirror: shape.mirror)
    end

    def self.branch(char : Char, width : Int = 1, fill : Corner = Corner::All) : Stroke?
      code = char.ord
      return nil unless BRANCH_FIRST <= code <= BRANCH_LAST
      shape = BRANCHES.unsafe_fetch(code - BRANCH_FIRST)
      new(arms: shape.arms, bends: shape.bends, node: shape.node, fade: shape.fade, fill: fill, width: width)
    end

    def self.region(fill : Fill, inside : Corner) : Corner
      case fill
      in Fill::Cell    then Corner::All
      in Fill::Inside  then inside
      in Fill::Outside then Corner::All & ~inside
      in Fill::None    then Corner::None
      end
    end

    def self.corner(arms : Arm) : Corner
      BENDS.each { |corner, joined| return corner if joined == arms }
      Corner::None
    end

    def self.place(value : Float64) : UInt8
      (value.clamp(0.0, 1.0) * 255).round.to_u8
    end

    def self.turn(arms : Arm, flip_x : Bool, flip_y : Bool) : Arm
      bits = arms.value
      bits = (bits & 0b0101_u8) | ((bits & 0b0010_u8) << 2) | ((bits & 0b1000_u8) >> 2) if flip_x
      bits = (bits & 0b1010_u8) | ((bits & 0b0001_u8) << 2) | ((bits & 0b0100_u8) >> 2) if flip_y
      Arm.new(bits)
    end

    def self.turn(corners : Corner, flip_x : Bool, flip_y : Bool) : Corner
      bits = corners.value
      bits = ((bits & 0b0101_u8) << 1) | ((bits & 0b1010_u8) >> 1) if flip_x
      bits = ((bits & 0b0011_u8) << 2) | ((bits & 0b1100_u8) >> 2) if flip_y
      Corner.new(bits)
    end

    def tinted? : Bool
      !@tones.none?
    end

    def shape : Stroke
      return self unless tinted?
      plain = self
      plain.tones = Tones::NONE
      plain
    end

    def reach : Arm
      arms = @arms
      BENDS.each { |corner, joined| arms |= joined if @bends.includes?(corner) }
      arms
    end

    def blank? : Bool
      @line.none?
    end

    def glyph : Char
      return QUADS.unsafe_fetch(@fill.value) if blank?
      case @node
      in Node::Filled then return '●'
      in Node::Hollow then return '○'
      in Node::None
      end
      if @arms.none? && @line.light?
        CURVES[@bends]?.try { |curve| return curve }
      end
      GLYPHS[@line].unsafe_fetch(reach.value)
    end

    def_equals_and_hash arms, bends, node, fade, fill, mirror, tones, width, x, y, line

    def mask(width : Int32, height : Int32) : Bytes
      data  = Bytes.new(width * height * 2)
      total = SAMPLES * SAMPLES
      index = 0
      sample(width, height) do |level, regions|
        fills = 0
        QUARTERS.each_with_index { |corner, slot| fills += regions[slot] if @fill.includes?(corner) }
        data.unsafe_put(index, level)
        data.unsafe_put(index + 1, (fills * 255 // total).to_u8)
        index += 2
      end
      data
    end

    def quarters(width : Int32, height : Int32) : Bytes
      data  = Bytes.new(width * height * 5)
      total = SAMPLES * SAMPLES
      index = 0
      sample(width, height) do |level, regions|
        data.unsafe_put(index, level)
        QUARTERS.each_with_index do |corner, slot|
          share = @fill.includes?(corner) ? regions[slot] * 255 // total : 0
          data.unsafe_put(index + 1 + slot, share.to_u8)
        end
        index += 5
      end
      data
    end

    protected def tones=(@tones : Tones) : Tones
    end

    private def sample(width : Int32, height : Int32, & : UInt8, StaticArray(Int32, 4) ->) : Nil
      least  = Math.min(width, height).to_f32
      weight = @line.heavy? ? @width.to_f32 * 2.0_f32 : @width.to_f32
      thick  = Math.min(weight, least)
      half   = thick / 2.0_f32
      gap    = @line.double? ? Math.min(Math.max(thick, least / 5.0_f32), Math.max(least / 2.0_f32 - half, 0.0_f32)) : 0.0_f32
      extent = half + gap
      cx     = extent + @x / 255.0_f32 * Math.max(width - 2.0_f32 * extent, 0.0_f32)
      cy     = extent + @y / 255.0_f32 * Math.max(height - 2.0_f32 * extent, 0.0_f32)
      if @line.double?
        cx  = (cx - half).round + half
        cy  = (cy - half).round + half
        gap = Math.max(gap.round, thick.ceil)
      end
      flip_x = @mirror.x?
      flip_y = @mirror.y?
      arms   = Stroke.turn(@line.double? ? reach : @arms, flip_x, flip_y)
      arcs   = @line.double? ? [] of Arc : arcs(Stroke.turn(@bends, flip_x, flip_y), width, height, cx, cy)
      radius = Math.min(Math.min(cx, cy), Math.min(width - cx, height - cy))
      fading = !@fade.none?
      step   = 1.0_f32 / SAMPLES
      total  = SAMPLES * SAMPLES
      height.times do |py|
        width.times do |px|
          hits    = 0
          shade   = 0.0_f32
          regions = StaticArray(Int32, 4).new(0)
          SAMPLES.times do |sy|
            y = py + (sy + 0.5_f32) * step
            v = flip_y ? height - y : y
            SAMPLES.times do |sx|
              x = px + (sx + 0.5_f32) * step
              u = flip_x ? width - x : x
              on, region = probe(u, v, width, height, cx, cy, half, thick, gap, radius, arms, arcs)
              if on
                hits += 1
                shade += fade(x, y, width, height) if fading
              end
              regions[Stroke.turn(region, flip_x, flip_y).value.trailing_zeros_count] += 1
            end
          end
          level = fading ? (shade * 255.0_f32 / total).to_i : hits * 255 // total
          yield level.to_u8, regions
        end
      end
    end

    private def settle : Nil
      unless sideways?
        @x      = CENTRE
        @mirror = @mirror & ~Mirror::X
      end
      unless upright?
        @y      = CENTRE
        @mirror = @mirror & ~Mirror::Y
      end
    end

    private def sideways? : Bool
      across = @arms & HORIZONTAL
      !(@arms & VERTICAL).none? || !@bends.none? || !@node.none? || !(across.none? || across == HORIZONTAL) ||
        @fill.north_west? != @fill.north_east? || @fill.south_west? != @fill.south_east? ||
        @tones.north_west != @tones.north_east || @tones.south_west != @tones.south_east
    end

    private def upright? : Bool
      along = @arms & VERTICAL
      !(@arms & HORIZONTAL).none? || !@bends.none? || !@node.none? || !(along.none? || along == VERTICAL) ||
        @fill.north_west? != @fill.south_west? || @fill.north_east? != @fill.south_east? ||
        @tones.north_west != @tones.south_west || @tones.north_east != @tones.south_east
    end

    private def arcs(bends : Corner, width : Int32, height : Int32, cx : Float32, cy : Float32) : Array(Arc)
      arcs = [] of Arc
      return arcs if bends.none?
      {Corner::SouthEast, Corner::SouthWest, Corner::NorthEast, Corner::NorthWest}.each do |corner|
        next unless bends.includes?(corner)
        flip_x = corner.south_west? || corner.north_west?
        flip_y = corner.north_east? || corner.north_west?
        ax     = flip_x ? width - cx : cx
        ay     = flip_y ? height - cy : cy
        radius = Math.min(width - ax, height - ay)
        arcs << Arc.new(corner, flip_x, flip_y, ax, ay, radius, ax + radius, ay + radius)
      end
      arcs
    end

    @[AlwaysInline]
    private def fade(x : Float32, y : Float32, width : Int32, height : Int32) : Float32
      case @fade
      in Fade::None  then 1.0_f32
      in Fade::North then y / height
      in Fade::South then 1.0_f32 - y / height
      in Fade::West  then x / width
      in Fade::East  then 1.0_f32 - x / width
      end
    end

    private def probe(u : Float32, v : Float32, width : Int32, height : Int32, cx : Float32, cy : Float32,
                      half : Float32, thick : Float32, gap : Float32, radius : Float32, arms : Arm,
                      arcs : Array(Arc)) : Tuple(Bool, Corner)
      region = if v >= cy
                 u >= cx ? Corner::SouthEast : Corner::SouthWest
               else
                 u >= cx ? Corner::NorthEast : Corner::NorthWest
               end
      on = false
      if @line.double?
        on = rail(v, cy, u, cx, half, gap, arms.east?, arms.west?, arms.north?, arms.south?) ||
             rail(u, cx, v, cy, half, gap, arms.south?, arms.north?, arms.west?, arms.east?)
      elsif !arms.none?
        across = (v - cy).abs <= half
        along  = (u - cx).abs <= half
        on = (arms.east? && u >= cx - half && across) || (arms.west? && u <= cx + half && across) ||
             (arms.south? && v >= cy - half && along) || (arms.north? && v <= cy + half && along)
      end
      arcs.each do |arc|
        a = arc.flip_x ? width - u : u
        b = arc.flip_y ? height - v : v
        if a < arc.ox && b < arc.oy
          reach = Math.sqrt((a - arc.ox) * (a - arc.ox) + (b - arc.oy) * (b - arc.oy))
          on ||= (reach - arc.radius).abs <= half
          if reach <= arc.radius
            region = arc.corner
          elsif region == arc.corner
            region = Stroke.turn(arc.corner, true, true)
          end
        else
          gap = Float32::INFINITY
          gap = Math.min(gap, (a - arc.cx).abs) if b >= arc.oy
          gap = Math.min(gap, (b - arc.cy).abs) if a >= arc.ox
          on ||= gap <= half
        end
      end
      unless @node.none?
        reach = Math.sqrt((u - cx) * (u - cx) + (v - cy) * (v - cy))
        inner = radius - thick
        on    = false if @node.hollow? && reach < inner
        on ||= reach <= radius && (@node.filled? || reach >= inner)
      end
      {on && !@line.none?, region}
    end

    @[AlwaysInline]
    private def rail(across : Float32, centre : Float32, along : Float32, middle : Float32, half : Float32,
                     gap : Float32, ahead : Bool, behind : Bool, low : Bool, high : Bool) : Bool
      return false unless ahead || behind
      {-1.0_f32, 1.0_f32}.each do |side|
        next unless (across - (centre + side * gap)).abs <= half
        near  = side < 0 ? low : high
        far   = side < 0 ? high : low
        start = if near
                  gap - half
                elsif far
                  -gap - half
                elsif ahead && behind
                  -Float32::INFINITY
                else
                  -half
                end
        return true if ahead && along >= middle + start
        return true if behind && along <= middle - start
      end
      false
    end
  end

  module Strokes
    extend self

    @@pool = Interner(Stroke).new

    def intern(stroke : Stroke) : UInt32
      @@pool.intern(stroke).to_u32 + 1_u32
    end

    def [](id : UInt32) : Stroke
      @@pool[(id - 1).to_i32]
    end
  end
end
