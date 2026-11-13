import Network
import XCTest
@testable import Helium

final class ResetDuringConfigLoadTests: XCTestCase {

    private var fallbacksFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
        Helium.config.enableWebApplePayReadiness = false
        ApplePayHelper.shared.setCanMakePaymentsForTesting(true)
        fallbacksFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("helium-reset-race-\(UUID().uuidString).json")
        try Self.configJSON().write(to: fallbacksFileURL)
        Helium.config.customFallbacksURL = fallbacksFileURL
    }

    override func tearDown() {
        Helium.config.customFallbacksURL = nil
        Helium.config.enableWebApplePayReadiness = true
        ApplePayHelper.shared.setCanMakePaymentsForTesting(nil)
        if let fallbacksFileURL {
            try? FileManager.default.removeItem(at: fallbacksFileURL)
        }
        Helium.resetHelium()
        super.tearDown()
    }

    func testFallbackLoadStoresItsConfigWhenNoResetIntervenes() async {
        HeliumFallbackViewManager.shared.setUpFallbackBundle()

        await fulfillment(of: [fallbackConfigLoaded()], timeout: 5)
    }

    func testFallbackLoadThatFinishesAfterResetIsDropped() async throws {
        HeliumFallbackViewManager.shared.setUpFallbackBundle()
        HeliumFallbackViewManager.reset()

        try await assertHolds(for: 2) { HeliumFallbackViewManager.shared.getConfig() == nil }
    }

    func testConcurrentResetsReleaseTheLoadedFallbackConfigOnce() {
        for _ in 0..<500 {
            HeliumFallbackViewManager.shared.injectFallbackConfigForTesting(
                makeTestConfig(triggers: ["paywall": makeTestPaywallInfo(trigger: "paywall")])
            )
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                HeliumFallbackViewManager.reset()
            }
        }

        XCTAssertNil(HeliumFallbackViewManager.shared.getConfig())
    }

    func testResetDropsEveryConfigFetchStartedBeforeIt() async throws {
        let firstRequest = expectation(description: "Config request reached the server")
        firstRequest.assertForOverFulfill = false
        let server = try StalledConfigServer { firstRequest.fulfill() }
        defer { server.stop() }
        try await server.start()

        let endpoint = "http://127.0.0.1:\(server.port)/config"
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            HeliumFetchedConfigManager.shared.fetchConfig(endpoint: endpoint, apiKey: "test_api_key") { _ in }
        }
        await fulfillment(of: [firstRequest], timeout: 10)

        HeliumFetchedConfigManager.reset()
        server.respondToAll(with: try Self.configJSON())

        try await assertHolds(for: 3) {
            HeliumFetchedConfigManager.shared.getConfig() == nil
                && HeliumFetchedConfigManager.shared.downloadStatus == .notDownloadedYet
        }
        XCTAssertEqual(server.requestCount, 1)
    }

    private func assertHolds(
        for seconds: TimeInterval,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            guard condition() else {
                XCTFail("Condition stopped holding", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
    }

    private func fallbackConfigLoaded() -> XCTestExpectation {
        XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in HeliumFallbackViewManager.shared.getConfig() != nil },
            object: nil
        )
    }

    private static func configJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "triggerToPaywalls": [String: Any](),
            "segmentBrowserWriteKey": "test_key",
            "segmentAnalyticsEndpoint": "https://test.example.com",
            "fetchedConfigID": UUID().uuidString,
        ])
    }
}

private final class StalledConfigServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.helium.tests.StalledConfigServer")
    private var connections: [NWConnection] = []
    private var _requestCount = 0
    private let onRequest: () -> Void

    init(onRequest: @escaping () -> Void) throws {
        self.onRequest = onRequest
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var requestCount: Int { queue.sync { _requestCount } }

    func start() async throws {
        let ready = AsyncStream<Void> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        for await _ in ready { break }
    }

    func respondToAll(with body: Data) {
        queue.async {
            var response = Data((
                "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Connection: close\r\n\r\n"
            ).utf8)
            response.append(body)
            for connection in self.connections {
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            self.connections.removeAll()
        }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, data?.isEmpty == false else { return }
            self.connections.append(connection)
            self._requestCount += 1
            self.onRequest()
        }
    }
}
