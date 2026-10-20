# src/asekii/render/interner.cr
module Asekii::Render
  class Interner(T)
    SHIFT  = 10
    CHUNK  = 1 << SHIFT
    MASK   = CHUNK - 1
    CHUNKS = 1 << 14

    def initialize
      @chunks = Pointer(Pointer(T)).malloc(CHUNKS)
      @ids    = {} of T => Int32
      @size   = Atomic(Int32).new(0)
      @lock   = Sync::Mutex.new
    end

    def intern(value : T, & : T -> T) : Int32
      @lock.synchronize do
        @ids[value]? || begin
          owned = yield value
          index = @size.get
          raise IndexError.new("interner is full") if index >= CHUNKS * CHUNK
          slot = index >> SHIFT
          @chunks[slot] = Pointer(T).malloc(CHUNK) if index & MASK == 0
          @chunks[slot][index & MASK] = owned
          @size.set(index + 1)
          @ids[owned] = index
        end
      end
    end

    def intern(value : T) : Int32
      intern(value) { |found| found }
    end

    def index?(value : T) : Int32?
      @lock.synchronize { @ids[value]? }
    end

    @[AlwaysInline]
    def [](index : Int32) : T
      @chunks[index >> SHIFT][index & MASK]
    end

    def size : Int32
      @size.get
    end
  end
end
