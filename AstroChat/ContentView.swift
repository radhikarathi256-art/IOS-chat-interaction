import SwiftUI

// ============================================================================
// MOTION TEST FLAGS — the only two lines to edit.
// ============================================================================

/// `true` = decelerate timing curves (what WhatsApp/iMessage actually use).
/// `false` = springs. Swaps both tokens at once; no call site changes.
///
/// Springs were the wrong call. A spring settles by ringing, so every row in a
/// reflow overshoots and comes back, and because each row has a different
/// distance to travel they ring out of phase with each other. That is the
/// "everything jerks" — a dozen bubbles all oscillating slightly differently.
/// A decelerate curve has no overshoot at all: every row starts and stops on
/// the same frame and the block moves as one piece.
let FLAG_EASE = true

// MARK: - Model

enum Sender: String, Codable { case seeker, astrologer, system }
enum Kind: String, Codable { case text, voice, image }

/// Ordered so a status can only ever move forward. Acks race — a `read` can
/// overtake its own `delivered` — and a tick sliding backwards is a visible
/// regression. `ChatClient.advance(_:to:)` is the only writer and it enforces it.
enum DeliveryStatus: Int, Comparable {
    case sending, sent, delivered, read
    static func < (a: DeliveryStatus, b: DeliveryStatus) -> Bool { a.rawValue < b.rawValue }
}

struct Message: Identifiable, Equatable {
    let id: String
    var kind: Kind = .text
    var from: Sender
    var text: String?
    var imageURL: String?
    var ts: Date = Date()
    /// Only meaningful on our own bubbles; incoming and system rows never draw ticks.
    var status: DeliveryStatus = .sent
    var isAdmin: Bool = false
    var replyToId: String?
}

// MARK: - Palette

extension Color {
    static let inkDark    = Color(red: 0.11, green: 0.16, blue: 0.22)
    static let sentBg     = Color(red: 0.99, green: 0.88, blue: 0.84)
    static let chatBg     = Color(red: 0.94, green: 0.96, blue: 1.00)
    static let muted      = Color(red: 0.60, green: 0.64, blue: 0.70)
    static let subtle     = Color(red: 0.40, green: 0.45, blue: 0.50)
    static let pillBg     = Color(red: 0.95, green: 0.96, blue: 0.97)
    static let pillStroke = Color(red: 0.82, green: 0.84, blue: 0.87)
    static let pillText   = Color(red: 0.20, green: 0.25, blue: 0.33)
    static let liveGreen  = Color(red: 0.01, green: 0.60, blue: 0.33)
    static let sendOrange = Color(red: 0.94, green: 0.41, blue: 0.22)
    static let endRed     = Color(red: 0.85, green: 0.18, blue: 0.13)
}

// MARK: - Motion tokens

/// Anything whose motion moves OTHER content: list reflow, scroll, keyboard,
/// the composer/panel hand-off, the session-end transition.
/// cubic-bezier(0.2, 0, 0, 1) — leaves fast, lands dead flat, never overshoots.
///
/// 0.40s, not 0.26s. 0.26 is about as fast as a curve can be while still being
/// legible, and at that speed a reflow reads as a flinch however clean it is —
/// there is no time to see anything travel, only to notice that it moved. The
/// eye reads a move as deliberate from roughly 0.35s. iMessage sits at 0.35-0.40
/// and that is the whole difference between "it jumped" and "it slid".
let layoutSpring: Animation = FLAG_EASE
    // (0, 0, 0.2, 1) — Material's decelerate, and identical to Android's
    // LinearOutSlowInEasing so the two platforms finally share one curve.
    //
    // This was (0.2, 0, 0, 1), which is NOT a decelerate curve: its first
    // control point sits at (0.2, 0), horizontal at t=0, so the initial
    // velocity is zero and the curve eases IN before it eases out. Measured
    // per-frame displacement of the list was -2, -9, -18, -19, -15, -11 —
    // accelerating for the first three frames. That 50ms of creep before the
    // content commits is what read as "the slide is not smooth". A decelerate
    // curve must leave at maximum velocity and decay monotonically.
    //
    // x2 is 0.5, not Material's 0.2. Both are decelerate curves — no ease-in,
    // monotonic decay — but they leave at very different speeds. Near t=0,
    // (0,0,x2,1) has slope 1/x2, so 0.2 leaves at 5x the average speed of the
    // move and 0.5 leaves at 2x. Measured on a typing indicator appearing (a
    // ~127px shove, the longest travel in the chat): 0.2 put 17% of the whole
    // distance into the very first frame — an 18-33px step. The eye reads a
    // step that large as a jump no matter how clean the remaining 24 frames
    // are. At 0.5 the first frame is ~7%, and the curve still has all its
    // deceleration left to spend.
    ? .timingCurve(0, 0, 0.5, 1, duration: 0.42)
    : .spring(response: 0.42, dampingFraction: 1.0)

/// Small elements that move nothing but themselves. NOTE: as of this build the
/// message bubble no longer uses this — a bubble overshooting at 0.80 while
/// every neighbour settled dead-flat at 1.0 in the same frame is what read as
/// jitter. The bubble now inherits layoutSpring so its scale and the reflow
/// around it are one motion. Still used by the typing dots and the pill.
let enterSpring: Animation = FLAG_EASE
    ? .timingCurve(0, 0, 0.5, 1, duration: 0.28)
    : .spring(response: 0.36, dampingFraction: 0.80)

/// How long a pause counts as "stopped typing" (§3). Same number on Android.
let typingIdle = Duration.milliseconds(1_200)

// MARK: - Scroll position probe

extension View {
    /// Reports whether an INVERTED scroll view is parked at the conversation's
    /// bottom. Because the list is flipped, that is simply contentOffset 0; the
    /// 24pt of slack stops the pill flickering during rubber-banding.
    ///
    /// The project still deploys to iOS 17, where `onScrollGeometryChange` does
    /// not exist. Both test phones are on 26, so the older path just reports
    /// "at bottom" and the pill stays hidden rather than misbehaving.
    @ViewBuilder
    func trackAtBottom(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, y in
                action(y < 24)
            }
        } else {
            self
        }
    }
}

// MARK: - Bubble shape (tail corner stays square)

struct BubbleShape: Shape {
    let isMine: Bool

    func path(in rect: CGRect) -> Path {
        // The square corner is the TAIL, and it sits at the bottom on both
        // sides — bottom-right for me, bottom-left for them — so the two
        // mirror each other and each bubble grows up and inward out of its
        // own tail. The received bubble used to carry its square corner at
        // the TOP-left, which meant it grew away from its tail while mine
        // grew out of it.
        let r: CGFloat = 16
        let tl: CGFloat = r
        let tr: CGFloat = r
        let br: CGFloat = isMine ? 0 : r
        let bl: CGFloat = isMine ? r : 0

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                 radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                 radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                 radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                 radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Quoted strip (inside a reply bubble)

struct QuotedStrip: View {
    let quoted: Message

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.sendOrange)
                .frame(width: 2, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(quoted.from == .seeker ? "You" : "Astro Hemali")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sendOrange)
                Text(quoted.text ?? "[\(quoted.kind.rawValue)]")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtle)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.inkDark.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Delivery ticks

/// §13/§14. Both glyphs are ALWAYS laid out; a status change only moves opacity
/// and colour. The frame is a fixed width in every state because a bubble is as
/// wide as its widest row — if this grew when the second tick appeared, an ack
/// arriving would resize the bubble and shove the whole conversation. Nothing
/// here may ever affect geometry.
struct StatusTicks: View {
    let status: DeliveryStatus

    var body: some View {
        ZStack(alignment: .leading) {
            tick.opacity(status == .sending ? 0.35 : 1)
            tick.offset(x: 4).opacity(status >= .delivered ? 1 : 0)
        }
        .foregroundStyle(status == .read ? Color.blue : Color.muted)
        .frame(width: 14, height: 9, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: status)
    }

    private var tick: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
    }
}

// MARK: - Bubble

struct BubbleView: View {
    let msg: Message
    let quoted: Message?
    /// Width reserved for the opposite side of the row, so the bubble can never
    /// exceed 70% (§11). A proportion, not the old fixed 100pt — that measured
    /// 69% on an SE and 77% on a Max.
    let gutter: CGFloat
    var isMine: Bool { msg.from == .seeker }

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: gutter) }

            VStack(alignment: .trailing, spacing: 2) {
                if let quoted { QuotedStrip(quoted: quoted) }

                if let urlStr = msg.imageURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            Image(systemName: "photo")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.muted)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 210, height: 210)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if let text = msg.text {
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.inkDark)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 3) {
                    Text(msg.ts, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.subtle)
                    if isMine { StatusTicks(status: msg.status) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isMine ? Color.sentBg : Color.white)
            .clipShape(BubbleShape(isMine: isMine))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)

            if !isMine { Spacer(minLength: gutter) }
        }
    }
}

// MARK: - Swipe right to reply

struct SwipeToReply<Content: View>: View {
    let onReply: () -> Void
    @ViewBuilder var content: Content

    private let maxDrag: CGFloat = 72
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.subtle)
                .frame(width: 28, height: 28)
                .background(Color.pillBg, in: Circle())
                .opacity(min(offset / maxDrag, 1))

            content
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { v in
                            offset = min(max(v.translation.width, 0), maxDrag)
                        }
                        .onEnded { _ in
                            let fired = offset > maxDrag * 0.6
                            withAnimation(enterSpring) { offset = 0 }
                            if fired {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                onReply()
                            }
                        }
                )
        }
    }
}

// MARK: - Typing indicator

/// Driven by `TimelineView(.animation)`, i.e. straight off the display link,
/// NOT by `withAnimation`. Two reasons, and both were visible before:
///
/// 1. A `.repeatForever` animation is still an animation, so it lived in
///    whatever transaction was running when the view appeared and got restarted
///    or retimed every time the list reflowed around it. The dots stuttered
///    exactly when a message landed. A timeline is immune — the reflow cannot
///    reach it.
/// 2. The old dot was a hard cut: `opacity(lift < -1 ? 1 : 0.35)`. A boolean
///    inside an animated scope is the definition of choppy — it snapped between
///    two values, and on the frames it snapped SwiftUI also tried to animate the
///    step with the 1.2s repeating curve.
///
/// Now every dot rides one cosine, so scale and opacity are continuous through
/// the wrap and no dot is ever parked. Scale, not offset, so the bubble's own
/// height is constant and the row above it never moves.
struct TypingBubble: View {
    private let period = 1.15
    private let stagger = 0.18

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let w = wave(t, i)
                    Circle()
                        .fill(Color.muted)
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.72 + 0.38 * w)
                        .opacity(0.32 + 0.68 * w)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white)
            .clipShape(BubbleShape(isMine: false))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        }
    }

    /// 0 → 1 → 0 over one period. `(1 - cos)/2` meets itself at both ends with
    /// matching slope, so the loop has no seam to see.
    private func wave(_ t: TimeInterval, _ i: Int) -> Double {
        var p = (t / period - Double(i) * stagger).truncatingRemainder(dividingBy: 1)
        if p < 0 { p += 1 }
        return (1 - cos(p * 2 * .pi)) / 2
    }
}

// MARK: - Recording indicator

struct RecordingBubble: View {
    @State private var dim = false

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 15))
            .foregroundStyle(Color.muted)
            .opacity(dim ? 0.15 : 1)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white)
            .clipShape(BubbleShape(isMine: false))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - System pill

struct SystemPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Color.pillText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.pillBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.pillStroke, lineWidth: 1)
            )
    }
}

// MARK: - Scroll to bottom

struct ScrollToBottom: View {
    let unread: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkDark)
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.sendOrange)
                }
            }
            .padding(.horizontal, unread > 0 ? 12 : 9)
            .padding(.vertical, 9)
            .background(Color.white, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reply HUD

struct ReplyHud: View {
    let replyTo: Message
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.sendOrange)
                .frame(width: 2, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sendOrange)
                Text(replyTo.text ?? "[\(replyTo.kind.rawValue)]")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.subtle)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.subtle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.pillBg)
    }
}

// MARK: - Avatar

struct Avatar: View {
    let size: CGFloat

    var body: some View {
        Image("Hemali")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .background(Color.sentBg, in: Circle())
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var chat = ChatClient()
    @State private var draft = ""
    @State private var replyTo: Message?
    @State private var atBottom = true
    @State private var unread = 0
    /// Set by `send()` only when we are scrolled away from the bottom (§9).
    @State private var pendingScrollToBottom = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    @FocusState private var focused: Bool

    private var msgs: [Message] { chat.msgs }
    private var showsIndicator: Bool { chat.isTyping || chat.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomStack }
        }
        .background(Color.white)
        .task {
            chat.connect()
            await chat.runOpening()
        }
        .onChange(of: draft) {
            chat.setTyping(!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        // iOS kills the socket while we're suspended, and the exponential backoff
        // alone left the chat dead for up to 30s after reopening.
        //
        // Only reconnect after a REAL background trip. Firing on every `.active`
        // also caught the inactive→active churn during launch, which cancelled the
        // socket `.task` had just opened while its join was still in flight — the
        // device logged `NSURLErrorCancelled` and never joined the room.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: wasBackgrounded = true
            case .active where wasBackgrounded:
                wasBackgrounded = false
                chat.reconnect()
            default: break
            }
        }
    }

    // MARK: List

    private var messageList: some View {
        // Measures the list so the bubble cap can be a proportion of it (§11).
        // GeometryReader rather than a preference key: every row needs the width
        // on the same layout pass, and a preference would arrive one pass late —
        // the first bubble would size, then visibly correct (§18).
        GeometryReader { geo in
            // The list pads 16pt each side, so a row is narrower than the list.
            let gutter = max((geo.size.width - 32) * 0.30, 48)

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    // INVERTED LIST. The ScrollView is flipped vertically and
                    // every row flips itself back, so content y=0 renders at the
                    // visual BOTTOM and the newest message is first in the stack.
                    //
                    // This is the fix for "the whole chat jerks". The old build
                    // appended to the end and held the view still with
                    // `.defaultScrollAnchor(.bottom)`. But an appended row leaves
                    // every older row's frame unchanged in content coordinates —
                    // the only thing that moved was the scroll offset, and the
                    // anchor corrects that in ONE unanimated frame. There was
                    // nothing for `withAnimation` to animate, so the older
                    // bubbles teleported up by a row height every time.
                    //
                    // Inverted, an insertion goes in at index 0 and genuinely
                    // pushes every older row down the content axis. That is a
                    // real layout change, so the enclosing layoutSpring slides
                    // them. The scroll offset stays at 0 and is never corrected.
                    // Android has always worked this way (`reverseLayout`).
                    // VStack, NOT LazyVStack. This is the line that was costing
                    // us both animations at once. A LazyVStack only materialises
                    // the rows near the viewport, so a row's identity comes and
                    // goes with scrolling — SwiftUI therefore will not run an
                    // insertion `.transition` on it (the bubble just pops in at
                    // full size) and it does not animate its children's
                    // placement when a sibling changes height (every older row
                    // teleports). Neither symptom is fixable from the transition
                    // side; the container has to be an eager VStack. A chat
                    // session is tens of rows, so there is nothing to gain from
                    // laziness here anyway.
                    ScrollView {
                        VStack(spacing: 12) {
                            // Visually the bottom edge of the conversation, and
                            // the scroll target for the pill. Nothing else — see
                            // the `onScrollGeometryChange` below for why this no
                            // longer reports whether we are at the bottom.
                            Color.clear
                                .frame(height: 1)
                                .id("bottomEdge")

                            if showsIndicator {
                                HStack(spacing: 0) {
                                    if chat.isRecording {
                                        RecordingBubble()
                                    } else {
                                        TypingBubble()
                                    }
                                    Spacer(minLength: 50)
                                }
                                .id("typing")
                                .scaleEffect(x: 1, y: -1)
                                // Same rule as the message rows: `.transition`
                                // outermost, or it is dropped entirely.
                                .transition(.asymmetric(
                                    // `.top` here reads as the visual BOTTOM.
                                    // `.transition` is applied AFTER the row's
                                    // `.scaleEffect(y: -1)`, so it wraps the
                                    // already-flipped view and its anchor
                                    // resolves in the ScrollView's flipped
                                    // space. Writing `.bottom` grows the bubble
                                    // downward out of its top edge.
                                    insertion: .scale(scale: 0.60, anchor: .topLeading)
                                        .combined(with: .opacity.animation(.easeOut(duration: 0.17))),
                                    // THE MORPH — and the fix for the shake.
                                    //
                                    // A view being removed with a transition KEEPS
                                    // ITS SPACE IN THE LAYOUT until that transition
                                    // finishes. `.transition` only animates how a
                                    // row is drawn, never how much room it takes.
                                    // So the old removal meant: on frame 1 the new
                                    // bubble claims its ~60pt while the dying
                                    // typing row is still holding its ~53pt, and
                                    // the conversation slides up by a whole bubble.
                                    // Then the removal completes, 53pt is handed
                                    // back, and the conversation slides back DOWN.
                                    // Two opposite slides overlapping on the same
                                    // pixels. That is the shake, and it fired on
                                    // every incoming message because the dots are
                                    // always up before one arrives.
                                    //
                                    // `.identity` releases the dots' space on the
                                    // very same frame the message claims its own,
                                    // so the two nearly cancel — the list makes ONE
                                    // unhurried move of just the height difference,
                                    // which is the "rest get time to move up". And
                                    // because the bubble grows from 0.75 out of the
                                    // exact corner the dots occupied, the eye joins
                                    // them up as one object: the dots become the
                                    // message.
                                    //
                                    // But that only applies when a message is
                                    // actually taking the dots' place. When the
                                    // astrologer simply stops typing, nothing is
                                    // competing for the space and an instant
                                    // vanish is a one-frame pop against a 420ms
                                    // slide — a hard cut next to a smooth move,
                                    // which is exactly what reads as a glitch.
                                    // So shrink back into the same corner then.
                                    removal: chat.typingHandoff
                                        ? .identity
                                        : .scale(scale: 0.60, anchor: .topLeading)
                                            .combined(with: .opacity)
                                ))
                            }

                            ForEach(msgs.reversed()) { m in
                                row(for: m, gutter: gutter)
                                    // No `.animation(enterSpring)` here. The bubble
                                    // inherits the enclosing transaction — the same
                                    // layoutSpring every neighbouring row reflows on.
                                    // Previously the bubble overshot at damping 0.80
                                    // while the rows around it settled dead-flat at
                                    // 1.0 in the same frame; one element ringing
                                    // against a rigid background reads as jitter.
                                    // 0.75 out of the tail corner, on layoutSpring —
                                    // the same curve the neighbours reflow on, so
                                    // the growth and the slide are one motion
                                    // rather than two that argue with each other.
                                    // 0.60, not 0.75. At 0.75 the bubble is
                                    // already three-quarters drawn on frame one,
                                    // so there is barely any growth to see and it
                                    // reads as a pop. 0.60 out of the tail corner
                                    // is a visible bottom-up grow, and it runs on
                                    // exactly the curve the neighbours reflow on,
                                    // so the growth and the slide are one motion.
                                    // ORDER IS LOAD-BEARING. `.transition` must be
                                    // the outermost modifier: SwiftUI resolves the
                                    // transition on the outermost view of the
                                    // inserted subtree, so anything wrapping it
                                    // (a `.scaleEffect`, an `.id`) makes the
                                    // insertion fall back to `.identity` and the
                                    // bubble simply pops at full size while the
                                    // reflow around it still animates. That split
                                    // is the shake.
                                    .id(m.id)
                                    .scaleEffect(x: 1, y: -1)
                                    .transition(
                                        // Grows from the bubble's tail corner —
                                        // the square corner in BubbleShape — up
                                        // and inward. `.top` == visual bottom
                                        // because the anchor resolves in the
                                        // inverted ScrollView's flipped space.
                                        // Starts at 0, not 0.60. At 0.60 the bubble
                                        // is already two-thirds grown on its first
                                        // frame and only the last third is animated,
                                        // so there is almost nothing to see and it
                                        // reads as a pop in the corner rather than a
                                        // grow out of the tail. Android grows its
                                        // outgoing bubble from 0 out of the matching
                                        // corner, and this is the difference that
                                        // made this side feel abrupt beside it.
                                        .scale(scale: 0,
                                               anchor: m.from == .seeker ? .topTrailing : .topLeading)
                                        // Opacity finishes early — fading across
                                        // the whole 420ms leaves the bubble
                                        // half-transparent while its neighbours
                                        // are still sliding, and two things
                                        // being vague at once reads as mush.
                                        //
                                        // But it finishes early ON THE SAME
                                        // CURVE as the scale, not on an ease-out
                                        // of its own. Android derives alpha from
                                        // the scale's own progress
                                        // (`alpha = p / 0.40`), so its bubble has
                                        // exactly one clock and cannot drift out
                                        // of step with itself. This was a second,
                                        // independent animation on the same
                                        // element — the pattern this file already
                                        // records as reading like a hitch.
                                        //
                                        // 0.11s is where Android's fade actually
                                        // completes, computed rather than
                                        // guessed: alpha hits 1 at p = 0.40, and
                                        // on cubic-bezier(0, 0, 0.5, 1) the curve
                                        // reaches 0.40 at t ≈ 0.238 of its
                                        // duration — 0.238 x 480ms ≈ 114ms.
                                        .combined(with: .opacity.animation(
                                            .timingCurve(0, 0, 0.5, 1, duration: 0.11)
                                        ))
                                    )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .scaleEffect(x: 1, y: -1)
                    .scrollDismissesKeyboard(.interactively)
                    .background(Color.chatBg)
                    .simultaneousGesture(TapGesture().onEnded { focused = false })
                    // §5. Ask the scroll view where it is, rather than asking a
                    // sentinel row whether it is on screen.
                    //
                    // The sentinel used `.onAppear`/`.onDisappear`, which is only
                    // a visibility signal inside a LazyVStack — the container
                    // creates and destroys rows as they pass the viewport. This
                    // list is now an eager VStack (it has to be, or insertion
                    // transitions never run), and an eager stack builds every row
                    // once and keeps it forever. So `onDisappear` never fired,
                    // `atBottom` was stuck true for the life of the screen, and
                    // the pill below could not render. That is the missing
                    // scroll-to-bottom button, not a layout problem.
                    //
                    // The list is inverted, so contentOffset 0 IS the visual
                    // bottom. 24pt of slack keeps the pill from flickering on
                    // during rubber-banding.
                    .trackAtBottom { bottom in
                        guard bottom != atBottom else { return }
                        // Animate the write itself rather than declaring
                        // `.animation(enterSpring, value: atBottom)` on the
                        // ZStack below. `.animation(_:value:)` is not scoped to
                        // the thing that changed — when its value flips it
                        // becomes the transaction for EVERY animatable change in
                        // its subtree on that frame, and its subtree was the
                        // whole ScrollView. Opening the keyboard shrinks the
                        // list, which shifts contentOffset, which flips
                        // `atBottom` on the same frame — so the keyboard's own
                        // resize got re-timed onto a 280ms spring and the
                        // conversation stopped tracking the keys. Only the pill
                        // was ever meant to animate here.
                        withAnimation(enterSpring) { atBottom = bottom }
                        if bottom { unread = 0 }
                    }
                    .onChange(of: msgs.count) { old, new in
                        let mine = msgs.last?.from == .seeker
                        if mine || atBottom {
                            unread = 0
                        } else {
                            unread += max(new - old, 0)
                        }
                    }
                    // §9. Android already did this; iOS lost it when the blanket
                    // scroll-on-every-message was removed. Only fires when we are
                    // NOT pinned to the bottom, so it can never race the arrival
                    // animation of a message that was already going to be visible.
                    // `anchor: .top` is the visual bottom — the list is inverted.
                    .onChange(of: pendingScrollToBottom) { _, want in
                        guard want else { return }
                        withAnimation(layoutSpring) { proxy.scrollTo("bottomEdge", anchor: .top) }
                        pendingScrollToBottom = false
                    }

                    if !atBottom {
                        ScrollToBottom(unread: unread) {
                            withAnimation(layoutSpring) {
                                proxy.scrollTo("bottomEdge", anchor: .top)
                            }
                            unread = 0
                        }
                        .padding(16)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                // Fills the reader, but takes its height from the layout system
                // instead of reading it back out of `geo`. A GeometryReader read
                // is a frame behind, so while the keyboard was moving the list
                // was being told last frame's height every frame.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }


    @ViewBuilder
    private func row(for m: Message, gutter: CGFloat) -> some View {
        if m.isAdmin || m.from == .system {
            SystemPill(text: m.text ?? "")
        } else {
            SwipeToReply(onReply: {
                withAnimation(layoutSpring) { replyTo = m }
                focused = true
            }) {
                BubbleView(msg: m, quoted: quoted(for: m), gutter: gutter)
            }
        }
    }

    private func quoted(for m: Message) -> Message? {
        guard let id = m.replyToId else { return nil }
        return msgs.first { $0.id == id }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.inkDark)

            Avatar(size: 45)

            VStack(alignment: .leading, spacing: 1) {
                Text("Astro Hemali")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.inkDark)

                HStack(spacing: 4) {
                    if chat.connected {
                        Circle().fill(Color.liveGreen).frame(width: 7, height: 7)
                        Text("Free Chat")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.liveGreen)
                    } else {
                        Text("Connecting…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.subtle)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Color.white)
        .animation(layoutSpring, value: chat.connected)
    }

    // MARK: Bottom stack (the safe-area inset)

    private var bottomStack: some View {
        VStack(spacing: 0) {
            if let replyTo {
                ReplyHud(replyTo: replyTo) { withAnimation(layoutSpring) { self.replyTo = nil } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composer
        }
        .background(Color.white)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.subtle)

            HStack(spacing: 6) {
                TextField("Type a message...", text: $draft, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                Image(systemName: "camera")
                    .foregroundStyle(Color.subtle)
                    .opacity(draft.isEmpty ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.pillBg)
            .clipShape(Capsule())

            Button(action: send) {
                Image(systemName: draft.isEmpty ? "mic.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(draft.isEmpty ? Color.subtle : Color.sendOrange)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    // MARK: Actions

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // ONE transaction, for exactly the reason the receive path is one
        // transaction. Sending changes the layout in three places at once:
        // clearing `draft` collapses a multi-line composer, clearing `replyTo`
        // closes the reply HUD, and the append grows the list. Committed
        // separately, the unanimated writes land on the current frame while the
        // animated one is still sitting at its start value — so the
        // conversation takes an instant step and only then begins to slide,
        // which is the same one-frame lurch the incoming path used to have.
        // Read the reply id out first; `replyTo` is nil by the time send runs.
        let reply = replyTo?.id
        withAnimation(layoutSpring) {
            draft = ""
            replyTo = nil
            chat.send(t, replyToId: reply)
        }
        // §9. When already pinned to the bottom the list follows on its own;
        // asking for a scroll as well would be a second animation on the same
        // pixels as the bubble's arrival, which is the old jank.
        if !atBottom { pendingScrollToBottom = true }
    }
}

#Preview {
    ContentView()
}
