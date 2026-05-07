import Foundation

/// URLProtocol-based interceptor for testing code that uses URLSession.
///
/// Why URLProtocol (not method stubs):
///   URLSession's data(for:) delegates to its registered protocols. If we
///   register MockURLProtocol on a URLSessionConfiguration, every request
///   that session makes routes through MockURLProtocol.startLoading -- which
///   gives tests full control over the response body, status code, and
///   headers without touching the real network.
///
///   Stubbing methods on URLSession would require sublcassing it, which the
///   Foundation API isn't designed for and tends to surprise consumers
///   (some methods aren't dispatchable). URLProtocol is the API-sanctioned
///   way.
///
/// Usage:
///   let config = URLSessionConfiguration.ephemeral
///   config.protocolClasses = [MockURLProtocol.self]
///   let session = URLSession(configuration: config)
///   MockURLProtocol.requestHandler = { request in
///       let response = HTTPURLResponse(url: request.url!, statusCode: 200, ...)
///       return (response, jsonData)
///   }
///
/// Always reset the requestHandler in tearDown so handlers don't leak across
/// tests (the handler is a static, so without reset a later test could pick
/// up a previous test's stubbed behavior).
///
/// Concurrency: URLProtocol callbacks run on URLSession's internal queue, and
/// when the protocol is registered on a session that issues parallel data(for:)
/// calls (the prefetch coordinator's parallel fan-out is the canonical case),
/// `startLoading()` fires concurrently from multiple threads. Both
/// `requestHandler` (read) and `capturedRequests` (read+append) need to be
/// serialized — otherwise tests intermittently lose captured requests or
/// race-condition during `reset()` between two tests. We use a serial dispatch
/// queue as the synchronization primitive (lighter than an actor, and the
/// protocol's instance methods aren't async-friendly anyway).
final class MockURLProtocol: URLProtocol {

    private static let stateQueue = DispatchQueue(label: "com.helium.tests.MockURLProtocol")
    private static var _requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    private static var _capturedRequests: [URLRequest] = []

    /// Test sets this closure; the protocol calls it for every intercepted
    /// request and uses the returned response + body. Throwing from the
    /// handler surfaces as a transport error to the caller, which lets tests
    /// drive both happy-path and network-failure cases.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))? {
        get { stateQueue.sync { _requestHandler } }
        set { stateQueue.sync { _requestHandler = newValue } }
    }

    /// Captured requests, in order. Lets tests assert on the exact URL,
    /// method, headers, and body that was sent — useful when the production
    /// code's contract with the server is part of what's under test.
    static var capturedRequests: [URLRequest] {
        stateQueue.sync { _capturedRequests }
    }

    /// Internal append, called from `startLoading`. Serializes via the
    /// state queue so concurrent loads don't race when appending.
    fileprivate static func appendCapturedRequest(_ request: URLRequest) {
        stateQueue.sync { _capturedRequests.append(request) }
    }

    static func reset() {
        stateQueue.sync {
            _requestHandler = nil
            _capturedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // Intercept every request that reaches a session this protocol is
        // registered on. The session-level registration is the gate; we
        // don't filter further here.
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "MockURLProtocol",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No requestHandler set on MockURLProtocol — set one in your test setUp"]
                )
            )
            return
        }

        // Capture the canonical request. URLProtocol receives a fully-formed
        // request (incl. body via httpBodyStream when the body is large), so
        // tests get fidelity on what would have hit the wire. Pass the
        // body-materialized request to the handler too — otherwise a test
        // handler that inspects `request.httpBody` would see nil whenever
        // URLSession converted the body to a stream.
        let materializedRequest = captureWithBody(request)
        MockURLProtocol.appendCapturedRequest(materializedRequest)

        do {
            let (response, body) = try handler(materializedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let body = body {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No long-running work to cancel; loading completes synchronously
        // inside startLoading().
    }

    /// URLSession may convert a small `httpBody` into an `httpBodyStream`
    /// before handing the request to URLProtocol. To assert on the body in
    /// tests, we re-materialize it here.
    private func captureWithBody(_ request: URLRequest) -> URLRequest {
        if request.httpBody != nil { return request }
        guard let stream = request.httpBodyStream else { return request }

        var copy = request
        var data = Data()
        stream.open()
        defer { stream.close() }
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        copy.httpBody = data
        return copy
    }
}
