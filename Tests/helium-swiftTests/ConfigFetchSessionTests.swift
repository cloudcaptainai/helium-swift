import Network
import XCTest
@testable import Helium

final class ConfigFetchSessionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    func testConfigRequestsShareOneConnection() async throws {
        let server = try await LoopbackHTTPServer.start()
        defer { server.stop() }

        for _ in 0..<2 {
            _ = try? await fetchEndpoint(endpoint: server.url, params: ["apiKey": "test_api_key"])
        }

        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testCancelledConfigFetchNeverReachesTheNetwork() async throws {
        let server = try await LoopbackHTTPServer.start()
        defer { server.stop() }

        let cancelledFetch = await Task { () -> Result<(HeliumFetchedConfig?, JSON?), Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                return .success(try await fetchEndpoint(endpoint: server.url, params: ["apiKey": "test_api_key"]))
            } catch {
                return .failure(error)
            }
        }.value
        XCTAssertThrowsError(try cancelledFetch.get())

        _ = try? await fetchEndpoint(endpoint: server.url, params: ["apiKey": "test_api_key"])
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(server.connectionCount, 1)
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.helium.tests.loopbackHTTPServer")
    private let lock = NSLock()
    private var connections = 0
    private var requests = 0

    var connectionCount: Int { lock.withLock { connections } }
    var requestCount: Int { lock.withLock { requests } }
    var url: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/config" }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> LoopbackHTTPServer {
        let server = try LoopbackHTTPServer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { [weak server] state in
                switch state {
                case .ready:
                    server?.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    server?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            server.listener.newConnectionHandler = { [weak server] connection in
                server?.accept(connection)
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections += 1 }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            while let requestLength = Self.completeRequestLength(in: buffer) {
                buffer.removeFirst(requestLength)
                self.lock.withLock { self.requests += 1 }
                let body = "unavailable"
                let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: keep-alive\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private static func completeRequestLength(in buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let total = headerEnd.upperBound - buffer.startIndex + contentLength
        return buffer.count >= total ? total : nil
    }
}
