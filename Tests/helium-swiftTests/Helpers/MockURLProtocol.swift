import Foundation

/// URLProtocol interceptor for URLSession-based tests. Register on a
/// URLSessionConfiguration to route every request through `requestHandler`.
final class MockURLProtocol: URLProtocol {

    private static let stateQueue = DispatchQueue(label: "com.helium.tests.MockURLProtocol")
    private static var _requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    private static var _capturedRequests: [URLRequest] = []

    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))? {
        get { stateQueue.sync { _requestHandler } }
        set { stateQueue.sync { _requestHandler = newValue } }
    }

    static var capturedRequests: [URLRequest] {
        stateQueue.sync { _capturedRequests }
    }

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

    override func stopLoading() {}

    /// URLSession may convert a small `httpBody` into an `httpBodyStream`
    /// before handing the request to URLProtocol; re-materialize it so
    /// tests can assert on `httpBody`.
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
