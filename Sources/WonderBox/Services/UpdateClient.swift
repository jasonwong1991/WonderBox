import CryptoKit
import CoreServices
import Foundation

protocol UpdateFetching: Sendable {
    func latestRelease() async throws -> GitHubRelease
    func download(_ update: AvailableUpdate, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws
}

struct GitHubUpdateClient: UpdateFetching {
    // Ephemeral sessions avoid persistent caches, cookies, credentials and personal request headers.
    static func session(delegate: URLSessionDelegate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "WonderBox-UpdateChecker"]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: UpdateSource.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("WonderBox-UpdateChecker", forHTTPHeaderField: "User-Agent")
        let data: Data
        do { data = try await metadata(request, limit: 1_024 * 1_024) }
        catch UpdateError.http(let code) where code == 403 || code == 429 {
            DiagnosticLogger.shared.record(.updateAPIFallback, outcome: .partial, errorFamily: .network, metrics: [.httpStatus: Int64(code)])
            return try await latestReleaseFromPublicPage()
        }
        do { return try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw UpdateError.invalidRelease }
    }

    /// GitHub's own latest redirect and published checksum file also work when a shared network
    /// exhausts the unauthenticated REST quota. No HTML scraping or third-party update service.
    private func latestReleaseFromPublicPage() async throws -> GitHubRelease {
        let page = try await head(UpdateSource.latestPageURL)
        guard let url = page.url else { throw UpdateError.invalidRelease }
        let tag = try UpdateSource.releaseTag(from: url)
        let number = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let name = "WonderBox-\(number).zip"
        let assetURL = UpdateSource.releasesURL.appendingPathComponent("download").appendingPathComponent(tag).appendingPathComponent(name)
        let assetResponse = try await head(assetURL)
        guard let sizeText = assetResponse.value(forHTTPHeaderField: "Content-Length"), let size = Int64(sizeText),
              size > 0, size <= UpdateSource.maximumDownloadSize else { throw UpdateError.missingAsset }
        let sumsURL = UpdateSource.releasesURL.appendingPathComponent("download").appendingPathComponent(tag).appendingPathComponent("SHA256SUMS")
        let sum = try UpdateSource.checksum(in: await metadata(URLRequest(url: sumsURL), limit: 65_536), filename: name)
        return GitHubRelease(tagName: tag, htmlURL: url, draft: false, prerelease: false, body: nil,
                             assets: [.init(name: name, size: size, browserDownloadURL: assetURL, digest: "sha256:" + sum)])
    }

    private func head(_ url: URL) async throws -> HTTPURLResponse {
        let session = Self.session(delegate: UpdateNetworkDelegate())
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("WonderBox-UpdateChecker", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
        return http
    }

    private func metadata(_ request: URLRequest, limit: Int) async throws -> Data {
        let session = Self.session(delegate: UpdateNetworkDelegate())
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)
        guard response.expectedContentLength <= Int64(limit) else { throw UpdateError.oversized }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw UpdateError.oversized }
            data.append(byte)
        }
        return data
    }

    func download(_ update: AvailableUpdate, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let tag = try UpdateSource.releaseTag(from: update.releaseURL)
        guard update.asset.size > 0, update.asset.size <= UpdateSource.maximumDownloadSize,
              update.asset.name == "WonderBox-\(update.version).zip",
              UpdateSource.isAssetURL(update.asset.browserDownloadURL, tag: tag, name: update.asset.name) else {
            throw UpdateError.missingAsset
        }
        let checksum: String
        if let digest = update.sha256 {
            guard UpdateSource.isSHA256(digest) else { throw UpdateError.invalidChecksum }
            checksum = digest
        } else if let url = update.checksumURL {
            guard UpdateSource.isAssetURL(url, tag: tag, name: "SHA256SUMS") else { throw UpdateError.invalidChecksum }
            checksum = try UpdateSource.checksum(in: await metadata(URLRequest(url: url), limit: 65_536), filename: update.asset.name)
        } else { throw UpdateError.invalidChecksum }
        let delegate = UpdateNetworkDelegate(expectedSize: update.asset.size, progress: progress)
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await delegate.download(URLRequest(url: update.asset.browserDownloadURL)) }
        catch {
            if delegate.exceededLimit { throw UpdateError.oversized }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
        try Self.validate(response)
        let verification = Task.detached(priority: .utility) {
            try UpdateFileStorage.verifyArchive(temporary, expectedSize: update.asset.size, sha256: checksum)
            try UpdateFileStorage.markDownloadedArchive(temporary, sourceURL: update.asset.browserDownloadURL, originURL: update.releaseURL)
            try Task.checkCancellation()
            try AtomicFileExport.save(temporary, to: destination)
        }
        try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
    }
}

private final class UpdateNetworkDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedSize: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var oversized = false
    private var lastProgress = Date.distantPast
    private var cancelled = false
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadedResult: Result<(URL, URLResponse), Error>?
    var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return oversized }

    init(expectedSize: Int64 = UpdateSource.maximumDownloadSize, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.expectedSize = expectedSize
        self.progress = progress
    }

    /// Completion-handler/async download tasks suppress download progress callbacks on some
    /// macOS releases. Use a delegate-driven task and bridge it, including early cancellation.
    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = GitHubUpdateClient.session(delegate: self)
                let task = session.downloadTask(with: request)
                lock.lock()
                if cancelled {
                    lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                downloadSession = session
                downloadTask = task
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancelDownload() }
    }

    private func cancelDownload() {
        lock.lock()
        cancelled = true
        let task = downloadTask
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url == UpdateSource.latestURL || UpdateSource.permitsRedirect(to: url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        if totalBytesWritten > expectedSize || totalBytesExpectedToWrite > expectedSize {
            oversized = true
            lock.unlock()
            downloadTask.cancel()
            return
        }
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastProgress) >= 0.1 || totalBytesWritten == expectedSize
        if shouldReport { lastProgress = now }
        lock.unlock()
        if shouldReport { progress(min(1, max(0, Double(totalBytesWritten) / Double(expectedSize)))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WonderBox-update-\(UUID().uuidString)", isDirectory: true)
        let result: Result<(URL, URLResponse), Error>
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
            guard response.statusCode == 200 else { throw UpdateError.http(response.statusCode) }
            // URLSession removes `location` when this callback returns, before an async caller resumes.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("download.zip")
            try FileManager.default.moveItem(at: location, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            result = .success((file, response))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            result = .failure(error)
        }
        lock.lock()
        downloadedResult = result
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        let saved = downloadedResult
        let result: Result<(URL, URLResponse), Error>
        if oversized { result = .failure(UpdateError.oversized) }
        else if let error { result = .failure(error) }
        else { result = saved ?? .failure(UpdateError.invalidArchive) }
        self.continuation = nil
        downloadSession = nil
        downloadTask = nil
        downloadedResult = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if case .failure = result, case let .success((url, _)) = saved {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        continuation.resume(with: result)
    }
}

enum UpdateFileStorage {
    /// Keep normal macOS download provenance/Gatekeeper behavior instead of silently stripping it.
    static func markDownloadedArchive(_ url: URL, sourceURL: URL, originURL: URL) throws {
        let properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "WonderBox",
            kLSQuarantineAgentBundleIdentifierKey as String: "com.wondercraft.WonderBox",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineDataURLKey as String: sourceURL,
            kLSQuarantineOriginURLKey as String: originURL
        ]
        try (url as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
    }
    static func verifyArchive(_ url: URL, expectedSize: Int64, sha256: String) throws {
        guard UpdateSource.isSHA256(sha256), expectedSize > 0, expectedSize <= UpdateSource.maximumDownloadSize else {
            throw UpdateError.invalidChecksum
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == expectedSize else { throw UpdateError.sizeMismatch }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4)
        guard header == Data([0x50, 0x4b, 0x03, 0x04]) else { throw UpdateError.invalidArchive }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
            throw UpdateError.checksumMismatch
        }
    }
}
