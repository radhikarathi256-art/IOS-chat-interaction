# Motion spec — read before changing any animation

This project is not just a chat app. The point of it is that **iOS and Android
feel like the same product**, and almost all of that feeling lives in a handful
of animation values and a few structural rules.

Most of the rules below were arrived at by breaking them first. If a value looks
arbitrary, assume it is load-bearing until you have reproduced the bug it fixes.

---

## 1. The tokens

There is **one easing curve** across both platforms:

```
cubic-bezier(0, 0, 0.5, 1)
```

Fast off the mark, long settle. iOS writes it `.timingCurve(0, 0, 0.5, 1, ...)`,
Android writes it `CubicBezierEasing(0f, 0f, 0.5f, 1f)` (`Decelerate`).

Everything else is a duration:

| Token | iOS | Android | Used for |
|---|---|---|---|
| layout | 420ms | 460ms | A bubble's grow, and the conversation reflowing around it |
| enter | 280ms | 280ms | Small things that move only themselves — typing dots, scroll pill |
| placement | — | 460ms | Android only: neighbouring rows sliding to new positions |
| status ticks | 180ms | 180ms | Sent → delivered → read |

**Why layout differs (420 vs 460).** These are genuinely different jobs. On iOS
the conversation is one `VStack` that reflows as a single motion. On Android
every row animates independently via `animateItem`, which reads busier, so it
needs slightly longer to settle. Matching the numbers exactly made Android look
worse, not better. Treat 420/460 as "the same token, tuned per platform".

---

## 2. How a message bubble enters

**It grows out of its own tail corner.** The tail is the square corner — bottom
right for your own messages, bottom left for theirs. Both axes scale from 0 to 1
together, anchored at that corner, so the bubble unfolds diagonally out of the
point where it is attached to the conversation.

- iOS: `.scale(scale: 0, anchor: .topTrailing / .topLeading)`
  The list is inverted (`scaleEffect(y: -1)`), so `.top…` resolves as the visual
  **bottom**. This is confusing and correct — do not "fix" it to `.bottom…`.
- Android: `graphicsLayer { scaleX = p; scaleY = p; transformOrigin = TransformOrigin(isMine ? 1f : 0f, 1f) }`

The fade is deliberately much shorter than the grow — the bubble is fully opaque
about a quarter of the way in, and only the shape is still moving after that.
iOS hardcodes 110ms. Android derives it from the grow's own progress
(`alpha = p / 0.40`), which at 460ms lands at ~109ms. That is why they match;
if you change Android's layout duration the fade follows automatically.

### The trap that cost the most time

On Android the scale **must sit on the bubble itself**, not on `BubbleView`'s
`fillMaxWidth()` row. On the full-width row, `TransformOrigin(1f, 1f)` means the
corner of the *screen*, not the corner of the bubble — so the bubble appears to
fly in from the screen edge instead of growing out of its tail. It looks
"wrong" in a way that is hard to name, and the fix is not in the curve.

---

## 3. Typing indicator → message

The dots and the message that replaces them are two different rows, and the
handoff between them is the single most fragile moment in the app.

The dots enter and exit at scale **0.60**, anchored bottom-left, on the enter
token. But when a real message is arriving, a flag (`typingHandoff`) makes the
dots' exit **instant — zero duration**.

**Why zero.** If the dots animate out over any non-zero duration, then for those
frames the layout contains both the dots' height *and* the new bubble's height.
The list visibly shakes. This is not tunable; it is a consequence of both rows
being laid out at once. The only fix is for the dots to release their height in
a single frame.

The flag is set on the transport side: the sender broadcasts `msg` **before**
`typing off`, so the receiver knows the message is the reason the dots are
going away.

### Things that have been tried here and reverted

- **Starting the bubble at the dots' exact size** so it appears to morph out of
  the pill. Tried twice, reverted twice — it looked worse than growing from 0
  both times. Not obviously a bad idea; just not solved yet.
- **Growing width only** (holding `scaleY` at 1) to dodge an apparent
  "grows from the top" problem. That problem was really the wrong-transform-origin
  bug in §2. Once the origin was fixed, uniform scale was correct.

---

## 4. Rules that are not negotiable

1. **One curve.** If you need a new feel, change a duration, not the easing.
2. **No springs.** Both platforms use timed curves only. Android still contains
   `spring()` definitions behind a `FLAG_EASE` flag — they are dead code kept
   for comparison. Enabling them makes the two platforms diverge immediately.
3. **A row's placement animation and its own entrance must share a duration.**
   Otherwise the bubble grows at one speed while the conversation slides at
   another, and the two read as unrelated events.
4. **Never scroll and animate the same pixels at once.** Android deliberately
   does *not* scroll when a message arrives while you are already at the bottom;
   `reverseLayout` already pins you there. Adding a scroll produced a jump that
   looked like a physics bug.
5. **Status ticks must never change the bubble's size.** They live in a
   fixed-size slot and animate opacity and colour only. A width change there
   reflows the whole conversation.

---

## 5. How to actually test this

Do not judge motion by tapping send yourself — you cannot watch your own thumb
and the animation at the same time, and outgoing and incoming are different
code paths.

Drive the **other** side over the wire instead. A small Node script that joins
the Supabase channel as the opposite role and emits `typing` then `msg` a second
later will trigger a real incoming animation on demand, with no second device.
See the wire contract in the README for the payload shape.

To inspect a single frame, **slow everything down by the same factor** — every
duration in the table, not just the one you are studying. Slowing the bubble but
leaving the list at full speed produces a mismatch that looks like a real bug and
is not. That mistake has been made here and reported as a finding.

---

## 6. Known open gaps

- The dots → message handoff still reads as a cut rather than a morph (§3).
- Android caps bubble width at 70% of the screen; iOS has no cap.
- iOS keyboard open/close inherits Apple's curve and cannot easily be retimed;
  Android drives its own at 260ms. Android is smoother. Unresolved.
