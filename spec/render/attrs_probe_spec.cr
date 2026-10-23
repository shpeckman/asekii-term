# spec/render/attrs_probe_spec.cr
require "./support"

describe "attrs-only probe" do
  it "emits bold when attrs change alone" do
    stage = Engine.new
    plane = stage.plane(20, 1)
    plane.put(0, 0, "item 1")
    first = stage.frame
    puts "first: #{first.inspect}"

    plane.put(0, 0, "item 1", attrs: Asekii::Render::Attr::Bold)
    second = stage.frame
    puts "second: #{second.inspect}"
    second.includes?("\e[1m").should be_true
  end

  it "emits bold after an erase-and-repaint cycle" do
    stage = Engine.new
    plane = stage.plane(20, 1)
    plane.put(0, 0, "item 1")
    stage.frame

    plane.erase(0, 0, 20, 1)
    plane.put(0, 0, "item 1", attrs: Asekii::Render::Attr::Bold)
    second = stage.frame
    puts "second: #{second.inspect}"
    second.includes?("\e[1m").should be_true
  end
end
