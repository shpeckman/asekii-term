# src/asekii-term/render.cr
require "bytewire"
require "compress/zlib"
require "sync/mutex"
require "sync/exclusive"
require "wait_group"

require "termwidth"

require "./unicode_placeholder"
require "./color_syntax"
require "./kitty_graphics"
require "./raster"

module Asekii::Render
end

require "./render/interner"
require "./render/color_space"
require "./render/palette"
require "./render/paint"
require "./render/text_layout"
require "./render/stroke"
require "./render/canvas"
require "./render/role_spec"
require "./render/theme"
require "./render/sprite"
require "./render/bitmap"
require "./render/plane"
require "./render/stroke_images"
require "./render/pile"
require "./render/compositor"
