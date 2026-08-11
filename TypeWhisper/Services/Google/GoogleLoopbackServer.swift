import Foundation
import Network

/// Minimal loopback HTTP listener that catches Google's OAuth redirect (D-G2). Binds an ephemeral
/// port on `127.0.0.1` (Desktop-app clients accept any loopback port, so no registration is
/// needed), hands the first callback URL to `onCallback`, and answers the browser with a tiny
/// localized "you can close this window" page.
///
/// Concurrency: queue-confined `@unchecked Sendable` — all listener/connection state is touched
/// only on `queue`, and the single exit point hops to the main actor for `onCallback`. This is the
/// proven loopback-OAuth shape (`OpenAILoopbackOAuthServer` precedent, per M1); `@MainActor`
/// internals are not viable because Network framework callbacks arrive on their own queue.
/// App-side reimplementation — deliberately does not import the OpenAI plugin (D-G1).
final class GoogleLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.meetingwhisper.google.oauth-loopback")
    private var listener: NWListener?
    /// Set once the callback has been delivered so stray follow-up requests (browser refresh,
    /// favicon probes) never fire `onCallback` twice.
    private var delivered = false

    /// Receives the full redirect URL (query string included) exactly once. Set this **before**
    /// `start()`; `GoogleAuthService` resumes its pending continuation here.
    var onCallback: @MainActor (URL) -> Void = { _ in }

    /// Starts listening on an ephemeral loopback port and returns the assigned port number, from
    /// which the caller builds the `redirect_uri`. Blocks briefly (on a semaphore, off the listener
    /// queue) until the listener reports ready so the port is known synchronously.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        // nonisolated(unsafe): written only from the listener's state handler before `ready` is
        // signaled, read only after the semaphore wait — sequenced, never concurrent.
        nonisolated(unsafe) var startupError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw GoogleAuthError.timedOut
        }
        if let startupError {
            listener.cancel()
            throw startupError
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw GoogleAuthError.exchangeFailed("loopback listener has no port")
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

    /// Serves the callback request. Only a GET carrying a query string counts as the OAuth
    /// redirect — anything else (favicon, health probes) gets the page without firing `onCallback`.
    private func respond(toRequestLine line: String, on connection: NWConnection) {
        let callbackURL = Self.callbackURL(fromRequestLine: line)
        send(Self.doneHTML, status: "200 OK", on: connection)

        guard let callbackURL, !delivered else { return }
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
