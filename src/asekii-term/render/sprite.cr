# src/asekii/render/sprite.cr
module Asekii::Render
  class Sprite
    BELOW_CELLS = Int32::MIN // 2 - 1

    record Placement, col : Int32, row : Int32, cols : Int32, rows : Int32,
      left : Int32, top : Int32, width : Int32, height : Int32, z : Int32 do
      def cropped? : Bool
        @width > 0
      end
    end

    getter plane        : Plane
    getter image_id     : UInt32
    getter placement_id : UInt32
    getter x            : Int32
    getter y            : Int32
    getter cols         : Int32
    getter rows         : Int32
    getter width        : Int32
    getter height       : Int32
    getter live         : Placement?
    getter? disposed    : Bool
    getter picture      : Raster?
    getter clip         : Tuple(Int32, Int32, Int32, Int32)?
    getter? hidden      : Bool

    property placed : Placement?
    property? stale : Bool
    property ink    : String?
    property inked  : Tuple(Placement, ImageProtocol, Int32, Int32)?

    def initialize(@plane : Plane, @pile : Pile, @image_id : UInt32, @placement_id : UInt32,
                   @x : Int32, @y : Int32, @cols : Int32, @rows : Int32,
                   @width : Int32, @height : Int32)
      @live     = nil
      @placed   = nil
      @disposed = false
      @picture  = nil
      @clip     = nil
      @hidden   = false
      @stale    = false
      @ink      = nil
      @inked    = nil
    end

    def picture=(raster : Raster?) : Raster?
      return raster if raster ? raster.same?(@picture) : @picture.nil?
      @picture = raster
      @width   = raster.try(&.width) || 0
      @height  = raster.try(&.height) || 0
      @ink     = nil
      @inked   = nil
      @stale   = true
      scar
      raster
    end

    def clip=(edges : Tuple(Int32, Int32, Int32, Int32)?) : Tuple(Int32, Int32, Int32, Int32)?
      return edges if edges == @clip
      @clip = edges
      scar
      edges
    end

    def hidden=(value : Bool) : Bool
      return value if value == @hidden
      @hidden = value
      scar
      value
    end

    def move(x : Int32, y : Int32) : Nil
      return if x == @x && y == @y
      scar
      @x = x
      @y = y
      scar
    end

    def resize(cols : Int32, rows : Int32) : Nil
      return if cols == @cols && rows == @rows
      scar
      @cols = Math.max(cols, 0)
      @rows = Math.max(rows, 0)
      scar
    end

    def dispose : Nil
      return if @disposed
      scar
      @disposed = true
      @live     = nil
      @plane.sprites.delete(self)
      @pile.retire(self)
    end

    @[AlwaysInline]
    def covers?(col : Int32, row : Int32) : Bool
      return false unless spot = @live
      col >= spot.col && col < spot.col + spot.cols && row >= spot.row && row < spot.row + spot.rows
    end

    def settle(screen_cols : Int32, screen_rows : Int32, depth : Int32) : Nil
      @live = aim(screen_cols, screen_rows, depth)
    end

    private def aim(screen_cols : Int32, screen_rows : Int32, depth : Int32) : Placement?
      return nil if @disposed || @hidden || @cols <= 0 || @rows <= 0 || !@plane.shown? || @plane.strength <= 0.0_f32
      edges  = @plane.window
      col    = @plane.abs_x + @x
      row    = @plane.abs_y + @y
      floor  = @picture ? screen_rows - 1 : screen_rows
      left   = Math.max(Math.max(col, edges[0]), 0)
      top    = Math.max(Math.max(row, edges[1]), 0)
      right  = Math.min(Math.min(col + @cols, edges[2]), screen_cols)
      bottom = Math.min(Math.min(row + @rows, edges[3]), floor)
      if fence = @clip
        left   = Math.max(left, fence[0])
        top    = Math.max(top, fence[1])
        right  = Math.min(right, fence[2])
        bottom = Math.min(bottom, fence[3])
      end
      return nil if left >= right || top >= bottom
      z = BELOW_CELLS - depth
      if left == col && top == row && right == col + @cols && bottom == row + @rows
        return Placement.new(col, row, @cols, @rows, 0, 0, 0, 0, z)
      end
      return nil if @width <= 0 || @height <= 0
      Placement.new(left, top, right - left, bottom - top,
        (left - col) * @width // @cols, (top - row) * @height // @rows,
        Math.max((right - left) * @width // @cols, 1), Math.max((bottom - top) * @height // @rows, 1), z)
    end

    private def scar : Nil
      @pile.damage(@plane.abs_x + @x, @plane.abs_y + @y, @cols, @rows)
    end
  end
end
