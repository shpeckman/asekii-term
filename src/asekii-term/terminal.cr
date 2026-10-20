# src/asekii-term/terminal.cr
require "base64"
require "uuid"
require "compress/zlib"
require "openssl/hmac"
require "sync/mutex"
require "sync/exclusive"
require "uri"
require "bytewire"
require "tty"

require "termwidth"

require "./unicode_placeholder"
require "./color_syntax"
require "./kitty_graphics"
require "./raster"

module Asekii::Event
end

class Asekii::Terminal
end

require "./terminal/config"
require "./terminal/wire"
require "./terminal/session"
require "./terminal/events"
require "./terminal/parser"
require "./terminal/engine"
require "./terminal/color"
require "./terminal/clipboard"
require "./terminal/graphics"
require "./terminal/notify"
require "./terminal/dnd"
require "./terminal/identity"
require "./terminal/passthrough"
require "./terminal/indicators"
