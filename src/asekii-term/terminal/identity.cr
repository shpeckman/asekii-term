# src/asekii-term/terminal/identity.cr
class Asekii::Terminal
  VERSION_QUERY = "\e[>0q"
  DEVICE_QUERY  = "\e[>c"

  DEVICES = {
    41 => "xterm",
    65 => "vte",
    77 => "mintty",
    83 => "screen",
    84 => "tmux",
    85 => "rxvt-unicode",
  }

  record Attributes, codes : Array(Int32) do
    def includes?(code : Int32) : Bool
      codes.includes?(code)
    end

    def sixel? : Bool
      includes?(4)
    end
  end

  record Device, kind : Int32, version : Int32, extra : Int32

  record Identity, name : String, version : String = "", device : Device? = nil do
    def self.from(text : String?, device : Device?) : Identity?
      if text && !text.empty?
        open = text.index('(')
        space = text.index(' ')
        if open && (space.nil? || open < space)
          return new(text[0, open].strip, text[open + 1..].rchop(')').strip, device)
        end
        return new(text[0, space].strip, text[space + 1..].strip, device) if space
        return new(text.strip, "", device)
      end
      device.try { |found| new(DEVICES[found.kind]? || "", found.version.to_s, found) }
    end

    def matches?(marker : String) : Bool
      name.downcase.includes?(marker)
    end

    def matches?(markers : Enumerable(String)) : Bool
      markers.any? { |marker| matches?(marker) }
    end
  end

  @identity : Identity?
  @identified = Atomic(Bool).new(false)
  @identifying = Sync::Mutex.new

  def attributes(limit : Time::Span = @config.query_timeout) : Attributes?
    request(Query::Attributes, ATTRIBUTES, limit).as?(Attributes)
  end

  def identity(limit : Time::Span = @config.query_timeout) : Identity?
    return @identity if @identified.get
    @identifying.synchronize do
      return @identity if @identified.get
      version = request(Query::Version, VERSION_QUERY, limit, probe: true)
      device = request(Query::Device, DEVICE_QUERY, limit, probe: true)
      found = Identity.from(version.as?(String), device.as?(Device))
      if found || version || device
        @identity = found
        @identified.set(true)
      end
      found
    end
  end
end
