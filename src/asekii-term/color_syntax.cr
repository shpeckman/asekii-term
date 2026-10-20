# src/asekii/color_syntax.cr
require "bytewire"

module Asekii
  module ColorSyntax
    record Channels, red : UInt16, green : UInt16, blue : UInt16

    def self.parse(text : String) : {Channels, Float64}?
      reader  = Bytewire::Reader.new(text)
      body    = reader.take_until?(0x40_u8) || reader.take_rest
      opacity = reader.match?(0x40_u8) ? String.new(reader.take_rest).to_f? : 1.0
      return unless opacity
      cursor = Bytewire::Reader.new(body)
      if cursor.match?("rgb:")
        r = scaled(cursor) || return
        return unless cursor.match?('/')
        g = scaled(cursor) || return
        return unless cursor.match?('/')
        b = scaled(cursor) || return
        return unless cursor.eof?
        {Channels.new(r, g, b), opacity}
      elsif cursor.match?('#') && cursor.remaining.in?(3, 6, 9, 12)
        width = cursor.remaining // 3
        shift = 16 - 4 * width
        r     = cursor.hex?(UInt16, width) || return
        g     = cursor.hex?(UInt16, width) || return
        b     = cursor.hex?(UInt16, width) || return
        return unless cursor.eof?
        {Channels.new(r << shift, g << shift, b << shift), opacity}
      elsif cursor.match?("rgbi:")
        r = float_channel(cursor.take_until?(0x2f_u8)) || return
        return unless cursor.match?('/')
        g = float_channel(cursor.take_until?(0x2f_u8)) || return
        return unless cursor.match?('/')
        b = float_channel(cursor.take_rest) || return
        {Channels.new(r, g, b), opacity}
      end
    end

    private def self.scaled(reader : Bytewire::Reader) : UInt16?
      start = reader.pos
      value = reader.hex?(UInt32) || return
      count = reader.pos - start
      return unless count.in?(1..4)
      (value * 0xffff_u32 // ((1_u32 << (4 * count)) - 1)).to_u16
    end

    private def self.float_channel(slice : Bytes?) : UInt16?
      return unless slice && !slice.empty?
      String.new(slice).to_f?.try { |value| (value.clamp(0.0, 1.0) * 0xffff).round.to_u16 }
    end

    def self.rgb(wire : Bytewire, red : UInt16, green : UInt16, blue : UInt16, bits : Int32) : Bytewire
      wire.str("rgb:")
      channel(wire, red, bits).char('/')
      channel(wire, green, bits).char('/')
      channel(wire, blue, bits)
    end

    private def self.channel(wire : Bytewire, value : UInt16, bits : Int32) : Bytewire
      bits == 16 ? wire.hex2((value >> 8).to_u8!).hex2(value.to_u8!) : wire.hex2(value.to_u8!)
    end
  end

  module ColorMath
    extend self

    def linear(channel : Float64) : Float64
      channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4
    end

    def luminance(r : Float64, g : Float64, b : Float64) : Float64
      0.2126 * r + 0.7152 * g + 0.0722 * b
    end
  end
end
