# src/asekii/kitty_graphics.cr
require "bytewire"

module Asekii
  module KittyGraphics
    def self.delete(wire : Bytewire, letter : Char, *, id : UInt32 = 0, number : UInt32 = 0, placement : UInt32 = 0, x : Int32 = 0, y : Int32 = 0, z : Int32 = 0, quiet : Bool = false) : Nil
      wire.apc.str("Ga=d,d=").char(letter)
      wire.str(",q=2") if quiet
      wire.str(",i=").int(id) if id != 0
      wire.str(",I=").int(number) if number != 0
      wire.str(",p=").int(placement) if placement != 0
      wire.str(",x=").int(x) if x != 0
      wire.str(",y=").int(y) if y != 0
      wire.str(",z=").int(z) if z != 0
      wire.st
    end

    def self.place(wire : Bytewire, *, id : UInt32 = 0, number : UInt32 = 0, quiet : Int32 = 0, placement : UInt32 = 0, x : Int32 = 0, y : Int32 = 0, width : Int32 = 0, height : Int32 = 0, offset_x : Int32 = 0, offset_y : Int32 = 0, columns : Int32 = 0, rows : Int32 = 0, z : Int32 = 0, hold_cursor : Bool = false, placeholder : Bool = false, parent : UInt32 = 0, parent_placement : UInt32 = 0, shift_x : Int32 = 0, shift_y : Int32 = 0) : Nil
      wire.apc.str("Ga=p")
      wire.str(",i=").int(id) if id != 0
      wire.str(",I=").int(number) if number != 0
      wire.str(",q=").int(quiet) if quiet != 0
      placement_keys(wire, placement: placement, x: x, y: y, width: width, height: height,
        offset_x: offset_x, offset_y: offset_y, columns: columns, rows: rows, z: z,
        hold_cursor: hold_cursor, placeholder: placeholder, parent: parent,
        parent_placement: parent_placement, shift_x: shift_x, shift_y: shift_y)
      wire.st
    end

    def self.placement_keys(wire : Bytewire, *, placement : UInt32 = 0, x : Int32 = 0, y : Int32 = 0, width : Int32 = 0, height : Int32 = 0, offset_x : Int32 = 0, offset_y : Int32 = 0, columns : Int32 = 0, rows : Int32 = 0, z : Int32 = 0, hold_cursor : Bool = false, placeholder : Bool = false, parent : UInt32 = 0, parent_placement : UInt32 = 0, shift_x : Int32 = 0, shift_y : Int32 = 0) : Nil
      wire.str(",p=").int(placement) if placement != 0
      wire.str(",x=").int(x) if x != 0
      wire.str(",y=").int(y) if y != 0
      wire.str(",w=").int(width) if width != 0
      wire.str(",h=").int(height) if height != 0
      wire.str(",X=").int(offset_x) if offset_x != 0
      wire.str(",Y=").int(offset_y) if offset_y != 0
      wire.str(",c=").int(columns) if columns != 0
      wire.str(",r=").int(rows) if rows != 0
      wire.str(",z=").int(z) if z != 0
      wire.str(",C=1") if hold_cursor
      wire.str(",U=1") if placeholder
      wire.str(",P=").int(parent) if parent != 0
      wire.str(",Q=").int(parent_placement) if parent_placement != 0
      wire.str(",H=").int(shift_x) if shift_x != 0
      wire.str(",V=").int(shift_y) if shift_y != 0
    end
  end
end
