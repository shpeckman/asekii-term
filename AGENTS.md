# AGENTS.md

Orientation for AI agents working on asekii-term. `README.md` is the reference for usage and the
public API; this file covers how the code is laid out and the rules it keeps.

## What this is

asekii-term is the bottom of the asekii stack: the kitty terminal protocols and a layered render
engine, in one shard and one `Asekii::` namespace. The asekii widget toolkit depends on it; it
depends on nothing from asekii.

Its two systems are **independent** — `terminal.cr` and `render.cr` never require each other — and
the code they share lives in four leaf files at the top of `src/asekii-term/` that require only
external shards. Anything shared between the two goes in a leaf file, never in one layer and never in
a copy.

| Entry point                  | Holds                                                                                         | May require              |
|------------------------------|-----------------------------------------------------------------------------------------------|--------------------------|
| `src/asekii-term/terminal.cr` | `Asekii::Terminal`, `Asekii::Event` — raw mode, input decoding, the protocols                | termwidth, bytewire, tty |
| `src/asekii-term/render.cr`   | `Asekii::Render` — planes, compositing, palettes, themes, text layout                        | termwidth, bytewire      |

`src/asekii-term.cr` requires both and adds nothing of its own. There is no `version.cr` here —
`Asekii::VERSION` is defined by the asekii umbrella.

## Namespaces

| Namespace                 | Lives in                 | What it is                                                          |
|---------------------------|--------------------------|----------------------------------------------------------------------|
| `Asekii::Terminal`        | `terminal/`              | the terminal itself: a class, with its protocol types nested          |
| `Asekii::Event`           | `terminal/events.cr`     | everything postable on the bus, plus the input domain (`Mods`, `Named`, `Direction`, `Shortcut`, `Size`, …) |
| `Asekii::Render`          | `render/`                | the render engine                                                    |
| `Asekii::Raster`          | `raster.cr`              | PNG/Sixel/iTerm2 decoding and encoding                                |
| `Asekii::ImageProtocol`   | `raster.cr`              | `Kitty`, `Sixel`, `Iterm`, `None`                                     |
| `Asekii::KittyGraphics`   | `kitty_graphics.cr`      | shared kitty delete and place command builders                        |
| `Asekii::ColorSyntax`     | `color_syntax.cr`        | the `#hex` / `rgb:` / `rgbi:` colour grammar                          |
| `Asekii::UnicodePlaceholder` | `unicode_placeholder.cr` | the kitty placeholder cluster and its diacritics                      |

`Asekii::Event` owns the input domain: `terminal/events.cr` moved across whole, so `Mods`, `Named`,
`Direction`, `Shortcut`, `Timer`, `Size`, `COMMAND`, `LOCKS`, `MODIFIERS` and `Event.code` live there.
Everything that is a *reply* or a *capability* — `Status`, `Clipboard`, `Palette`, `Color`, `Notice`,
`Pixels`, `Placement`, `Feature`, `Query`, `Mode`, `Config` — stays nested in `Asekii::Terminal`.
Inside `class Asekii::Terminal`, a moved type is written `Event::Key`; inside `module Asekii::Event`,
a reference back is `Terminal::Query`.

## Repository layout

```
shard.yml                                      bytewire, tty, termwidth
makefile                                       shards, spec, layers, run, bench
src/asekii-term.cr                             both systems
src/asekii-term/terminal.cr                    entry: opens Asekii::Event and Asekii::Terminal, then the parts
src/asekii-term/terminal/                      the Terminal class split by concern (config, wire, session, events, parser, engine, color, clipboard, graphics, notify, dnd, identity, passthrough, indicators)
src/asekii-term/render.cr                      entry: opens Asekii::Render, then the engine in dependency order
src/asekii-term/render/                        interner, color_space, palette, paint, text_layout, stroke, canvas, role_spec, theme, theme_enums, sprite, bitmap, plane, stroke_images, pile, compositor
src/asekii-term/common/raster.cr               Asekii::ImageProtocol and Asekii::Raster: PNG, scaling, Sixel, iTerm2
src/asekii-term/common/kitty_graphics.cr       Asekii::KittyGraphics: the shared kitty delete and place builders
src/asekii-term/common/color_syntax.cr         Asekii::ColorSyntax: the shared colour grammar
src/asekii-term/common/unicode_placeholder.cr  Asekii::UnicodePlaceholder: the kitty placeholder table
spec/terminal/terminal_spec.cr                 the protocol suite; drives Terminal over pipes and real PTYs
spec/terminal/run.sh                           the protocol matrix, before a release
spec/render/                                   the engine suite; Engine drives it with a Bytewire, no app
spec/palette16.cr                              the 16-colour reference palettes the render specs use
bench/run.cr                                   the benchmark entry; requires the three suites below
bench/render_bench.cr                          plane, compositor, text layout, colour space, palette, stroke
bench/terminal_bench.cr                        colour grammar, shortcuts, kitty command builders
bench/raster_bench.cr                          PNG, scaling, Sixel
```

`make` prunes `lib/*` down to `shard.yml` and `src`, so the dependencies' own specs and AGENTS.md are
not available after `make shards`.

## Commands

```sh
make shards    # install and prune dependencies
make spec      # the terminal and render suites (spec/terminal spec/render)
make layers    # type-check terminal.cr and render.cr each on its own
make run       # the protocol flakiness matrix (spec/terminal/run.sh)
make bench     # the benchmark suite (crystal run --release bench/run.cr)
```

`make layers` is the boundary check for this shard: each layer compiles without the other, which is
what keeps the terminal and render systems independent. A change is verified two ways — its layer
still compiles alone, and its spec suite still passes.

## Layer boundaries

- `terminal` and `render` must not require each other. A reference in either direction is a design
  mistake: extract the shared code into a leaf file at the top of `src/asekii-term/`.
- Leaf files require only external shards (`bytewire`, `termwidth`, `tty`), never a layer.
- Do not define anything under the `TTY` namespace, and do not reimplement termios, ioctl or PTY code —
  `tty` provides it. `Asekii::Terminal` swallows `TTY::Error` in its private restore helpers so paths
  never raise.
- Do not add width or segmentation code here — `termwidth` provides it; `Render::TextLayout` aliases
  `TermWidth::Wrap` and `TermWidth::CharClass`.

## Code standards

- Compiler-friendly, performance-focused and idiomatic Crystal.
- Data-driven design.
- No comments in code, except the first line of every file, which is a comment holding the file's path
  (for example `# src/asekii-term/render/compositor.cr`).
- The usage-facing API must be ergonomic.
- Prevent shotgun surgery: a change should touch as few files as possible.
- Never use `out` as an identifier.
- Do not add functionality that was not asked for.
- Deliver complete files: no stubs and no placeholders.
- Never change the `version` field in `shard.yml`.
- Keep `README.md` (usage and the public-facing API) and this file in sync with the code.
- Write in English.

The repository is watched by the zentry daemon: file changes are committed automatically to `dev`
after a short quiet period, releases happen through `zentry stop`, and `main` is only ever a release
target. Do not `git commit`, `git push`, `git reset --hard` or `git branch -D` by hand.
