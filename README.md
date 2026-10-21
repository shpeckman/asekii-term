# asekii-term

The terminal and render systems of the [asekii](https://github.com/shpeckman/asekii) framework, in
one shard. It holds the kitty terminal protocols, a layered render engine with damage tracking, and
the pixel and colour primitives the two share — all under the `Asekii::` namespace.

`asekii-term` is the layer below the asekii widget toolkit; it depends on nothing from it. The
terminal and render systems are independent of each other: neither requires the other, and the code
they share lives in four leaf files at the top of `src/asekii-term/`.

## Installation

Add it to your `shard.yml`:

```yaml
dependencies:
  asekii-term:
    github: shpeckman/asekii-term
```

## Requiring

```crystal
require "asekii-term"            # both systems
require "asekii-term/terminal"   # Asekii::Terminal and Asekii::Event
require "asekii-term/render"     # Asekii::Render
```

Each entry point compiles on its own and pulls only its own dependencies (`bytewire`, `tty` and
`termwidth` for the terminal; `bytewire` and `termwidth` for the render engine).

## The terminal

`Asekii::Terminal` is usable on its own, with no app around it. It puts the terminal into raw mode,
turns everything it sends into typed events on a channel, and gives you a method for everything you
send back:

```crystal
require "asekii-term/terminal"

Asekii::Terminal.open do |term|
  term.pointer = Asekii::Terminal::Shape::Pointer
  while event = term.events.receive?
    case event
    when Asekii::Event::Key   then break if event.named.try(&.escape?)
    when Asekii::Event::Mouse then puts "#{event.col},#{event.row}"
    end
  end
end
```

It covers the Kitty keyboard protocol with taps, holds, chords and key sequences; pixel-precise mouse
reporting with clicks, drags, hover, scroll and swipe gestures; resize, focus, visibility and
colour-scheme notifications; pointer shapes; the colour stack; MIME-typed clipboard and paste; the
kitty graphics protocol including animation and Unicode placeholders; desktop notifications; and drag
and drop, including remote files. On terminals that lack these protocols it falls back to legacy
keyboard input, cell-based mouse reports and bracketed paste.

Every fire-and-forget graphics command also has an encoder that returns the escape code instead of
sending it, for writing into a frame of your own: `image_code`, `frame_code`, `Terminal.compose_code`,
`Terminal.animate_code`, `Terminal.place_code` and `Terminal.delete_code`. `supports_graphics?` and
`supports_indexed?` query whether the terminal takes images at all and palette-indexed pixels
(`f=8`/`f=16`) in particular. `sixel_code` and `inline_image_code` encode the same `Pixels` as Sixel
and as an iTerm2 inline image, `sixel` and `inline_image` send them at the cursor, and
`image_protocol` names the best of the three the terminal takes.

`attributes` returns the primary device attributes (`DA1`); `identity` asks once for the terminal's
name and version (`XTVERSION`) and its secondary attributes (`DA2`) and keeps the answer. Several
protocols have an older, more widely supported form — `OSC 52` clipboard, `OSC 9`/`OSC 777`
notifications, `OSC 4` palette reads, `OSC 11` light-or-dark, Sixel and iTerm2 images — and the
terminal picks the fallback when the kitty one is missing. Set `config.detect = false` to assume every
kitty protocol and mode.

The gesture engine (holds, taps, multi-clicks, long presses, hover dwell, scroll coalescing, key
sequences) times events with `config.clock`, an `Asekii::Clock` that defaults to
`Asekii::Clock::SYSTEM`. A clock answers `now`, says how long a sleeper may wait for a deadline
(`budget`), and calls the procs registered with `watch` when it jumps, so a test clock can freeze time
and still wake the engine when it moves. Capability queries keep using real time. The render engine's
theme transitions read time through `Themes#now`.

`title=` sets the window title (`OSC 2`) and restores it on exit; `bell` rings; `progress` shows a
fraction in the taskbar or tab (`OSC 9;4`) and `clear_progress` removes it. Inside tmux (`$TMUX`) or
GNU screen (`$STY`) the terminal wraps the kitty-family sequences in the multiplexer's passthrough so
they reach the terminal outside.

## The render engine

`Asekii::Render` is framework-agnostic: plain classes that take bytes out and callbacks in. Planes
hold styled cells, a `Pile` composites them with damage tracking, and the compositor emits
differential ANSI:

```crystal
require "asekii-term/render"

compositor = Asekii::Render::Compositor.new
plane      = compositor.plane(40, 10, 0, 0)
plane.put(1, 1, "hello")
buffer = Bytewire.new(4096)
compositor.render(buffer)
STDOUT.write(buffer.written)
```

A plane shows only inside its parent's window when the parent has `clip` set, and only inside its own
`bounds` when it has them: an absolute `{left, top, right, bottom}` that clips the plane and every
plane inside it.

A plane can also hold stroke cells — the pieces tiled borders are made of. Tell the compositor the
cell size in pixels and it composites each one into an image, uploads it inline in the frame and
frees it once nothing on screen shows it:

```crystal
compositor.cell_pixels(10, 22)
plane.stroke(0, 0, Asekii::Render::Stroke.new(Asekii::Render::Stroke::Piece::TopLeft, round: true, width: 2), :accent)
```

A stroke is described by what it connects — `arms`, `bends`, `node`, `fade`, `fill`, `width`,
`position` and `mirror` — so the same tile pipeline draws border pieces, junctions and graph lanes.
`Stroke.branch` returns the shape of any codepoint in kitty's and Ghostty's branch-drawing range
(U+F5D0–U+F60D), drawn as tiles so they take the stroke width and colours like a border.

`Render::Bitmap` is RGBA (`0xRRGGBBAA`) with `fill`, `blend`, `line`, `disc` and `arc`. `Render::Theme`
and `Render::Themes` map colour roles to palettes; `Render::TextLayout` wraps termwidth's line
wrapping and character classification. On a terminal that takes palette-indexed pixels, set
`compositor.indexed_tiles = true` to upload border tiles at half the size and let the terminal
recolour them when its theme changes.

## The shared foundation

Four leaf files hold what both systems use. Neither layer requires the other, so anything they share
lives here and requires only external shards:

- `Asekii::Raster` (`raster.cr`) — decodes PNG (every colour type, bit depth and interlacing) and raw
  RGB or RGBA, and crops, scales and encodes to PNG or Sixel. `Asekii::ImageProtocol` names the image
  transport the terminal takes: `Kitty`, `Sixel`, `Iterm` or `None`.
- `Asekii::KittyGraphics` (`kitty_graphics.cr`) — the shared kitty delete and place command builders
  both the terminal's image encoders and the compositor's inline pictures use.
- `Asekii::ColorSyntax` (`color_syntax.cr`) — the `#hex` / `rgb:` / `rgbi:` colour-string grammar.
- `Asekii::UnicodePlaceholder` (`unicode_placeholder.cr`) — the kitty placeholder character, its 297
  row and column diacritics, and `cell`, which builds a whole placeholder cluster.

## Graphemes and cell width

Graphemes and cell width come from [termwidth](https://github.com/shpeckman/termwidth), a separate
shard. asekii-term re-exports nothing from it; use `TermWidth` directly:

```crystal
require "termwidth"

seg = TermWidth::Segmenter::NARROW
seg.each("ab日é") { |cluster, width| }
```

The render engine segments every string it draws with `Asekii::Render::Graphemes.segmenter`; set
`Asekii::Render::Graphemes.profile = TermWidth::WidthProfile::UNICODE_WIDE` to switch every plane to
another width profile.

## Development

```sh
make shards    # install and prune dependencies
make spec      # the terminal and render suites
make layers    # type-check each layer on its own
make run       # the protocol flakiness matrix, before a release
```

## License

MIT. See [LICENSE](LICENSE).
