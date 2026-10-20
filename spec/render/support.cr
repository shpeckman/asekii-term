# spec/render/support.cr
require "spec"
require "../../src/asekii-term/render"
require "../palette16"

class Engine
  getter compositor : Asekii::Render::Compositor
  getter themes     : Asekii::Render::Themes

  def initialize(cols : Int32 = 20, rows : Int32 = 5)
    @buf    = Bytewire.new
    @themes = Asekii::Render::Themes.new
    @themes.depth = Asekii::Render::ColorDepth::TrueColor
    @themes.output = -> { @buf }
    @compositor = Asekii::Render::Compositor.new
    @compositor.themes = @themes
    @compositor.resize(cols, rows)
    @themes.on_palette = -> { @compositor.pile.damage_all }
  end

  def plane(cols : Int32, rows : Int32, x : Int32 = 0, y : Int32 = 0) : Asekii::Render::Plane
    @compositor.plane(cols, rows, x, y)
  end

  def planes_top : Asekii::Render::Plane
    @compositor.pile.planes.last
  end

  def frame : String
    @buf.reset
    @compositor.render(@buf)
    String.new(@buf.written)
  end

  def compose : Nil
    @compositor.pile.compose(@themes, @compositor.blend)
  end

  def at(x : Int32, y : Int32) : Asekii::Render::Tile
    @compositor.at(x, y)
  end
end
