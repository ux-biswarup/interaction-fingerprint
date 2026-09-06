import Foundation
import Network
import Observation

/// Streams a recording to the researcher's Mac as it happens, and catches up whatever was
/// recorded while the Mac was out of reach.
///
/// The Mac runs `Analysis/dashboard/server.py`, which advertises itself on the local network
/// as a Bonjour service of type `_ifp._tcp`. The phone finds it without an address being
/// typed, opens a WebSocket, and forwards every event the recorder appends, batched four
/// times a second. When a link comes up the phone also lists the sessions and calibrations
/// it holds; the desk answers with the ones it lacks and the phone uploads them, so a
/// session recorded on the train arrives the moment the phone is back on the home network.
///
/// Nothing leaves the local network. The phone keeps writing its own files regardless, so
/// the link is a convenience, never the record. Protocol and privacy notes:
/// `docs/product/13-DESK-LINK.md`.
@Observable @MainActor
public final class DeskLink {
    public static let serviceType = "_ifp._tcp"
    static let flushInterval: Duration = .milliseconds(250)
    static let outboxLimit = 4000

    public enum State: Equatable, Sendable {
        case off
        case searching
        case connecting(String)
        case connected(String)

        public var label: String {
            switch self {
            case .off: "off"
            case .searching: "looking for the desk"
            case .connecting(let name): "connecting to \(name)"
            case .connected(let name): "connected to \(name)"
            }
        }
    }

    public private(set) var state: State = .off
    public private(set) var sentEvents = 0
    private var sessionEvents = 0
    public private(set) var uploads = 0
    public var queuedMessages: Int { outbox.count }

    /// Off by default only in tests; the instrument screen offers a toggle.
    public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }
    static let enabledKey = "interactionFingerprint.deskLink.enabled"

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var deskName: String?
    private var outbox: [Data] = []
    private var pendingEvents: [FingerprintEvent] = []
    private var flusher: Task<Void, Never>?
    private var sending = false
    /// One retry chain at a time. Each failure used to start its own, and two of them
    /// reaching an empty `connection` in the same tick opened two sockets to the desk.
    private var retryScheduled = false

    public init(enabled: Bool? = nil) {
        let stored = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
        isEnabled = enabled ?? stored ?? true
    }

    // MARK: Lifecycle

    public func start() {
        guard isEnabled, browser == nil else { return }
        state = .searching
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated { self.found(results) }
        }
        browser.stateUpdateHandler = { browserState in
            MainActor.assumeIsolated {
                if case .failed = browserState { self.restartBrowsingLater() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        flusher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.flushInterval)
                self?.flushPendingEvents()
            }
        }
    }

    public func stop() {
        flusher?.cancel()
        flusher = nil
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        deskName = nil
        state = .off
    }

    private func restartBrowsingLater() {
        browser?.cancel()
        browser = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.start()
        }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard connection == nil, isEnabled else { return }
        // Prefer a result that is not tied to one interface, so the address the phone
        // resolves is the one that survives a Wi-Fi hop.
        guard let result = results.first(where: { $0.interfaces.isEmpty }) ?? results.first else { return }
        let name: String
        if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName } else { name = "desk" }
        connect(to: result.endpoint, named: name)
    }

    private func connect(to endpoint: NWEndpoint, named name: String) {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 64 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let connection = NWConnection(to: endpoint, using: parameters)
        deskName = name
        state = .connecting(name)
        connection.stateUpdateHandler = { connectionState in
            MainActor.assumeIsolated { self.connectionChanged(connectionState) }
        }
        connection.start(queue: .main)
        self.connection = connection
        receive(on: connection)
    }

    private func connectionChanged(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            state = .connected(deskName ?? "desk")
            sending = false
            enqueue(DeskMessage.envelope(type: "hello", payload: try? Self.encoder.encode(Hello())))
            announceHoldings()
            flushOutbox()
        case .waiting:
            // Waiting for a path that may never come back; a fresh attempt is cheaper.
            connection?.cancel()
        case .failed, .cancelled:
            connection = nil
            sending = false
            if isEnabled {
                state = .searching
                retryLater()
            }
        default:
            break
        }
    }

    private func retryLater() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.retryScheduled = false
            guard self.isEnabled, self.connection == nil else { return }
            if let results = self.browser?.browseResults, !results.isEmpty {
                self.found(results)
            } else {
                self.retryLater()
            }
        }
    }

    /// Called when the app returns to the foreground. A socket that survived suspension is
    /// not to be trusted; drop it and let the retry path rebuild it.
    public func resume() {
        guard isEnabled else { return }
        if browser == nil { start(); return }
        if let connection {
            connection.cancel()
        } else {
            retryLater()
        }
    }

    // MARK: What the recorder tells the link

    public func sessionStarted(_ session: SessionRecord) {
        sessionEvents = 0
        enqueue(DeskMessage.envelope(type: "session_start", payload: try? Self.encoder.encode(session)))
    }

    public func record(_ event: FingerprintEvent) {
        pendingEvents.append(event)
        sessionEvents += 1
    }

    /// Sent after the phone has written its own files. Carries the event count so a desk
    /// whose streamed copy is short, because the link dropped batches, asks for the file.
    public func sessionEnded(_ session: SessionRecord) {
        flushPendingEvents()
        enqueue(DeskMessage.envelope(
            type: "session_end", payload: try? Self.encoder.encode(session), extra: "\"eventCount\":\(sessionEvents)"
        ))
    }

    public func calibrationSaved(_ document: SessionExporter.CalibrationDocument) {
        enqueue(DeskMessage.envelope(type: "calibration", payload: try? Self.encoder.encode(document)))
    }

    /// The areas of interest currently laid out, so the desk can draw the screen the gaze is
    /// being attributed against.
    public func areasChanged(_ areas: [AreaOfInterest], viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let payload = areas.map { area in
            AreaPayload(
                screen: area.screen.rawValue, target: area.target.rawValue, productID: area.productID,
                x: area.frame.minX / viewport.width, y: area.frame.minY / viewport.height,
                width: area.frame.width / viewport.width, height: area.frame.height / viewport.height
            )
        }
        enqueue(DeskMessage.envelope(type: "areas", payload: try? Self.encoder.encode(payload)))
    }

    // MARK: Catch-up

    private func announceHoldings() {
        let files = SessionExporter.existing().map(\.lastPathComponent)
        let holdings = Holdings(
            sessions: files.filter { $0.hasPrefix("session_") }.map { String($0.dropFirst("session_".count).dropLast(".json".count)) },
            calibrations: files.filter { $0.hasPrefix("calibration_") }
        )
        enqueue(DeskMessage.envelope(type: "have", payload: try? Self.encoder.encode(holdings)))
    }

    private func handle(incoming data: Data) {
        guard let message = try? JSONDecoder().decode(Incoming.self, from: data) else { return }
        guard message.type == "missing", let folder = try? SessionExporter.directory() else { return }
        for id in message.sessions ?? [] {
            let url = folder.appendingPathComponent("session_\(id).json")
            if let body = try? Data(contentsOf: url) {
                enqueue(DeskMessage.upload(kind: "session", id: id, body: body))
                uploads += 1
            }
        }
        for name in message.calibrations ?? [] {
            let url = folder.appendingPathComponent(name)
            if let body = try? Data(contentsOf: url) {
                enqueue(DeskMessage.upload(kind: "calibration", id: name, body: body))
                uploads += 1
            }
        }
        flushOutbox()
    }

    // MARK: Transport

    private func flushPendingEvents() {
        guard !pendingEvents.isEmpty else { return }
        let batch = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        enqueue(DeskMessage.envelope(type: "events", payload: try? Self.encoder.encode(batch)))
        sentEvents += batch.count
    }

    private func enqueue(_ message: Data) {
        // Bounded: the phone's own files are the record, the link is best effort.
        if outbox.count >= Self.outboxLimit { outbox.removeFirst() }
        outbox.append(message)
        flushOutbox()
    }

    private func flushOutbox() {
        guard let connection, connection.state == .ready, !sending, let next = outbox.first else { return }
        sending = true
        let context = NWConnection.ContentContext(
            identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]
        )
        connection.send(content: next, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            MainActor.assumeIsolated {
                self.sending = false
                if error == nil, !self.outbox.isEmpty { self.outbox.removeFirst() }
                self.flushOutbox()
            }
        })
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { content, _, _, error in
            MainActor.assumeIsolated {
                if let content { self.handle(incoming: content) }
                if error != nil {
                    // A failed handshake or a dropped peer surfaces here first.
                    connection.cancel()
                } else if connection.state != .cancelled {
                    self.receive(on: connection)
                }
            }
        }
    }

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    // MARK: Wire types

    struct Hello: Encodable {
        let device = "iPhone"
        let protocolVersion = 1
    }

    struct Holdings: Encodable {
        let sessions: [String]
        let calibrations: [String]
    }

    struct AreaPayload: Encodable {
        let screen: String
        let target: String
        let productID: String?
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Incoming: Decodable {
        let type: String
        let sessions: [String]?
        let calibrations: [String]?
    }
}

/// The wire envelope: `{"type": "...", "payload": ...}` with the payload's own JSON inserted
/// verbatim, so a five megabyte session document is not decoded and re-encoded on the phone.
public enum DeskMessage {
    nonisolated public static func envelope(type: String, payload: Data?, extra: String? = nil) -> Data {
        var data = Data("{\"type\":\"\(type)\",".utf8)
        if let extra { data.append(Data("\(extra),".utf8)) }
        data.append(Data("\"payload\":".utf8))
        data.append(payload ?? Data("null".utf8))
        data.append(Data("}".utf8))
        return data
    }

    nonisolated public static func upload(kind: String, id: String, body: Data) -> Data {
        var data = Data("{\"type\":\"upload\",\"kind\":\"\(kind)\",\"id\":\"\(id)\",\"payload\":".utf8)
        data.append(body)
        data.append(Data("}".utf8))
        return data
    }
}
