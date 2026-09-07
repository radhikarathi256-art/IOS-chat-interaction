# AstroChat — developer guide

Realtime chat demo. Two native clients and a web console, all talking to each
other over Supabase Realtime broadcast.

| Client | Role | Stack | Repo |
|---|---|---|---|
| iOS | seeker (customer) | SwiftUI | `IOS-chat-interaction` |
| Android | astrologer | Jetpack Compose | `Androidchat-interaction` |
| Web console | astrologer | single HTML file | not published |

All three interoperate — a message sent from any one appears in the other two.

The hard part of this project is **feel**: message entrance, the typing
indicator, delivery states and keyboard transitions behaving identically on both
platforms. The networking is small by comparison. Most of the non-obvious code
is there for a specific reason, and this document records those reasons.

---

## 1. Getting it running

### Credentials

Nothing is committed. Both apps read credentials from a gitignored local file.
Without them the app builds and launches but never connects — the header sits on
"Connecting…".

**iOS**

```sh
cp AstroChat/Secrets.example.swift AstroChat/Secrets.swift
```

Fill in the two values. The Xcode project uses a synchronized folder group, so
the file is picked up with no project changes.

**Android** — add to `local.properties` in the project root:

```properties
SUPABASE_HOST=...
SUPABASE_KEY=...
```

`app/build.gradle.kts` exposes these as `BuildConfig.SUPABASE_HOST` and
`BuildConfig.SUPABASE_KEY`.

Use the publishable (anon) key. Only Realtime is used — no tables, no migrations,
nothing to provision. A free Supabase project is enough.

### Build

**iOS** — open `AstroChat.xcodeproj` and run. Signing is automatic; command-line
device builds need `-allowProvisioningUpdates`.

**Android**

```sh
./gradlew installDebug
```

`minSdk` 26. Use Android Studio's bundled JDK if your system Java is a different
major version.

---

## 2. Wire contract

Both clients must agree on all of this or they silently fail to see each other.

- Transport: Supabase Realtime over a raw WebSocket, hand-rolled Phoenix protocol
- Topic: `realtime:chat:<ROOM>`, `ROOM` defaults to `demo`
- Presence key: `seeker` for iOS, `astrologer` for Android and the web console
- Events: `msg`, `typing`, `delivered`, `read`

`msg` payload:

```json
{ "id": "...", "kind": "text", "from": "seeker",
  "ts": 0, "text": "...", "imageUrl": null, "replyToId": null }
```

Broadcast frames arrive **nested** — the useful payload is at `payload.payload`,
not `payload`. Unwrap twice.

**Ordering matters.** A client broadcasts `msg` *before* `typing: false`. The
receiving side relies on that order to know the message is replacing the typing
indicator rather than arriving on its own. Don't reorder them.

---

## 3. Connection reliability

This was a real bug with three layers. Don't undo any of them.

**Reconnect must be unconditional.** The old guard was
`if (connected) return`. After the OS suspends the app the failure callback never
fires, so `connected` stays a stale `true` and the reconnect is silently skipped.
`reconnect()` now does `retries = 0; connect()` every time.

**Every socket callback needs an identity guard.** `connect()` cancels the old
socket, and the *old* listener's failure callback would then queue a second
reconnect — two sockets racing to join the same topic.

```kotlin
if (webSocket !== ws) return          // Android, on every callback
```
```swift
guard let self, socket === self.task else { return }   // iOS
```

**Reconnect on foreground.** Android uses a `LifecycleEventObserver` on
`ON_START`. iOS watches `scenePhase`.

**iOS trap:** firing on *every* `scenePhase == .active` catches the launch
inactive→active churn and cancels the socket the join task just opened, giving
`-999 cancelled` and a client that never joins. It is gated behind a
`wasBackgrounded` flag so it only fires after a real background trip. Keep it.

---

## 4. Delivery states

`DeliveryStatus` is `sending → sent → delivered → read`, ordered/comparable on
both platforms.

`advance(id, status)` is **monotonic** — it never moves a message backwards.
Acks can arrive out of order; without this a late `delivered` would undo a `read`.

Read rule is deliberately simple: grey ✓✓ on arrival, blue immediately after. No
visibility or viewport tracking.

**The ticks live in a fixed-size slot.** Adding a second tick would otherwise
widen the bubble, and bubble width must never change because of state. The slot
animates opacity and colour only, never layout.

---

## 5. Layout rules

**Bubbles hug their content, capped at 70% of screen width on both platforms.**

Android:

```kotlin
val maxBubble = (LocalConfiguration.current.screenWidthDp * 0.70f).dp
Modifier.widthIn(max = maxBubble)
```

iOS uses a gutter instead:

```swift
let gutter = max((geo.size.width - 32) * 0.30, 48)
// ... Spacer(minLength: gutter) on the bubble's outer side
```

**Why the two differ:** SwiftUI's `.frame(maxWidth:)` is greedy — it stretches
as well as caps, so bubbles stop hugging their content. A `Spacer(minLength:)`
constrains without stretching. Compose's `widthIn(max =)` is a constraint only
and doesn't have this problem. Don't "simplify" the iOS side to `maxWidth`.

The header shows a green dot and **"Free Chat"**, or "Connecting…" when offline.
There is no session timer and no session-end state — both were removed.

---

## 6. Motion

The governing idea is that the chat is one continuous surface with a single
source of truth for final position. **No pixel should ever be moved by two
competing animations.** Most rules below follow from that.

### Shared curve

```
cubic-bezier(0, 0, 0.5, 1)
```

The `0.5` matters. At `0.2` the first frame carries ~17% of the total distance
and the eye reads it as a jump however clean the rest is.

### Android tokens

`MainActivity.kt` — three tokens, one curve. Don't add a fourth.

```kotlin
private val Decelerate = CubicBezierEasing(0f, 0f, 0.5f, 1f)

LayoutSpring    = tween(460, easing = Decelerate)   // Float
PlacementSpring = tween(460, easing = Decelerate)   // IntOffset
EnterSpring     = tween(280, easing = Decelerate)   // Float
```

- `LayoutSpring` — the arriving bubble's own grow
- `PlacementSpring` — older messages sliding up to make room
- `EnterSpring` — things that move nothing but themselves (typing dots,
  scroll-to-bottom pill)

The first two are the same number **on purpose**. The bubble growing and the
conversation pushing up are one event; on two different specs they finished
~40ms apart and it read as a hitch.

`FLAG_EASE = true` makes all four `spring()` definitions dead code. **Nothing in
this screen uses a spring.** If motion looks springy it is not a spring — look at
duration against travel distance.

### Android bubble entrance

```kotlin
val anim = remember { Animatable(0f) }
LaunchedEffect(Unit) { anim.animateTo(1f, LayoutSpring) }
val p = anim.value

Modifier.graphicsLayer {
    scaleX = p
    scaleY = p
    alpha = (p / 0.40f).coerceIn(0f, 1f)
    transformOrigin = TransformOrigin(if (isMine) 1f else 0f, 1f)
}
```

Three rules, each one a bug already hit:

1. **`Animatable`, not `animateFloatAsState` off a boolean.** The boolean pattern
   costs two frames before anything draws. `Animatable` is already at its start
   value when frame one composes.
2. **Alpha derives from the scale's own progress**, so there is one clock. It
   completes at `p = 0.40` ≈ 110ms, matching iOS's 110ms fade. Change the
   duration and the fade silently drifts away from iOS.
3. **The modifier goes on the bubble, not on `BubbleView`'s `fillMaxWidth` row.**
   On the row, `TransformOrigin(1f, 1f)` resolves to the corner of the *screen*,
   so the bubble flies in from the screen edge instead of growing from its tail.

Origin is the bubble's tail corner — bottom-right sent, bottom-left received,
matching the squared corner in `bubbleShape()`.

### Android list placement

```kotlin
Modifier.animateItem(fadeInSpec = null, placementSpec = PlacementSpring, fadeOutSpec = null)
```

Without it a new row claims full height on frame one and every older message
teleports upward before the bubble starts growing.

### Android typing indicator

```kotlin
enter = scaleIn(EnterSpring, 0.60f, TransformOrigin(0f, 1f)) + fadeIn(EnterSpring)

exit = if (chat.typingHandoff) {
    shrinkVertically(tween(0), Alignment.Bottom) + fadeOut(tween(0))
} else { /* normal scaleOut + fadeOut + shrinkVertically */ }
```

**The `tween(0)` is not laziness.** When a message replaces the dots they must
release their height in one frame. Any non-zero exit puts two rows in the layout
at once and the list visibly shakes. Do not "fix" it.

### Android scrolling

`reverseLayout = true` already pins index 0 to the bottom, so no scroll is needed
when a message arrives — that would be a third animation on the same pixels. The
only remaining scroll is sending while scrolled up.

### iOS

`ContentView.swift`. Same curve, 420ms for layout.

- Insertion: `.scale(scale: 0, anchor:)` — `.topTrailing` sent, `.topLeading` received
- Typing: `.scale(scale: 0.60, anchor: .topLeading)`
- Outgoing opacity: `.timingCurve(0, 0, 0.5, 1, duration: 0.11)`
- Typing removal during a handoff is `.identity` — the equivalent of Android's
  `tween(0)`, for the same reason

The list is inverted with `.scaleEffect(x: 1, y: -1)`, so **anchors are
vertically flipped**: `.topLeading` in code is visual *bottom*-leading. This
trips everyone up once. The anchors above are correct as written.

### Why the platforms use different numbers

iOS reflows the whole conversation as one `VStack`, so a single animation moves
everything. Android animates each row independently via `animateItem`, so the
same duration reads busier. Hence 460ms against iOS's 420ms — not copied
verbatim, tuned by eye on device.

---

## 7. Testing

- **Physical devices, not simulator or emulator.** Frame pacing differs enough to
  make motion judgements worthless.
- **Sent and received are different code paths.** Verify receiving by driving the
  other client over the wire, not by tapping send on the same device. A change
  can fix sending and leave receiving broken — this has happened.
- **Verifying delivery without a screenshot:** `devicectl` has no screenshot
  command. Instead watch the wire for the `read` receipt echoing the same message
  id — only the seeker app emits that, so it proves the message landed.
- Screen recordings beat adjectives. "Weird" or "not smooth" costs a build each
  and rarely converges. Capture the moment and compare frames.

---

## 8. Known gotchas

**Stuck on "Connecting…" (Android)** — usually the Wi-Fi is pushing an HTTP proxy
the device can't reach:

```sh
adb shell dumpsys connectivity | grep -i proxy
```

Ping still succeeds in that state because ICMP bypasses proxies, so ping proves
nothing.

**Same symptom (iOS)** — Settings → Wi-Fi → (i) → Configure Proxy → Off. Fast
triage: open Safari. If Safari fails too, it's the network, not the app. This has
been the cause more than once.

**Android emulator** — the emulator binary ships with the SDK but no system image
is installed, and creating one means accepting Google's licence in Android
Studio's Device Manager. Until then Android needs a physical device.

**iOS simulator** — boot with `simctl bootstatus <udid> -b` before screenshots,
or captures fail with "Timeout waiting for screen surfaces".

**macOS tooling** — `timeout` doesn't exist (use background + `sleep` + `kill`);
`devicectl --console` returns empty when backgrounded; `log stream --device-name`
needs admin; automating the Simulator needs Accessibility permission.

---

## 9. Open work

- **Typing indicator doesn't truly morph into the arriving bubble.** Today the
  dots are cut and the bubble grows from zero in the same frame. Starting the
  bubble at the dots' pill footprint (59×31dp) and growing from the shared
  bottom-left corner has been **tried twice and reverted both times** — it looked
  worse. Needs a different approach, not a retry.
- **Keyboard transition.** Android drives its own at 260ms on the shared curve.
  iOS inherits Apple's system curve and has no timing of its own, so content and
  composer don't move in lockstep. The system curve is not straightforwardly
  retimable — timebox it.
- **Stale comment.** The block above `LayoutSpring` in `MainActivity.kt` still
  says "Now 420". The real value is 460. Trust the code.
