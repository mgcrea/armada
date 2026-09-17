# Mouse button combos

Two thumb buttons, one trigger. Back and Forward pressed together, and either one
held while the other is clicked.

## Why

A mouse binding today is one button and one modifier. The thumb's two buttons can
do more than that on their own: pressed together they are a third trigger, and held
one-while-clicking-the-other they are a rocker that repeats — hold Back, click
Forward three times, walk three sessions. That last shape is the one worth having,
because walking the fleet is what these bindings are for and a modifier-free way to
do it leaves the other hand alone.

Cadence already ships Back + Forward together, as `DictationMouseButton`, and its
tap is a port of Armada's. Staying close to it keeps one mechanism in two apps.

## What is added

Three triggers, offered next to the single buttons in the same menu:

| Trigger | Fires when |
| --- | --- |
| Back + Forward together | The second of the two goes down within 70 ms of the first |
| Hold Back, press Forward | Forward goes down after that window, with Back still held |
| Hold Forward, press Back | The reverse |

Each carries the modifier list every binding already has, `none` included.

Combos are built from Back (button 3) and Forward (button 4) only. They are the pair
a thumb can work at once; anything else on a mouse is out of reach of the same thumb,
so a general "any two buttons" trigger would spend a second picker and a two-press
Detect on a shape nobody presses.

## How it is stored

Negative button numbers in the existing field, which is what Cadence does:

- `-1` Back + Forward together (the same number Cadence writes)
- `-2` Hold Back, press Forward
- `-3` Hold Forward, press Back

A binding stays one modifier, one button, one action, so bindings written before
this decode unchanged and no migration runs. No mouse reports a negative button, so
a combo number can never match a real press.

The alternative — a trigger enum with associated values — reads better and costs a
hand-written `Codable` conformance, a migration for stored bindings, and the match
with Cadence. For a fixed set of three it does not pay for itself.

## How a press is handled

The rule that governs the design: **a press is held back only when a combo binding
could still claim it.** Everything else passes at once, so a Mac with no combo
bindings behaves exactly as it does today.

A press of Back or Forward is held when some combo binding starts with that button
and matches the modifiers being held. The tap keeps a copy of the event and starts a
70 ms timer. From there:

- **The other button goes down inside the window** → the together binding fires, if
  there is one for these modifiers.
- **The other button goes down after the window, first still held** → the matching
  hold-then-press binding fires.
- **The window expires and no hold-then-press binding starts with this button** →
  the press settles at once.
- **The first button is released before anything fired** → the press settles now.

Settling means one of two things: the button's own single binding fires (⌥ Back,
say), or the press is replayed to the system — the down, and the up if it has already
arrived — so the application gets its Back. A replayed event is stamped in
`eventSourceUserData` so this tap passes it through rather than holding it a second
time. Cadence uses the same marker mechanism.

While the first button stays down after a combo has fired, each further press of the
other button fires again. Releasing the first button ends the run and swallows both
releases, which the `swallowed` set already does for single bindings.

### What this costs

- A plain Back press, on a Mac with a *together* binding on Back, arrives 70 ms late.
- A plain Back press, on a Mac with a *hold Back, press Forward* binding, arrives
  when the button is released rather than when it goes down.
- Both costs are per-button and per-modifier: they apply only to presses that carry
  the combo's modifiers, so a ⌥ combo leaves unmodified Back alone entirely.

### Nothing may stay down

A held press that is never settled would leave an application with a button down and
no button up. Three things settle it: the release, the timer, and the next press of
that button. On top of those, the tap settles any held press when it stops, when it
is disabled by macOS, and when the bindings change. A press whose release macOS
hides (Secure Input) is settled by that button's next press, which is exactly when
the old one is known to be stale — the same bound the `swallowed` set already uses.

## Settings

The trigger menu gains the three combos below the single buttons. A row reads
"⌥ Hold Back, press Forward". Detect… still learns one button; it is there for
mice that number their buttons oddly, and a combo is defined in terms of Back and
Forward rather than raw numbers.

Captions under a row, for bindings with no modifier only:

| Binding | Caption |
| --- | --- |
| Back or Forward alone | today's: the button stops going Back or Forward in every app |
| Middle button alone | it stops opening links in a new tab |
| Together | Back and Forward reach apps 70 ms late |
| Hold-then-press | the held button goes Back (or Forward) when you let go of it |

The pane's footer gains a sentence: a combo holds the first press for a moment, and
says what that means for the button on its own.

## Code

- `MouseBinding.swift` — the three numbers, their labels, and which caption a
  binding earns. Pure types, no tap.
- `MouseBindingsStore` moves to `MouseBindingsStore.swift`. It calls `MouseTap`, and
  the split is what lets the types and the new logic build without AppKit for
  `make unit`.
- `MouseChord.swift`, new — the state machine above, written over a button number,
  modifier flags, a timestamp and the binding list. It returns `pass`, `swallow`,
  `hold`, `fire(binding)` or `settle`. No `CGEvent`, no timer, no singleton.
- `MouseTap.swift` — keeps the event copies, runs the timer, replays and posts. It
  asks `MouseChord` what to do and does it.

## Testing

`make unit` covers `MouseChord`, which is where every rule above lives:

- no combo bindings → a press passes, unchanged from today
- together fires inside the window; outside it, it does not
- hold-then-press fires after the window, and again on each further press
- a click shorter than the window settles on release
- a window that expires with no hold-then-press binding settles immediately
- a single ⌥ Back binding still fires when a combo binding also exists
- a held press left by a lost release is settled by that button's next press
- modifiers gate the hold: a combo bound to ⌥ never delays an unmodified press

Then a build. The real check is a mouse, which is the user's to do: Armada does not
post synthetic button presses to test itself.

## Not in scope

- Combos on any pair other than Back and Forward.
- Tap-then-tap sequences (click Back, then click Forward). The window would have to
  outlast a double-click, and every plain Back on the Mac would pay it.
- Anything about the middle button not being reported by the user's Logitech
  receiver: that is the mouse's on-board profile, not Armada.
