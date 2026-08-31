import Foundation
import SwiftUI
import Combine

// Realtime.swift — talks to Supabase Realtime over a plain WebSocket.

// Credentials live in Secrets.swift, which git ignores. SUPABASE_HOST and
// SUPABASE_KEY are declared there so this file can be published safely.
private let ROOM          = "demo"

@MainActor
final class ChatClient: ObservableObject {

    @Published var msgs: [Message] = []
    @Published var isTyping = false
    @Published var isRecording = false

    /// True only for the single update in which a message is replacing the
    /// typing indicator. The dots' exit has to be instant in that one case —
    /// a view being removed keeps its layout space until its exit finishes, so
    /// an animated exit means the dying dots (53pt) and the arriving bubble
    /// (60pt) both claim room for a moment, shoving the conversation up and
    /// then dragging it back down. Every other time the dots go away nothing is
    /// competing for that space, and an instant vanish is pure loss.
    @Published var typingHandoff = false
    @Published var joined = false
    @Published var connected = false

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var ref = 0
    private var retries = 0
    private var didTrack = false
    private var closedByUs = false
    private var topic: String { "realtime:chat:\(ROOM)" }

    // MARK: Connect

    func connect() {
        closedByUs = false
        didTrack = false
        heartbeat?.invalidate()
        task?.cancel()

        var c = URLComponents()
        c.scheme = "wss"
        c.host = SUPABASE_HOST
        c.path = "/realtime/v1/websocket"
        c.queryItems = [
            URLQueryItem(name: "apikey", value: SUPABASE_KEY),
            URLQueryItem(name: "vsn", value: "1.0.0"),
        ]
        guard let url = c.url else { return }

        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
        join()

        heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.sendRaw(topic: "phoenix", event: "heartbeat", payload: [:])
            }
        }
    }

    private func join() {
        sendRaw(topic: topic, event: "phx_join", payload: [
            "config": [
                "broadcast": ["self": false],
                // `enabled: true` is required to receive presence_state on join.
                // Without it we only get presence_diff, so an astrologer who was
                // already connected before us is never seen.
                "presence": ["key": "seeker", "enabled": true],
            ]
        ])
    }

    /// Passing `presence.key` in the join config does NOT put us in presenceState().
    /// Supabase only registers us after an explicit track frame — without this the
    /// astrologer console sits on "waiting for seeker" forever.
    private func trackPresence() {
        sendRaw(topic: topic, event: "presence", payload: [
            "type": "presence",
            "event": "track",
            "payload": ["role": "seeker"],
        ])
    }

    func disconnect() {
        closedByUs = true
        heartbeat?.invalidate()
        heartbeat = nil
        task?.cancel()
        connected = false
    }

    /// Called on every foreground. iOS tears the socket down while we're suspended
    /// and by the time the user returns the backoff in `scheduleReconnect` has
    /// usually saturated at its 30s cap, so the chat sat dead for up to half a
    /// minute. Deliberately unconditional: `connected` still reads a stale `true`
    /// after a suspend, because the failure callback never got a chance to run.
    /// `connect()` drops any existing socket first, so calling this when we happen
    /// to be healthy costs one quick rejoin.
    func reconnect() {
        retries = 0
        connect()
    }

    private func scheduleReconnect() {
        guard !closedByUs else { return }
        closedByUs = true          // stop this socket from queueing more retries
        heartbeat?.invalidate()
        connected = false
        retries += 1
        let delay = min(pow(2.0, Double(retries)), 30.0)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.connect()
        }
    }

    // MARK: Send

    func send(_ text: String, replyToId: String? = nil) {
        let msg = Message(id: UUID().uuidString, from: .seeker, text: text,
                          status: .sending, replyToId: replyToId)
        withAnimation(layoutSpring) {
            msgs.append(msg)
        }
        var body: [String: Any] = [
            "id": msg.id,
            "kind": "text",
            "from": "seeker",
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "text": text,
        ]
        if let replyToId { body["replyToId"] = replyToId }
        sendRaw(topic: topic, event: "broadcast", payload: [
            "type": "broadcast",
            "event": "msg",
            "payload": body,
        ]) { [weak self] in
            self?.advance(msg.id, to: .sent)
        }
        setTyping(false)
    }

    /// The only writer of `status`, and it only ever moves forward — a `read`
    /// can overtake its own `delivered`, and a tick going backwards is visible.
    ///
    /// Mutates in place and is deliberately NOT wrapped in `withAnimation`: the
    /// row keeps its identity (§15) and an ack must not animate any geometry
    /// (§14). `StatusTicks` owns the only transition, on opacity and colour.
    private func advance(_ id: String, to status: DeliveryStatus) {
        guard let i = msgs.firstIndex(where: { $0.id == id }),
              msgs[i].status < status else { return }
        msgs[i].status = status
    }

    /// Tells the sender their message landed. `delivered` on arrival, `read`
    /// once it is in the list — they land within a frame of each other.
    private func ack(_ event: String, id: String) {
        sendRaw(topic: topic, event: "broadcast", payload: [
            "type": "broadcast",
            "event": event,
            "payload": ["id": id],
        ])
    }

    private var typingSent = false

    func setTyping(_ on: Bool) {
        guard connected, typingSent != on else { return }
        typingSent = on
        sendRaw(topic: topic, event: "broadcast", payload: [
            "type": "broadcast",
            "event": "typing",
            "payload": ["on": on, "mode": "text"],
        ])
    }

    /// `onSent` fires once the frame is actually handed to an open socket —
    /// that is what turns a bubble from Sending into Sent. If the socket is
    /// down it never fires and the tick correctly stays faint.
    private func sendRaw(topic: String, event: String, payload: [String: Any],
                         onSent: (() -> Void)? = nil) {
        ref += 1
        let frame: [String: Any] = [
            "topic": topic,
            "event": event,
            "payload": payload,
            "ref": String(ref),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { error in
            if let error { print("ws send error:", error); return }
            guard let onSent else { return }
            Task { @MainActor in onSent() }
        }
    }

    // MARK: Receive

    /// Every callback checks it still belongs to the current socket. Without this,
    /// the `task?.cancel()` inside `connect()` delivers a failure for the socket we
    /// just discarded, which then queues its own reconnect — so one foreground
    /// could leave two live sockets racing to join the same topic.
    private func receiveLoop() {
        let socket = task
        socket?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, socket === self.task else { return }
                switch result {
                case .failure(let error):
                    print("ws error:", error)
                    self.scheduleReconnect()
                case .success(let message):
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootEvent = root["event"] as? String
        else { return }

        let outer = root["payload"] as? [String: Any] ?? [:]

        switch rootEvent {
        case "phx_reply":
            // Heartbeat replies come back on the "phoenix" topic — ignore those.
            guard root["topic"] as? String == topic,
                  outer["status"] as? String == "ok" else { return }
            retries = 0
            connected = true
            if !didTrack {
                didTrack = true
                trackPresence()
            }
            return

        case "presence_state", "presence_diff":
            let keys: [String] = rootEvent == "presence_state"
                ? Array(outer.keys)
                : Array((outer["joins"] as? [String: Any] ?? [:]).keys)
            if keys.contains("astrologer") { markJoined() }
            return

        case "phx_error", "phx_close":
            scheduleReconnect()
            return

        case "broadcast":
            break

        default:
            return
        }

        guard let event = outer["event"] as? String else { return }
        let body = outer["payload"] as? [String: Any] ?? [:]

        switch event {
        case "msg":
            markJoined()
            let text = body["text"] as? String
            let id = body["id"] as? String ?? UUID().uuidString
            let img = body["imageUrl"] as? String
            let kind = Kind(rawValue: body["kind"] as? String ?? "text") ?? .text
            let replyToId = body["replyToId"] as? String
            // All three writes go inside ONE transaction. `typingHandoff` used
            // to be set outside it, which meant the frame carried two
            // transactions at once — an unanimated one that dropped the typing
            // row and an animated one that inserted the bubble. Measured, the
            // list moved DOWN 9-12px for a frame and only then slid up: the
            // dots gave their space back before the bubble had claimed any. A
            // reversal of direction is exactly what reads as a jerk. One
            // transaction means one net height change and one direction.
            let handingOff = isTyping || isRecording
            withAnimation(layoutSpring) {
                typingHandoff = handingOff
                isTyping = false
                isRecording = false
                if !msgs.contains(where: { $0.id == id }) {
                    msgs.append(Message(id: id, kind: kind, from: .astrologer,
                                        text: text, imageURL: img,
                                        replyToId: replyToId))
                }
            }
            // Cleared only once the slide is over. On the next runloop turn it
            // would re-render mid-flight and hand the (already departing)
            // typing row an animated exit spec.
            if handingOff {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    self?.typingHandoff = false
                }
            }
            ack("delivered", id: id)
            ack("read", id: id)

        case "typing":
            markJoined()
            let on = body["on"] as? Bool ?? false
            let mode = body["mode"] as? String ?? "text"
            withAnimation(layoutSpring) {
                isTyping = on && mode == "text"
                isRecording = on && mode == "voice"
            }

        case "delivered":
            if let id = body["id"] as? String { advance(id, to: .delivered) }

        case "read":
            if let id = body["id"] as? String { advance(id, to: .read) }

        default:
            break
        }
    }

    private var openingDone = false
    private var pendingJoin = false

    private func markJoined() {
        guard !joined else { return }
        // Presence can land in ~300ms, well before the opening pills finish.
        // Hold the join notice back so it can't jump the welcome sequence.
        guard openingDone else { pendingJoin = true; return }
        withAnimation(layoutSpring) {
            joined = true
            msgs.append(Message(id: "joined",
                                from: .system,
                                text: "Astrologer has joined to guide you",
                                isAdmin: true))
        }
    }

    // MARK: Opening pill (local, before the console takes over)

    /// Only the first welcome line is scripted — everything after it comes from
    /// the real astrologer, so the chat never looks pre-canned.
    func runOpening() async {
        try? await Task.sleep(for: .seconds(0.5))
        withAnimation(layoutSpring) {
            msgs.append(Message(id: "pre-welcome", from: .system,
                                text: "Welcome to AstroChat!"))
        }
        openingDone = true
        if pendingJoin {
            pendingJoin = false
            markJoined()
        }
    }
}
