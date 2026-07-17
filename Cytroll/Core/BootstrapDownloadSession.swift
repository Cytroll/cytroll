import Foundation

/// Real HTTP download with byte-level progress (not a fake timer).
final class BootstrapDownloadSession: NSObject, URLSessionDownloadDelegate {
    static let shared = BootstrapDownloadSession()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var onProgress: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    func download(from url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            lock.lock()
            if continuation != nil {
                lock.unlock()
                cont.resume(throwing: URLError(.unknown))
                return
            }
            self.continuation = cont
            self.onProgress = onProgress
            lock.unlock()

            var request = URLRequest(url: url)
            request.setValue("Cytroll/1.0", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            onProgress?(0.05)
            return
        }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent(
            "cytroll-bootstrap-\(UUID().uuidString).tmp"
        )
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: location, to: dest)

            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                try? fm.removeItem(at: dest)
                finish(.failure(URLError(.badServerResponse)))
                return
            }

            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        onProgress = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}
