# spec/render/stroke_legacy_spec.cr
require "./support"

private alias Stroke = Asekii::Render::Stroke

private struct LegacyStroke
  SAMPLES = 4

  getter piece : Stroke::Piece
  getter? round : Bool
  getter width : UInt8
  getter position : UInt8
  getter fill : Stroke::Fill

  def initialize(@piece : Stroke::Piece, @round : Bool = false, width : Int = 1, position : Float64 = 0.5,
                 @fill : Stroke::Fill = Stroke::Fill::Cell)
    @width = width.clamp(1, 255).to_u8
    @position = (position.clamp(0.0, 1.0) * 255).round.to_u8
  end

  def mask(width : Int32, height : Int32) : Bytes
    data = Bytes.new(width * height * 2)
    thick = Math.min(@width.to_f32, Math.min(width, height).to_f32)
    half = thick / 2.0_f32
    along = @position / 255.0_f32
    cx = half + along * (width - thick)
    cy = half + along * (height - thick)
    radius = @round ? Math.min(width - cx, height - cy) : 0.0_f32
    flip_x = @piece.right? || @piece.top_right? || @piece.bottom_right?
    flip_y = @piece.bottom? || @piece.bottom_left? || @piece.bottom_right?
    step = 1.0_f32 / SAMPLES
    total = SAMPLES * SAMPLES
    index = 0
    height.times do |py|
      width.times do |px|
        strokes = 0
        fills = 0
        SAMPLES.times do |sy|
          y = py + (sy + 0.5_f32) * step
          v = flip_y ? height - y : y
          SAMPLES.times do |sx|
            x = px + (sx + 0.5_f32) * step
            u = flip_x ? width - x : x
            on, inside = probe(u, v, cx, cy, half, radius)
            strokes += 1 if on
            fills += 1 if covers?(inside)
          end
        end
        data.unsafe_put(index, (strokes * 255 // total).to_u8)
        data.unsafe_put(index + 1, (fills * 255 // total).to_u8)
        index += 2
      end
    end
    data
  end

  private def covers?(inside : Bool) : Bool
    case @fill
    in Stroke::Fill::Cell    then true
    in Stroke::Fill::Inside  then inside
    in Stroke::Fill::Outside then !inside
    in Stroke::Fill::None    then false
    end
  end

  private def probe(u : Float32, v : Float32, cx : Float32, cy : Float32, half : Float32,
                    radius : Float32) : Tuple(Bool, Bool)
    case @piece
    when .top?, .bottom?
      {(v - cy).abs <= half, v >= cy}
    when .left?, .right?
      {(u - cx).abs <= half, u >= cx}
    else
      @round ? arc(u, v, cx, cy, half, radius) : corner(u, v, cx, cy, half)
    end
  end

  private def corner(u : Float32, v : Float32, cx : Float32, cy : Float32, half : Float32) : Tuple(Bool, Bool)
    on = (u >= cx - half && (v - cy).abs <= half) || (v >= cy - half && (u - cx).abs <= half)
    {on, u >= cx && v >= cy}
  end

  private def arc(u : Float32, v : Float32, cx : Float32, cy : Float32, half : Float32,
                  radius : Float32) : Tuple(Bool, Bool)
    ox = cx + radius
    oy = cy + radius
    if u < ox && v < oy
      reach = Math.sqrt((u - ox) * (u - ox) + (v - oy) * (v - oy))
      return {(reach - radius).abs <= half, reach <= radius}
    end
    gap = Float32::INFINITY
    gap = Math.min(gap, (u - cx).abs) if v >= oy
    gap = Math.min(gap, (v - cy).abs) if u >= ox
    {gap <= half, u >= cx && v >= cy}
  end
end

private SIZES     = [{8, 16}, {9, 18}, {7, 15}, {10, 21}, {12, 24}, {16, 8}, {6, 6}, {3, 7}, {2, 1}, {1, 1}]
private WIDTHS    = [1, 2, 3, 5, 40]
private POSITIONS = [0.0, 0.1, 0.25, 0.3, 0.5, 0.75, 0.9, 1.0]

describe "Asekii::Render::Stroke border masks" do
  it "rasterises every border piece byte for byte as the piece model did" do
    checked = 0
    Stroke::Piece.each do |piece|
      {false, true}.each do |round|
        WIDTHS.each do |width|
          POSITIONS.each do |position|
            Stroke::Fill.each do |fill|
              legacy = LegacyStroke.new(piece, round, width, position, fill)
              current = Stroke.new(piece, round, width, position, fill)
              SIZES.each do |cols, rows|
                unless current.mask(cols, rows) == legacy.mask(cols, rows)
                  fail "#{piece} round=#{round} width=#{width} position=#{position} fill=#{fill} at #{cols}x#{rows}"
                end
                checked += 1
              end
            end
          end
        end
      end
    end
    checked.should eq(8 * 2 * WIDTHS.size * POSITIONS.size * 4 * SIZES.size)
  end

  it "keeps the fallback glyph of every border piece" do
    sharp = StaticArray['─', '─', '│', '│', '┌', '┐', '└', '┘']
    rounded = StaticArray['─', '─', '│', '│', '╭', '╮', '╰', '╯']
    Stroke::Piece.each do |piece|
      Stroke.new(piece).glyph.should eq(sharp[piece.value])
      Stroke.new(piece, round: true).glyph.should eq(rounded[piece.value])
    end
  end
end
