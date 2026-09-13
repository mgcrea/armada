# Armada icon

Candidate **6a** — "one ship on the family's water" — from
`../.idea/design/app-icon/Armada Icon.dc.html`, symbol `#a6a`. Two sails on the same water
cupertino and bastion stand on.

One mark, every rendering, one command:

```bash
make icon        # from the repo root
make icon-check  # fail if anything generated has drifted
```

| File                                             | Role                                                                                   |
| ------------------------------------------------ | -------------------------------------------------------------------------------------- |
| `armada-mark.svg`                                | **the source.** Two sails and two waves on a transparent sky, 1024×1024. Edit this.    |
| `colors.json`                                    | the palette and the plate gradient                                                     |
| `armada-menubar.svg`                             | **authored** — the menu bar glyph, idle. Edit this too.                                |
| `armada-menubar-active.svg`                      | **authored** — the same rig filled, drawn while a session is working.                  |
| `armada-menubar-active-halo.svg`                 | **authored** — the filled rig plus the halo, drawn while a session wants you.          |
| `armada-icon.svg`                                | _generated_ — plated vector for the README and docs                                    |
| `../apps/apple/Armada/Armada.icon`               | _generated_ — the Icon Composer bundle Xcode compiles                                  |
| `…/Assets.xcassets/MenuBarIcon*.imageset/*.svg`  | _generated_ — copies of the three glyphs above                                         |

Never hand-edit a generated file. The mark and the three menu bar glyphs are the only
geometry in the project, which is the whole point of generating the rest — and `make
icon-check` fails on a copy that has drifted, rather than letting a hand-edited glyph ship.

**There is no lockup.** Both siblings generate one for their websites; Armada has no site
yet, so the file that would be composed for it does not exist. When there is a site, this is
where it goes, and it should be composed from `armada-icon.svg` rather than drawn beside it —
cupertino's was hand-drawn alongside its mark and its hills had been wrong for two revisions
before anyone noticed.

## Why it borrows the family's water

Deliberately, and it is the one decision here that is not about Armada. These are three apps
by one author, and the family's mark is a warm vertical plate with a dark landscape running
off the bottom. Cupertino puts a sun over it, bastion a fort, Armada a boat. Both water
colours are copied to the digit from `../../bastion/design/colors.json` — `#B0532F` and
`#7A2F1C`, the same two hills — so the three sit beside each other in a Dock as siblings
rather than as near misses, which is worse than either matching or differing.

What is Armada's own is the subject and the plate: `#FFF6E8` sails at 92%, over a gradient a
shade lighter and pinker than bastion's.

## Why the sky is a flag and not artwork

The mark carries no background. `make icon` passes the sky as `--plate-gradient
'#FFD9A2,#F6A177' --plate-angle 90`, so appshot writes the `.icon` as **two layers** —
`mark.png` over an opaque `plate.png`. macOS 26 lights and parallaxes them independently; a
single flattened bitmap gets one specular sweep across the whole icon and reads flat.

`icon.json`'s `layers` array runs **front to back**, so the plate is the _last_ entry.
Backwards is silent: the bundle still compiles and installs, and renders as a bare plate with
no mark.

## Why the waves bleed off the edges

They are landscape, not a centred glyph — every wave path deliberately overruns the canvas on
three sides, so the mark goes in at `--mark-fraction 1.0` and maps 1:1. The usual 70–80%
glyph-to-plate band does not apply to a scene icon, and `appshot icon build` says so in its
own output: it reports the mark spanning 100% of the composed plate.

The overrun is why `make icon` clips the generated SVG afterwards. macOS masks the `.icon` to
its own squircle for free, but nothing masks an SVG on a web page — without the clip the
waves square off the plate's bottom two corners.

That clip step needs `perl -0777`, and the reason is specific to this mark: it carries its
**own** `<defs>` for the waterline, so a line-by-line substitution matches twice and writes a
duplicate `id="c"`. Bastion's mark has no defs and never hit this.

## The sails sit in the water, not on it

`armada-mark.svg` defines one `clipPath`, `sky`, whose lower edge is the back wave. Both
sails are drawn down to y800 — well below the waterline — and the clip cuts them at the
water. That is what puts the hull *in* the water rather than floating over it, and it is the
same arrangement cupertino's sun has, drawn before its hills and setting behind them.

## Palette

| Token         | Hex       | Role                                   |
| ------------- | --------- | -------------------------------------- |
| plate top     | `#FFD9A2` | icon background, top                   |
| plate bottom  | `#F6A177` | icon background, bottom                |
| sail          | `#FFF6E8` | the mark's ink, at 92% over the sky    |
| water mid     | `#B0532F` | back wave, at 90% over the sky         |
| water fore    | `#7A2F1C` | front wave                             |

The plate gradient is always vertical, top light → bottom warm. Don't rotate it, don't add a
third stop. `gradients` uses the **CSS** angle convention (180 = top to bottom); `make icon`
passes appshot's (degrees clockwise, y-down, 90 = top to bottom). The two must not meet.

`colors.json` is deliberately short. Both siblings carry `ink`, `ground`, `paper` and
`accent` for their websites, and `ok` / `warn` / `danger` for their UI. Armada has no website,
and its app takes status colour from the system's semantic palette — the only two literal
colours in the whole app are `ContextBar`'s two series, which live in Swift beside the view
that draws them. Adding tokens here that nothing reads would be inventing a design system
rather than recording one.

## The menu bar glyphs

**Three files, not two** — one more than either sibling, because Armada has one more thing to
say. Bastion's glyph answers "is a server running"; Armada's answers that *and* "is a session
waiting for you", which is the question you want answered from across the room.

| file                              | state                          | drawn as                        |
| --------------------------------- | ------------------------------ | ------------------------------- |
| `armada-menubar.svg`              | nothing working                | outlined, 1.8 stroke            |
| `armada-menubar-active.svg`       | a session is working           | filled, same silhouette         |
| `armada-menubar-active-halo.svg`  | a session wants you            | filled, plus two offset arcs    |

`MenuBarLabel` in `ArmadaApp.swift` picks between them; which sessions light the halo is the
user's choice, on the ladder in `MenuBarHalo.swift`.

Coordinates are cupertino's 36-unit grid at 18pt, so 2 units = 1pt and the menu bar glyphs in
this family are comparable without conversion. The water line is **bastion's, unchanged and
on purpose**: these apps sit inches apart in one menu bar, and a shared horizon is what makes
them read as one family rather than three unrelated drawings.

The rig is byte-identical across all three files. They are swapped in place, so any drift
would read as the icon twitching rather than as a state changing.

### The halo

Bastion's idea — a light shape standing off the mark at a constant distance, rather than a
ring drawn around it. Nothing in it is drawn by hand: each arc is a sail's leech offset 3.6
units along its own normal, and the numbers come from sweeps and renders rather than from
taste.

Four things worth knowing before touching it, each of which cost a rejected draft:

- **It is two arcs, not one.** A single arc over the whole rig fits beautifully and is wrong:
  the convex hull bridges the notch between the two mastheads, and a filled notch stops
  reading as two sails and reads as a tent.
- **It does not reach above the rig.** The arcs are cut from the top, so this state is the
  boat gaining a light stroke along its flanks rather than the boat growing.
- **It can never be drawn around the _outlined_ rig.** An offset runs parallel to what it
  offsets at every point, so on an outline it comes out as nested strokes — and it fuses
  besides, the 1.8 stroke spending 0.9 of the 2.8 gap. A lit halo always draws the filled rig.
- **The gap is 2.8 units and the stroke 1.6**, which are bastion's gap and cupertino's halo
  weight exactly. Matched weights read as tramlines; one light shape around one solid one
  reads as a form inside another.

**The full derivation lives in the comment at the top of
[`armada-menubar-active-halo.svg`](armada-menubar-active-halo.svg)** — every rejected
alternative with the measurement that rejected it, the trim fractions, the fitted start
points, and why the feet terminate on the sails' own base line. It is not repeated here,
because a measurement kept in two files is a measurement that will disagree with itself.

### Verify by counting, not by looking

Counting 8-connected components of the rendered alpha at a threshold of 32:

| state  | shapes                | 16pt | 18pt | 20pt |
| ------ | --------------------- | ---- | ---- | ---- |
| idle   | rig with its water    | 1    | 1    | 1    |
| active | rig with its water    | 1    | 1    | 1    |
| halo   | the above, two arcs   | 3    | 3    | 3    |

Measured at 2×, alpha thresholded at 32. **The rig and the water are one component, not
two** — the sails' feet end at y27 and the water's stroke reaches y27.4 at the centre, so the
two touch and the antialiased render welds them. That is the arrangement, not a defect: every
shape in the glyph terminates on one line, which is what it shares with both siblings. It
also means the halo's three is the only count with any slack in it, so it is the one to
re-measure.

At 1× the gap does not resolve and a component count says the glyph is one shape. Both
siblings do the same thing at that size. Acceptable degradation rather than a bug to chase —
retina is the design target, and 1× still changes visibly, which is what a state needs to do.

Re-measure with a component count after any edit. By eye at 2× you cannot see the failure.

### Template images

Pure black plus alpha, so AppKit tints them for light menu bars, dark ones and the
highlighted state instead of shipping six renderings. `Image(_:)` resolves by name **without**
consulting `template-rendering-intent`, so `MenuBarLabel` also says
`.renderingMode(.template)`; without it the glyph ships black-on-black in a dark menu bar.

Armada is the quietest active state in the family on purpose — 19.53% ink against bastion's
27.46 and cupertino's 28.61. A sail is a thin shape, and a boat that grows a shell stops
being a boat.
