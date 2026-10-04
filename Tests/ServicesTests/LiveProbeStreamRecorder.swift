// The opt-in probe tees actual response bytes, including frames that fail typed SSE decoding.
// It forwards chunks without waiting for EOF; private SSE is never printed or committed.
import Foundation

class LiveProbeStreamRecorder: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var forwardingTask: URLSessionDataTask?
    private var output: FileHandle?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let directory = URL(fileURLWithPath: ".build/live-vtodo-probe", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let path = directory.appendingPathComponent("sse-\(UUID().uuidString).txt")
            guard FileManager.default.createFile(
                atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
            output = try FileHandle(forWritingTo: path)
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 180
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var forwarded = request
            if let body = forwarded.httpBodyStream {
                body.open()
                defer { body.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while body.hasBytesAvailable {
                    let count = body.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    bytes.append(buffer, count: count)
                }
                forwarded.httpBody = bytes
            }
            if let body = forwarded.httpBody {
                let bodyPath = directory.appendingPathComponent("request-body-\(UUID().uuidString).json")
                try body.write(to: bodyPath, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bodyPath.path)
                FileHandle.standardError.write(Data("LIVE_VTODO wireBytes=\(body.count)\n".utf8))
            }
            forwardingTask = session?.dataTask(with: forwarded)
            forwardingTask?.resume()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {
        forwardingTask?.cancel()
        session?.invalidateAndCancel()
        try? output?.close()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try output?.write(contentsOf: data) } catch {
            client?.urlProtocol(self, didFailWithError: error)
            forwardingTask?.cancel()
            return
        }
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? output?.close()
        if let error { client?.urlProtocol(self, didFailWithError: error) } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        session.finishTasksAndInvalidate()
    }
}
