import Foundation
import Network

/// The seam `GoogleAuthService` drives its loopback listener through, so flow-state-machine tests
/// can inject a fake, capture the redirect port, and invoke `onCallback` directly — no listener
/// binds and no browser opens under test (§7).
protocol GoogleLoopbackServing: AnyObject {
    var onCallback: @MainActor (URL) -> Void { get set }
    /// Binds the listener and returns its port. `async` (PR #7 review finding 10): the readiness
    /// wait used to block the calling thread — the main actor, in practice — for up to 5 s, so a
    /// machine where the listener cannot bind beach-balled the whole UI before failing. Called
    /// from `GoogleAuthService` (a `@MainActor` type), so it is main-actor isolated like
    /// `onCallback` — awaiting it suspends the flow without ever blocking the actor.
    @MainActor
    func start() async throws -> UInt16
    func stop()
}

/// Minimal loopback HTTP listener that catches Google's OAuth redirect (D-G2). Binds an ephemeral
/// port on `127.0.0.1` (Desktop-app clients accept any loopback port, so no registration is
/// needed), hands the callback URL to `onCallback`, and answers the browser with a tiny
/// localized "you can close this window" page. Only a request echoing `expectedState` consumes
/// the one-shot callback slot, so a stray local request can never use it up before the real
/// redirect lands (SR review; precedent: `OpenAILoopbackOAuthServer`'s state binding).
///
/// Concurrency: queue-confined `@unchecked Sendable` — all listener/connection state is touched
/// only on `queue`, and the single exit point hops to the main actor for `onCallback`. This is the
/// proven loopback-OAuth shape (`OpenAILoopbackOAuthServer` precedent, per M1); `@MainActor`
/// internals are not viable because Network framework callbacks arrive on their own queue.
/// App-side reimplementation — deliberately does not import the OpenAI plugin (D-G1).
final class GoogleLoopbackServer: GoogleLoopbackServing, @unchecked Sendable {
    /// How long the listener gets to reach `.ready` before `start()` reports
    /// `.loopbackUnavailable`. The wait is fully asynchronous, so this never blocks a thread.
    nonisolated static let readyTimeout: TimeInterval = 5

    /// One-shot resume guard for the readiness continuation: `.ready`, `.failed`, and the timeout
    /// race each other, and a `CheckedContinuation` may be resumed exactly once.
    private final class ReadyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        func attach(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func finish(_ error: Error?) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private let queue = DispatchQueue(label: "com.meetingwhisper.google.oauth-loopback")
    /// The `state` value a request must echo before it is treated as the OAuth redirect.
    private let expectedState: String
    private var listener: NWListener?
    /// Set once the callback has been delivered so follow-up requests (browser refresh) never
    /// fire `onCallback` twice.
    private var delivered = false

    /// Receives the full redirect URL (query string included) exactly once. Set this **before**
    /// `start()`; `GoogleAuthService` resumes its pending continuation here.
    var onCallback: @MainActor (URL) -> Void = { _ in }

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    /// Starts listening on an ephemeral loopback port and returns the assigned port number, from
    /// which the caller builds the `redirect_uri`.
    ///
    /// The readiness wait is asynchronous (PR #7 review finding 10): it used to block the calling
    /// thread — the main actor, in practice — on a semaphore for up to 5 s, so a machine where the
    /// listener cannot bind (socket-filter extension, local security software, exhausted loopback)
    /// froze the entire UI and then reported `.timedOut`, which reads as "the browser redirect
    /// never arrived" even though no browser was ever opened. Bind failures now surface as
    /// `.loopbackUnavailable`, a distinct taxonomy entry with its own message.
    @MainActor
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw GoogleAuthError.loopbackUnavailable(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        let gate = ReadyGate()
        var timeoutTask: Task<Void, Never>?
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.attach(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.finish(nil)
                    case .failed(let error):
                        gate.finish(GoogleAuthError.loopbackUnavailable(error.localizedDescription))
                    case .cancelled:
                        gate.finish(GoogleAuthError.loopbackUnavailable("listener cancelled"))
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.readyTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    gate.finish(GoogleAuthError.loopbackUnavailable("listener did not become ready"))
                }
            }
        } catch {
            timeoutTask?.cancel()
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw error
        }
        timeoutTask?.cancel()
        // Startup is decided; drop the handler so later transitions cannot resume anything (a
        // runtime failure after this surfaces as a redirect that never arrives, which the flow's
        // 5-minute timeout handles).
        listener.stateUpdateHandler = nil
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw GoogleAuthError.loopbackUnavailable("loopback listener has no port")
        }
        self.queue.async { self.listener = listener }
        return port
    }

    /// Stops listening. Safe to call repeatedly (timeout, cancel, and normal completion all funnel
    /// here).
    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: - Connection handling (queue-confined)

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            if let requestLine = Self.requestLine(from: accumulated) {
                self.respond(toRequestLine: requestLine, on: connection)
                return
            }

            if isComplete || error != nil {
                self.send(Self.doneHTML, status: "400 Bad Request", on: connection)
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    /// Serves the callback request. Only a GET whose query echoes `expectedState` counts as the
    /// OAuth redirect — anything else (favicon, health probes, stray local requests) gets the
    /// page without firing `onCallback` and without consuming the one-shot slot (SR review).
    /// Google echoes `state` on error redirects too, so denial callbacks still qualify.
    private func respond(toRequestLine line: String, on connection: NWConnection) {
        let callbackURL = Self.callbackURL(fromRequestLine: line)
        send(Self.doneHTML, status: "200 OK", on: connection)

        guard let callbackURL, Self.stateValue(of: callbackURL) == expectedState, !delivered else {
            return
        }
        delivered = true
        let callback = onCallback
        Task { @MainActor in
            callback(callbackURL)
        }
    }

    private func send(_ html: String, status: String, on connection: NWConnection) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Request parsing (pure)

    /// The first CRLF-terminated line of the HTTP request, if fully received.
    private static func requestLine(from data: Data) -> String? {
        guard let range = data.range(of: Data("\r\n".utf8)) else { return nil }
        return String(data: data.subdata(in: data.startIndex..<range.lowerBound), encoding: .utf8)
    }

    /// The `state` query parameter of a callback URL, if present.
    private static func stateValue(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "state" })?
            .value
    }

    /// `"GET /?code=…&state=… HTTP/1.1"` → a parseable URL, or nil when the request carries no
    /// query (not the OAuth redirect).
    private static func callbackURL(fromRequestLine line: String) -> URL? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        guard target.contains("?"),
              let url = URL(string: "http://127.0.0.1\(target)"),
              let query = url.query, !query.isEmpty else { return nil }
        return url
    }

    /// The page the browser lands on after the redirect. Localized like every user-facing string
    /// (EN + DE).
    private static var doneHTML: String {
        let message = String(localized: "google.oauth.browserDone")
        return """
        <!DOCTYPE html>
        <html>
          <head><meta charset="utf-8"><title>MeetingWhisper</title></head>
          <body style="font-family: -apple-system, sans-serif; display: flex; align-items: center; justify-content: center; height: 90vh;">
            <p style="font-size: 1.1em; max-width: 32em; text-align: center;">\(message)</p>
          </body>
        </html>
        """
    }
}
