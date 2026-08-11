import Foundation

/// The fakeable network seam for every Google service (M1; reused by the calendar sync engine in
/// M3 and by Drive/Gmail in later phases). Tests inject a canned transport so no unit test ever
/// touches the network (§7).
protocol GoogleHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport over an ephemeral `URLSession` (no shared cookie/cache state — tokens are
/// managed explicitly, never by the session).
struct URLSessionGoogleTransport: GoogleHTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}
