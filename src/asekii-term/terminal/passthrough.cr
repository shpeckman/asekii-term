# src/asekii-term/terminal/passthrough.cr
class Asekii::Terminal
  WRAPPED = {
    Multiplexer::Tmux   => Set{9, 21, 22, 72, 99, 777, 1337, 5522, 30001, 30101},
    Multiplexer::Screen => Set{9, 21, 22, 52, 72, 99, 777, 1337, 5522, 30001, 30101},
  }

  SCREEN_CHUNK = 768
  TMUX_OPEN    = "\ePtmux;".to_slice
  DCS_OPEN     = "\eP".to_slice
  DCS_CLOSE    = "\e\\".to_slice

  @passthrough : Passthrough?

  def multiplexer : Multiplexer
    @passthrough.try(&.mode) || Multiplexer::None
  end

  private class Passthrough
    enum Phase
      Ground
      Escape
      Code
      Body
      BodyEscape
    end

    getter mode : Multiplexer

    @phase = Phase::Ground
    @code = 0
    @osc = false
    @held = Bytewire.new(1024)

    def self.for(chosen : Multiplexer) : Passthrough?
      mode = chosen
      if mode.auto?
        mode = if ENV["TMUX"]?.presence
                 Multiplexer::Tmux
               elsif ENV["STY"]?.presence
                 Multiplexer::Screen
               else
                 Multiplexer::None
               end
      end
      codes = WRAPPED[mode]? || return
      new(mode, codes)
    end

    def initialize(@mode : Multiplexer, @codes : Set(Int32))
    end

    def pass(bytes : Bytes, io : IO) : Nil
      size = bytes.size
      index = 0
      start = 0
      while index < size
        case @phase
        in .ground?
          found = bytes[index..].index(0x1b_u8)
          unless found
            index = size
            next
          end
          index += found
          io.write(bytes[start, index - start]) if index > start
          @held.reset
          @held.byte(0x1b_u8)
          @phase = Phase::Escape
          index += 1
        in .escape?
          byte = bytes[index]
          case byte
          when 0x5f
            @held.byte(byte)
            @osc = false
            @phase = Phase::Body
            index += 1
          when 0x5d
            @held.byte(byte)
            @osc = true
            @code = 0
            @phase = Phase::Code
            index += 1
          else
            io.write(@held.written)
            @phase = Phase::Ground
            start = index
          end
        in .code?
          byte = bytes[index]
          if 0x30 <= byte <= 0x39
            @code = @code &* 10 &+ (byte &- 0x30)
            @held.byte(byte)
            index += 1
          elsif @codes.includes?(@code)
            @phase = Phase::Body
          else
            io.write(@held.written)
            @phase = Phase::Ground
            start = index
          end
        in .body?
          stop = index
          while stop < size
            byte = bytes[stop]
            break if byte == 0x1b || (@osc && byte == 0x07)
            stop += 1
          end
          @held.bytes(bytes[index, stop - index])
          index = stop
          next if stop == size
          @held.byte(bytes[stop])
          index += 1
          if bytes[stop] == 0x07
            wrap(io)
            start = index
          else
            @phase = Phase::BodyEscape
          end
        in .body_escape?
          byte = bytes[index]
          @held.byte(byte)
          index += 1
          if byte == 0x5c
            wrap(io)
            start = index
          else
            @phase = Phase::Body
          end
        end
      end
      io.write(bytes[start, size - start]) if @phase.ground? && size > start
    end

    private def wrap(io : IO) : Nil
      @phase = Phase::Ground
      sequence = @held.written
      @mode.screen? ? screen(sequence, io) : tmux(sequence, io)
      @held.reset
    end

    private def tmux(sequence : Bytes, io : IO) : Nil
      io.write(TMUX_OPEN)
      start = 0
      sequence.each_with_index do |byte, index|
        next unless byte == 0x1b
        io.write(sequence[start, index + 1 - start])
        io.write_byte(0x1b_u8)
        start = index + 1
      end
      io.write(sequence[start, sequence.size - start]) if sequence.size > start
      io.write(DCS_CLOSE)
    end

    private def screen(sequence : Bytes, io : IO) : Nil
      if @osc && sequence.size >= 2 && sequence[-2] == 0x1b && sequence[-1] == 0x5c
        sequence = Bytes.new(sequence.size - 1).tap do |copy|
          sequence[0, sequence.size - 2].copy_to(copy)
          copy[-1] = 0x07_u8
        end
      end
      start = 0
      while start < sequence.size
        stop = Math.min(start + SCREEN_CHUNK, sequence.size)
        if escape = sequence[start + 1, Math.max(stop - start - 1, 0)].index(0x1b_u8)
          stop = start + 1 + escape + 1
        end
        stop = start + 1 if stop <= start
        io.write(DCS_OPEN)
        io.write(sequence[start, stop - start])
        io.write(DCS_CLOSE)
        start = stop
      end
    end
  end
end
