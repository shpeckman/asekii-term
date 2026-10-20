# src/asekii-term/render/canvas.cr
module Asekii::Render
  module Canvas
    abstract def cols : Int32
    abstract def rows : Int32
    abstract def put(x : Int32, y : Int32, text : String, fg : Paint? = nil, bg : Paint? = nil,
                     attrs : Attr = Attr::None, line : Paint? = nil,
                     link : String? = nil) : Int32
    abstract def fill(x : Int32, y : Int32, cols : Int32, rows : Int32, glyph : Char? = nil,
                      fg : Paint? = nil, bg : Paint? = nil,
                      attrs : Attr = Attr::None, line : Paint? = nil,
                      link : String? = nil) : Nil
    abstract def fill(glyph : Char? = nil, fg : Paint? = nil, bg : Paint? = nil,
                      attrs : Attr = Attr::None, line : Paint? = nil,
                      link : String? = nil) : Nil
    abstract def stroke(x : Int32, y : Int32, stroke : Stroke, fg : Paint? = nil, bg : Paint? = nil) : Nil
    abstract def image(x : Int32, y : Int32, image_id : UInt32, columns : Int32, rows : Int32,
                       placement : UInt32? = nil) : Nil
    abstract def erase : Nil
  end
end
