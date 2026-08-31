# AstroChat — iOS (seeker)

SwiftUI client for a realtime astrology chat demo. This app is the **seeker**
side. It talks to an Android app (the astrologer) and a web console over
Supabase Realtime broadcast; all three interoperate.

## Setup

Credentials are not in this repo. Before the app will connect:

```sh
cp AstroChat/Secrets.example.swift AstroChat/Secrets.swift
```

Then open `AstroChat/Secrets.swift` and uncomment/fill the two values:

```swift
let SUPABASE_HOST = "your-project-ref.supabase.co"
let SUPABASE_KEY  = "your-publishable-anon-key"
```

`Secrets.swift` is gitignored, so it never gets committed. The Xcode project
uses a synchronized folder group, so the file is picked up automatically — no
project settings to change.

Get the values either from whoever runs the shared Supabase project, or by
creating your own free project at supabase.com and using its publishable
(anon) key. Only Realtime is used — no database tables are required.

## Running

Open `AstroChat.xcodeproj` and run. Works on simulator and device (signing is
automatic).

## Wire contract

- Channel topic: `realtime:chat:<ROOM>` — `ROOM` is `demo` by default
- Presence key: `seeker` for this app, `astrologer` for the Android app/console
- Broadcast events: `msg`, `typing`, `read`
- `msg` payload: `{ id, kind, from, ts, text?, imageUrl?, replyToId? }`

Both platforms must agree on all of the above to interoperate.

## Notes on motion

The entrance animations are deliberately tuned and documented inline in
`ContentView.swift`. The shared easing is `cubic-bezier(0, 0, 0.5, 1)` on both
platforms. Read the comments before changing any duration — several of the
values there are fixes for framework behaviour, not taste.
