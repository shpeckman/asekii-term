# spec/render/text_layout_spec.cr
require "./support"

describe Asekii::Render::TextLayout do
  it "measures text in cells and splits it into grapheme clusters" do
    Asekii::Render::TextLayout.width("a日b").should eq(4)
    Asekii::Render::TextLayout.clusters("é日").should eq(["é", "日"])
  end

  it "wraps at word boundaries and breaks words that are too long" do
    Asekii::Render::TextLayout.wrap("hello world", 8).should eq(["hello", "world"])
    Asekii::Render::TextLayout.wrap("one two\nthree", 20).should eq(["one two", "three"])
    Asekii::Render::TextLayout.wrap("abcdefgh", 3).should eq(["abc", "def", "gh"])
    Asekii::Render::TextLayout.wrap("", 5).should eq([""])
  end

  it "wraps at any grapheme without splitting a wide one" do
    Asekii::Render::TextLayout.wrap("abcdef", 4, Asekii::Render::Wrap::Grapheme).should eq(["abcd", "ef"])
    Asekii::Render::TextLayout.wrap("a日本語", 3, Asekii::Render::Wrap::Grapheme).should eq(["a日", "本", "語"])
    Asekii::Render::TextLayout.wrap("ab\ncd", 0, Asekii::Render::Wrap::Grapheme).should eq(["ab", "cd"])
  end

  it "truncates to a width with an optional tail" do
    Asekii::Render::TextLayout.truncate("abcdef", 4).should eq("abcd")
    Asekii::Render::TextLayout.truncate("abcdef", 4, "…").should eq("abc…")
    Asekii::Render::TextLayout.truncate("日本語", 3, "…").should eq("日…")
    Asekii::Render::TextLayout.truncate("abc", 5, "…").should eq("abc")
    Asekii::Render::TextLayout.truncate("abc", 0, "…").should eq("")
  end

  it "maps between grapheme indexes and columns" do
    Asekii::Render::TextLayout.column("a日b", 0).should eq(0)
    Asekii::Render::TextLayout.column("a日b", 2).should eq(3)
    Asekii::Render::TextLayout.column("a日b", 9).should eq(4)
    Asekii::Render::TextLayout.index("a日b", 0).should eq(0)
    Asekii::Render::TextLayout.index("a日b", 1).should eq(1)
    Asekii::Render::TextLayout.index("a日b", 2).should eq(1)
    Asekii::Render::TextLayout.index("a日b", 3).should eq(2)
    Asekii::Render::TextLayout.index("a日b", 9).should eq(3)
  end

  it "offsets text for an alignment" do
    Asekii::Render::TextLayout.offset("日本", 10, Asekii::Render::HorizontalAlignment::Right).should eq(6)
    Asekii::Render::TextLayout.offset("abcd", 10, Asekii::Render::HorizontalAlignment::Center).should eq(3)
  end
end

describe Asekii::Render::TextLayout do
  it "breaks an over-long word wherever it falls and keeps blank lines" do
    Asekii::Render::TextLayout.wrap("aaaaaaaaaaaa bb", 5).should eq(["aaaaa", "aaaaa", "aa bb"])
    Asekii::Render::TextLayout.wrap("x aaaaaaaa", 5).should eq(["x", "aaaaa", "aaa"])
    Asekii::Render::TextLayout.wrap("a\n\nb", 5).should eq(["a", "", "b"])
    Asekii::Render::TextLayout.wrap("abcd\nef", 4, Asekii::Render::Wrap::Grapheme).should eq(["abcd", "ef"])
    Asekii::Render::TextLayout.wrap("a\n\nb", 4, Asekii::Render::Wrap::Grapheme).should eq(["a", "", "b"])
  end

  it "expands tabs to tab stops" do
    Asekii::Render::TextLayout.expand_tabs("a\tb").should eq("a       b")
    Asekii::Render::TextLayout.expand_tabs("ab\tc\n\td", 4).should eq("ab  c\n    d")
    Asekii::Render::TextLayout.expand_tabs("plain").should eq("plain")
  end
end

describe Asekii::Render::TextLayout do
  it "measures single clusters and runs of clusters" do
    clusters = Asekii::Render::TextLayout.clusters("a日❤️b")
    Asekii::Render::TextLayout.cluster_width("日").should eq(2)
    Asekii::Render::TextLayout.cluster_width("❤️").should eq(2)
    Asekii::Render::TextLayout.width(clusters).should eq(6)
    Asekii::Render::TextLayout.width(clusters, 1, 3).should eq(4)
    Asekii::Render::TextLayout.width(clusters, 2).should eq(3)
    Asekii::Render::TextLayout.width(clusters, -4, 99).should eq(6)
    Asekii::Render::TextLayout.width(clusters, 3, 1).should eq(0)
  end

  it "finds the cluster at a column in a run of clusters" do
    clusters = Asekii::Render::TextLayout.clusters("a日b")
    Asekii::Render::TextLayout.index(clusters, 0).should eq(0)
    Asekii::Render::TextLayout.index(clusters, 2).should eq(1)
    Asekii::Render::TextLayout.index(clusters, 3).should eq(2)
    Asekii::Render::TextLayout.index(clusters, 9).should eq(3)
    Asekii::Render::TextLayout.index(clusters, 2, nearest: true).should eq(2)
    Asekii::Render::TextLayout.index(clusters, 1, from: 1).should eq(1)
    Asekii::Render::TextLayout.index(clusters, 2, from: 1).should eq(2)
    Asekii::Render::TextLayout.index(clusters, 9, to: 2).should eq(2)
    Asekii::Render::TextLayout.index("a日b", 2, nearest: true).should eq(2)
  end

  it "finds the longest suffix that fits" do
    clusters = Asekii::Render::TextLayout.clusters("a日bc")
    Asekii::Render::TextLayout.fit_tail(clusters, 9).should eq(0)
    Asekii::Render::TextLayout.fit_tail(clusters, 4).should eq(1)
    Asekii::Render::TextLayout.fit_tail(clusters, 3).should eq(2)
    Asekii::Render::TextLayout.fit_tail(clusters, 0).should eq(4)
    Asekii::Render::TextLayout.fit_tail(clusters, 2, to: 2).should eq(1)
    Asekii::Render::TextLayout.fit_tail(clusters, 1, to: 2).should eq(2)
  end

  it "classifies clusters" do
    Asekii::Render::TextLayout.cluster_class("é").should eq(Asekii::Render::CharClass::Word)
    Asekii::Render::TextLayout.cluster_class(" ").should eq(Asekii::Render::CharClass::Space)
    Asekii::Render::TextLayout.cluster_class(",").should eq(Asekii::Render::CharClass::Punct)
    Asekii::Render::TextLayout.cluster_class("😀").should eq(Asekii::Render::CharClass::Other)
  end

  it "wraps after any white space but not after a no-break space" do
    Asekii::Render::TextLayout.wrap("ab　cd", 3).should eq(["ab", "cd"])
    Asekii::Render::TextLayout.wrap("ab cd", 3).should eq(["ab ", "cd"])
    Asekii::Render::TextLayout.wrap("ab\r\ncd", 10).should eq(["ab", "cd"])
  end

  it "truncates without splitting a cluster" do
    Asekii::Render::TextLayout.truncate("ééé", 2).should eq("éé")
    Asekii::Render::TextLayout.truncate("a日b", 2, "…").should eq("a…")
    Asekii::Render::TextLayout.truncate("abc", 2, "日日").should eq("日日")
  end

  it "measures with the configured width profile" do
    previous = Asekii::Render::Graphemes.profile
    begin
      Asekii::Render::TextLayout.width("¡").should eq(1)
      Asekii::Render::Graphemes.profile = TermWidth::WidthProfile::UNICODE_WIDE
      Asekii::Render::Graphemes.profile.should eq(TermWidth::WidthProfile::UNICODE_WIDE)
      Asekii::Render::TextLayout.width("¡").should eq(2)
      Asekii::Render::TextLayout.cluster_width("¡").should eq(2)
    ensure
      Asekii::Render::Graphemes.profile = previous
    end
  end
end
