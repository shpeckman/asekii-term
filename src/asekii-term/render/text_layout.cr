# src/asekii/render/text_layout.cr
module Asekii::Render
  alias Wrap = ::TermWidth::Wrap
  alias CharClass = ::TermWidth::CharClass

  module TextLayout
    extend self

    NEWLINE  = 0x0A_u8
    TAB      = 0x09_u8
    TAB_SIZE =       8

    def width(text : String) : Int32
      Graphemes.segmenter.measure(text)
    end

    def width(clusters : Array(String), from : Int32 = 0, to : Int32 = clusters.size) : Int32
      segmenter = Graphemes.segmenter
      stop = to.clamp(0, clusters.size)
      index = Math.max(from, 0)
      total = 0
      while index < stop
        total += segmenter.cluster_width(clusters.unsafe_fetch(index)).to_i
        index += 1
      end
      total
    end

    def cluster_width(cluster : String) : Int32
      Graphemes.segmenter.cluster_width(cluster).to_i
    end

    def cluster_class(cluster : String) : CharClass
      ::TermWidth.cluster_class(cluster)
    end

    def clusters(text : String) : Array(String)
      clusters = [] of String
      Graphemes.each(text) { |cluster, _| clusters << String.new(cluster) }
      clusters
    end

    def lines(text : String) : Array(String)
      text.split('\n')
    end

    def expand_tabs(text : String, size : Int32 = TAB_SIZE) : String
      return text unless text.includes?('\t')

      String.build do |io|
        column = 0
        Graphemes.each(text) do |cluster, span|
          first = cluster.unsafe_fetch(0)

          if cluster.size == 1 && first == TAB
            pad = size - column % size
            pad.times { io << ' ' }
            column += pad
          else
            io.write(cluster)
            column = cluster.size == 1 && first == NEWLINE ? 0 : column + span.to_i
          end
        end
      end
    end

    def wrap(text : String, width : Int32, mode : Wrap = Wrap::Word) : Array(String)
      bytes = text.to_slice
      lines = [] of String
      Graphemes.segmenter.each_line(bytes, width, mode) do |line|
        lines << String.new(bytes[line.start, line.content])
      end
      lines
    end

    def truncate(text : String, width : Int32, tail : String = "") : String
      return "" if width <= 0

      segmenter = Graphemes.segmenter
      bytes = text.to_slice
      return text if segmenter.measure(bytes) <= width

      cut = segmenter.locate(bytes, column: width - segmenter.measure(tail)).byte
      String.build(cut + tail.bytesize) do |io|
        io.write(bytes[0, cut])
        io << tail
      end
    end

    def offset(text : String, width : Int32, align : HorizontalAlignment) : Int32
      align.offset(width(text), width)
    end

    def column(text : String, index : Int32) : Int32
      Graphemes.segmenter.locate(text, index: index).column
    end

    def index(text : String, column : Int32, nearest : Bool = false) : Int32
      Graphemes.segmenter.locate(text, column: column, nearest: nearest).index
    end

    def index(clusters : Array(String), column : Int32, from : Int32 = 0, to : Int32 = clusters.size,
              nearest : Bool = false) : Int32
      segmenter = Graphemes.segmenter
      stop = to.clamp(0, clusters.size)
      index = Math.max(from, 0)
      edge = 0
      while index < stop
        extent = segmenter.cluster_width(clusters.unsafe_fetch(index)).to_i
        return index if column < edge + (nearest ? (extent + 1) // 2 : extent)
        edge += extent
        index += 1
      end
      Math.min(index, stop)
    end

    def fit_tail(clusters : Array(String), cols : Int32, to : Int32 = clusters.size) : Int32
      segmenter = Graphemes.segmenter
      index = to.clamp(0, clusters.size)
      used = 0
      while index > 0
        extent = segmenter.cluster_width(clusters.unsafe_fetch(index - 1)).to_i
        break if used + extent > cols
        used += extent
        index -= 1
      end
      index
    end
  end

  enum HorizontalAlignment
    Left
    Center
    Right

    def offset(content : Int32, available : Int32) : Int32
      case self
      in HorizontalAlignment::Left   then 0
      in HorizontalAlignment::Center then Math.max((available - content) // 2, 0)
      in HorizontalAlignment::Right  then Math.max(available - content, 0)
      end
    end
  end

  enum VerticalAlignment
    Top
    Middle
    Bottom

    def offset(content : Int32, available : Int32) : Int32
      case self
      in VerticalAlignment::Top    then 0
      in VerticalAlignment::Middle then Math.max((available - content) // 2, 0)
      in VerticalAlignment::Bottom then Math.max(available - content, 0)
      end
    end
  end
end
