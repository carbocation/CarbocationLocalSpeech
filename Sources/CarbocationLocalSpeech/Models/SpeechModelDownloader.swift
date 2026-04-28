import CryptoKit
import Darwin
import Foundation
import OSLog

private let speechModelDownloaderLog = Logger(
    subsystem: "com.carbocation.CarbocationLocalSpeech",
    category: "SpeechModelDownloader"
)

public enum SpeechModelDownloaderError: Error, LocalizedError, Sendable {
    case badURL(String)
    case httpStatus(Int)
    case hashMismatch(expected: String, actual: String)
    case noContentLength
    case incompleteResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badURL(let value):
            return "Invalid speech model download URL: \(value)"
        case .httpStatus(let code):
            return "Speech model download failed with HTTP \(code)."
        case .hashMismatch(let expected, let actual):
            return "SHA256 mismatch; expected \(expected.prefix(12)), got \(actual.prefix(12))."
        case .noContentLength:
            return "Server did not report a content length."
        case .incompleteResponse:
            return "Server closed the connection before the speech model download completed."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

public struct SpeechDownloadProgress: Sendable, Hashable {
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double

    public init(bytesReceived: Int64, totalBytes: Int64, bytesPerSecond: Double) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionComplete: Double {
        totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : 0
    }
}

public struct PartialSpeechModelDownload: Identifiable, Hashable, Sendable {
    public var id: String
    public var partialURL: URL
    public var sidecarURL: URL
    public var sourceURL: URL
    public var displayName: String
    public var hfRepo: String?
    public var hfFilename: String?
    public var totalBytes: Int64
    public var bytesOnDisk: Int64

    public init(
        id: String,
        partialURL: URL,
        sidecarURL: URL,
        sourceURL: URL,
        displayName: String,
        hfRepo: String? = nil,
        hfFilename: String? = nil,
        totalBytes: Int64,
        bytesOnDisk: Int64
    ) {
        self.id = id
        self.partialURL = partialURL
        self.sidecarURL = sidecarURL
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.hfRepo = hfRepo
        self.hfFilename = hfFilename
        self.totalBytes = totalBytes
        self.bytesOnDisk = bytesOnDisk
    }

    public var fractionComplete: Double {
        totalBytes > 0 ? Double(bytesOnDisk) / Double(totalBytes) : 0
    }
}

public struct SpeechModelDownloadResult: Sendable, Hashable {
    public let tempURL: URL
    public let sizeBytes: Int64
    public let sha256: String

    public init(tempURL: URL, sizeBytes: Int64, sha256: String) {
        self.tempURL = tempURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public struct SpeechModelDownloadConfiguration: Sendable, Hashable {
    public static let defaultChunkSize: Int64 = 16 * 1_024 * 1_024
    public static let defaultParallelConnections = 12
    public static let maximumParallelConnections = 32

    public var parallelConnections: Int
    public var chunkSize: Int64
    public var requestTimeout: TimeInterval

    public init(
        parallelConnections: Int = Self.defaultParallelConnections,
        chunkSize: Int64 = Self.defaultChunkSize,
        requestTimeout: TimeInterval = 3_600
    ) {
        self.parallelConnections = min(
            max(1, parallelConnections),
            Self.maximumParallelConnections
        )
        self.chunkSize = max(1_024 * 1_024, chunkSize)
        self.requestTimeout = max(30, requestTimeout)
    }

    public static let `default` = SpeechModelDownloadConfiguration()
}

private struct PartialSpeechSidecar: Codable, Sendable {
    var url: String
    var etag: String?
    var lastModified: String?
    var totalBytes: Int64
    var displayName: String?
    var schemaVersion: Int?
    var chunkSize: Int64?
    var doneChunks: [Int]?
}

private struct PartialSpeechDownloadState: Sendable {
    let existingSize: Int64
    let totalBytes: Int64
    let etag: String?
    let lastModified: String?
}

private struct SpeechDownloadChunkRange: Sendable, Hashable {
    let index: Int
    let start: Int64
    let end: Int64

    var length: Int64 {
        end - start + 1
    }
}

private struct SpeechDownloadChunkPlan: Sendable, Hashable {
    static let defaultChunkSize: Int64 = SpeechModelDownloadConfiguration.defaultChunkSize

    let totalBytes: Int64
    let chunkSize: Int64
    var doneChunks: Set<Int>

    init(
        totalBytes: Int64,
        chunkSize: Int64 = defaultChunkSize,
        doneChunks: Set<Int> = []
    ) {
        self.totalBytes = totalBytes
        self.chunkSize = chunkSize
        self.doneChunks = doneChunks
    }

    var chunkCount: Int {
        Int((totalBytes + chunkSize - 1) / chunkSize)
    }

    func chunkRange(for index: Int) -> SpeechDownloadChunkRange {
        let start = Int64(index) * chunkSize
        let end = min(start + chunkSize - 1, totalBytes - 1)
        return SpeechDownloadChunkRange(index: index, start: start, end: end)
    }

    func pendingRanges() -> [SpeechDownloadChunkRange] {
        (0..<chunkCount)
            .filter { !doneChunks.contains($0) }
            .map { chunkRange(for: $0) }
    }

    func completedBytes() -> Int64 {
        doneChunks.reduce(Int64(0)) { partial, index in
            partial + chunkRange(for: index).length
        }
    }
}

private final class SpeechRandomAccessFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(url: URL) throws {
        let openedFD = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDWR) } ?? -1
        }
        guard openedFD >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        fd = openedFD
    }

    func write(_ data: Data, at offset: Int64) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }

            lock.lock()
            defer { lock.unlock() }

            guard fd >= 0 else {
                throw POSIXError(.EBADF)
            }

            var bytesRemaining = rawBuffer.count
            var localOffset = 0
            while bytesRemaining > 0 {
                let written = Darwin.pwrite(
                    fd,
                    baseAddress.advanced(by: localOffset),
                    bytesRemaining,
                    off_t(offset + Int64(localOffset))
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else {
                    throw POSIXError(.EIO)
                }
                bytesRemaining -= written
                localOffset += written
            }
        }
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }

        let result = Darwin.close(fd)
        fd = -1
        if result != 0 {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }
}

private actor SpeechChunkWorkQueue {
    private var pending: [SpeechDownloadChunkRange]
    private var done: Set<Int>
    private let sidecarURL: URL
    private var sidecar: PartialSpeechSidecar
    private var lastPersist: Date = .distantPast

    init(
        pending: [SpeechDownloadChunkRange],
        done: Set<Int>,
        sidecarURL: URL,
        sidecar: PartialSpeechSidecar
    ) {
        self.pending = pending
        self.done = done
        self.sidecarURL = sidecarURL
        self.sidecar = sidecar
    }

    func nextChunk() -> SpeechDownloadChunkRange? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func markDone(_ index: Int) {
        done.insert(index)
        let now = Date()
        if now.timeIntervalSince(lastPersist) >= 1 {
            lastPersist = now
            persistSidecar()
        }
    }

    func flush() {
        persistSidecar()
    }

    var completedCount: Int {
        done.count
    }

    private func persistSidecar() {
        sidecar.doneChunks = Array(done).sorted()
        if let data = try? JSONEncoder().encode(sidecar) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }
}

private final class SpeechProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var chunkBytes: [Int: Int64] = [:]
    private let alreadyHad: Int64
    private let totalBytes: Int64
    private let started = Date()
    private var lastEmit = Date(timeIntervalSince1970: 0)

    init(alreadyHad: Int64, totalBytes: Int64) {
        self.alreadyHad = alreadyHad
        self.totalBytes = totalBytes
    }

    func add(_ bytes: Int64, forChunk index: Int) {
        lock.lock()
        defer { lock.unlock() }
        chunkBytes[index, default: 0] += bytes
    }

    func maybeEmit(_ onProgress: @Sendable (SpeechDownloadProgress) -> Void) {
        let progress: SpeechDownloadProgress?
        let now = Date()
        lock.lock()
        if now.timeIntervalSince(lastEmit) >= 0.25 {
            lastEmit = now
            let received = alreadyHad + chunkBytes.values.reduce(0, +)
            let elapsed = now.timeIntervalSince(started)
            let bytesPerSecond = elapsed > 0 ? Double(received - alreadyHad) / elapsed : 0
            progress = SpeechDownloadProgress(
                bytesReceived: received,
                totalBytes: totalBytes,
                bytesPerSecond: bytesPerSecond
            )
        } else {
            progress = nil
        }
        lock.unlock()

        if let progress {
            onProgress(progress)
        }
    }
}

private final class SpeechURLSessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private final class SpeechRangedChunkDownloadState {
    let chunk: SpeechDownloadChunkRange
    let writer: SpeechRandomAccessFileWriter
    let tracker: SpeechProgressTracker
    let onProgress: @Sendable (SpeechDownloadProgress) -> Void
    let continuation: CheckedContinuation<Void, Error>

    private let lock = NSLock()
    private var receivedBytes: Int64 = 0

    init(
        chunk: SpeechDownloadChunkRange,
        writer: SpeechRandomAccessFileWriter,
        tracker: SpeechProgressTracker,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.chunk = chunk
        self.writer = writer
        self.tracker = tracker
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func reserveWriteOffset(byteCount: Int) throws -> Int64 {
        let byteCount = Int64(byteCount)
        lock.lock()
        defer { lock.unlock() }

        guard receivedBytes + byteCount <= chunk.length else {
            throw SpeechModelDownloaderError.incompleteResponse
        }

        let offset = chunk.start + receivedBytes
        receivedBytes += byteCount
        return offset
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes == chunk.length
    }
}

private final class SpeechRangedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int: SpeechRangedChunkDownloadState] = [:]

    func download(
        request: URLRequest,
        chunk: SpeechDownloadChunkRange,
        session: URLSession,
        writer: SpeechRandomAccessFileWriter,
        tracker: SpeechProgressTracker,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void
    ) async throws {
        let taskBox = SpeechURLSessionTaskBox()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = SpeechRangedChunkDownloadState(
                    chunk: chunk,
                    writer: writer,
                    tracker: tracker,
                    onProgress: onProgress,
                    continuation: continuation
                )
                register(state, for: task)
                taskBox.set(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            complete(taskIdentifier: dataTask.taskIdentifier, with: .failure(SpeechModelDownloaderError.httpStatus(-1)))
            completionHandler(.cancel)
            return
        }

        guard http.statusCode == 206 else {
            complete(taskIdentifier: dataTask.taskIdentifier, with: .failure(SpeechModelDownloaderError.httpStatus(http.statusCode)))
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask.taskIdentifier) else { return }

        do {
            let offset = try state.reserveWriteOffset(byteCount: data.count)
            try state.writer.write(data, at: offset)
            state.tracker.add(Int64(data.count), forChunk: state.chunk.index)
            state.tracker.maybeEmit(state.onProgress)
        } catch {
            complete(taskIdentifier: dataTask.taskIdentifier, with: .failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = state(for: task.taskIdentifier) else { return }

        if let error {
            complete(taskIdentifier: task.taskIdentifier, with: .failure(error))
            return
        }

        guard state.isComplete else {
            complete(taskIdentifier: task.taskIdentifier, with: .failure(SpeechModelDownloaderError.incompleteResponse))
            return
        }

        complete(taskIdentifier: task.taskIdentifier, with: .success(()))
    }

    private func register(_ state: SpeechRangedChunkDownloadState, for task: URLSessionTask) {
        lock.lock()
        states[task.taskIdentifier] = state
        lock.unlock()
    }

    private func state(for taskIdentifier: Int) -> SpeechRangedChunkDownloadState? {
        lock.lock()
        defer { lock.unlock() }
        return states[taskIdentifier]
    }

    private func complete(taskIdentifier: Int, with result: Result<Void, Error>) {
        lock.lock()
        let state = states.removeValue(forKey: taskIdentifier)
        lock.unlock()

        guard let state else { return }

        switch result {
        case .success:
            state.continuation.resume()
        case .failure(let error):
            state.continuation.resume(throwing: error)
        }
    }
}

public enum SpeechModelDownloader {
    public static let partialPrefix = "cls-partial-"
    private static let userAgent = "CarbocationLocalSpeech/1.0"

    public static func huggingFaceResolveURL(repo: String, filename: String) throws -> URL {
        let urlString = "https://huggingface.co/\(repo)/resolve/main/\(filename)?download=true"
        guard let url = URL(string: urlString) else {
            throw SpeechModelDownloaderError.badURL(urlString)
        }
        return url
    }

    public static func download(
        hfRepo: String,
        hfFilename: String,
        modelsRoot: URL,
        displayName: String? = nil,
        expectedSHA256: String? = nil,
        configuration: SpeechModelDownloadConfiguration = .default,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void = { _ in }
    ) async throws -> SpeechModelDownloadResult {
        try await download(
            from: huggingFaceResolveURL(repo: hfRepo, filename: hfFilename),
            displayName: displayName,
            expectedSHA256: expectedSHA256,
            to: modelsRoot,
            configuration: configuration,
            onProgress: onProgress
        )
    }

    public static func partialsDirectory(
        in root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = root.appendingPathComponent(".partials", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func listPartials(
        in root: URL,
        fileManager: FileManager = .default
    ) -> [PartialSpeechModelDownload] {
        guard let partialsRoot = try? partialsDirectory(in: root, fileManager: fileManager),
              let entries = try? fileManager.contentsOfDirectory(
                at: partialsRoot,
                includingPropertiesForKeys: [.fileSizeKey],
                options: []
              )
        else { return [] }

        var result: [PartialSpeechModelDownload] = []
        for sidecarURL in entries where isPartialSidecar(sidecarURL) {
            let stem = sidecarURL.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? JSONDecoder().decode(PartialSpeechSidecar.self, from: data),
                  let sourceURL = URL(string: sidecar.url),
                  sidecar.totalBytes > 0
            else { continue }

            let partialURL = matchingPartialFile(stem: stem, in: partialsRoot, fileManager: fileManager)
                ?? partialsRoot.appendingPathComponent("\(stem).bin")
            guard fileManager.fileExists(atPath: partialURL.path) else {
                try? fileManager.removeItem(at: sidecarURL)
                continue
            }

            let key = partialKey(fromStem: stem) ?? stem
            let bytesOnDisk = bytesOnDisk(for: sidecar, partialURL: partialURL, fileManager: fileManager)
            let (hfRepo, hfFilename) = parseHFCoords(from: sourceURL) ?? (nil, nil)
            let displayName = sidecar.displayName
                ?? hfFilename?.replacingOccurrences(of: ".bin", with: "")
                ?? sourceURL.deletingPathExtension().lastPathComponent

            result.append(PartialSpeechModelDownload(
                id: key,
                partialURL: partialURL,
                sidecarURL: sidecarURL,
                sourceURL: sourceURL,
                displayName: displayName,
                hfRepo: hfRepo,
                hfFilename: hfFilename,
                totalBytes: sidecar.totalBytes,
                bytesOnDisk: min(bytesOnDisk, sidecar.totalBytes)
            ))
        }

        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public static func deletePartial(
        _ partial: PartialSpeechModelDownload,
        fileManager: FileManager = .default
    ) {
        discardPartial(partialURL: partial.partialURL, sidecarURL: partial.sidecarURL, fileManager: fileManager)
    }

    /// Downloads a whisper.cpp `.bin` file into the model cache's `.partials` directory.
    /// Range-capable servers use a chunked sidecar and parallel workers; other servers fall back to single-stream resume.
    public static func download(
        from sourceURL: URL,
        displayName: String? = nil,
        expectedSHA256: String? = nil,
        to root: URL,
        configuration: SpeechModelDownloadConfiguration = .default,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void = { _ in }
    ) async throws -> SpeechModelDownloadResult {
        try await download(
            from: sourceURL,
            displayName: displayName,
            expectedSHA256: expectedSHA256,
            to: root,
            fileManager: .default,
            configuration: configuration,
            onProgress: onProgress
        )
    }

    public static func download(
        from sourceURL: URL,
        displayName: String? = nil,
        expectedSHA256: String? = nil,
        to root: URL,
        fileManager: FileManager,
        configuration: SpeechModelDownloadConfiguration = .default,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void = { _ in }
    ) async throws -> SpeechModelDownloadResult {
        let (partialURL, sidecarURL) = try partialPaths(for: sourceURL, root: root, fileManager: fileManager)

        if let (plan, sidecar) = loadChunkedState(
            partialURL: partialURL,
            sidecarURL: sidecarURL,
            sourceURL: sourceURL,
            fileManager: fileManager
        ) {
            var updatedSidecar = sidecar
            if updatedSidecar.displayName == nil, let displayName {
                updatedSidecar.displayName = displayName
                writeSidecarValue(updatedSidecar, to: sidecarURL)
            }

            speechModelDownloaderLog.info(
                "Resuming chunked \(sourceURL.lastPathComponent, privacy: .public) (\(plan.doneChunks.count)/\(plan.chunkCount) chunks done)"
            )

            return try await downloadParallel(
                url: sourceURL,
                partialURL: partialURL,
                sidecarURL: sidecarURL,
                plan: plan,
                sidecar: updatedSidecar,
                fileManager: fileManager,
                configuration: configuration,
                expectedSHA256: expectedSHA256,
                onProgress: onProgress
            )
        }

        let legacy = loadSingleStreamState(
            partialURL: partialURL,
            sidecarURL: sidecarURL,
            sourceURL: sourceURL,
            fileManager: fileManager
        )

        guard let probe = try await probeServer(url: sourceURL) else {
            speechModelDownloaderLog.info(
                "Server does not support Range for \(sourceURL.lastPathComponent, privacy: .public); using single stream"
            )
            return try await downloadSingleStream(
                url: sourceURL,
                partialURL: partialURL,
                sidecarURL: sidecarURL,
                prior: legacy,
                displayName: displayName,
                fileManager: fileManager,
                expectedSHA256: expectedSHA256,
                onProgress: onProgress
            )
        }

        let totalBytes = probe.totalBytes
        var doneChunks = Set<Int>()
        if let legacy {
            if legacy.totalBytes == totalBytes {
                let fullChunks = legacy.existingSize / configuration.chunkSize
                for index in 0..<Int(fullChunks) {
                    doneChunks.insert(index)
                }
                speechModelDownloaderLog.info("Credited \(fullChunks) legacy chunks from single-stream partial")
            } else {
                discardPartial(partialURL: partialURL, sidecarURL: sidecarURL, fileManager: fileManager)
            }
        }

        let plan = SpeechDownloadChunkPlan(
            totalBytes: totalBytes,
            chunkSize: configuration.chunkSize,
            doneChunks: doneChunks
        )
        let sidecar = PartialSpeechSidecar(
            url: sourceURL.absoluteString,
            etag: probe.etag,
            lastModified: probe.lastModified,
            totalBytes: totalBytes,
            displayName: displayName,
            schemaVersion: 2,
            chunkSize: configuration.chunkSize,
            doneChunks: Array(doneChunks).sorted()
        )

        if !fileManager.fileExists(atPath: partialURL.path) {
            fileManager.createFile(atPath: partialURL.path, contents: nil)
        }
        let allocationHandle = try FileHandle(forWritingTo: partialURL)
        try allocationHandle.truncate(atOffset: UInt64(totalBytes))
        try allocationHandle.close()

        writeSidecarValue(sidecar, to: sidecarURL)

        speechModelDownloaderLog.info(
            "Starting parallel speech model download \(sourceURL.lastPathComponent, privacy: .public) (\(totalBytes) bytes, \(plan.chunkCount) chunks, \(configuration.parallelConnections) connections)"
        )

        return try await downloadParallel(
            url: sourceURL,
            partialURL: partialURL,
            sidecarURL: sidecarURL,
            plan: plan,
            sidecar: sidecar,
            fileManager: fileManager,
            configuration: configuration,
            expectedSHA256: expectedSHA256,
            onProgress: onProgress
        )
    }

    private static func downloadParallel(
        url: URL,
        partialURL: URL,
        sidecarURL: URL,
        plan: SpeechDownloadChunkPlan,
        sidecar: PartialSpeechSidecar,
        fileManager: FileManager,
        configuration: SpeechModelDownloadConfiguration,
        expectedSHA256: String?,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void
    ) async throws -> SpeechModelDownloadResult {
        let alreadyHad = plan.completedBytes()
        let queue = SpeechChunkWorkQueue(
            pending: plan.pendingRanges(),
            done: plan.doneChunks,
            sidecarURL: sidecarURL,
            sidecar: sidecar
        )
        let tracker = SpeechProgressTracker(alreadyHad: alreadyHad, totalBytes: plan.totalBytes)
        let writer = try SpeechRandomAccessFileWriter(url: partialURL)
        let validator = sidecar.etag ?? sidecar.lastModified
        let delegate = SpeechRangedDownloadDelegate()
        let session = makeURLSession(configuration: configuration, delegate: delegate)
        defer { session.invalidateAndCancel() }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<configuration.parallelConnections {
                    group.addTask {
                        while let chunk = await queue.nextChunk() {
                            try Task.checkCancellation()
                            try await downloadChunk(
                                chunk: chunk,
                                from: url,
                                validator: validator,
                                session: session,
                                delegate: delegate,
                                requestTimeout: configuration.requestTimeout,
                                writer: writer,
                                queue: queue,
                                tracker: tracker,
                                onProgress: onProgress
                            )
                        }
                    }
                }
                try await group.waitForAll()
            }
            try writer.close()
        } catch is CancellationError {
            try? writer.close()
            await queue.flush()
            throw SpeechModelDownloaderError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            try? writer.close()
            await queue.flush()
            throw SpeechModelDownloaderError.cancelled
        } catch {
            try? writer.close()
            await queue.flush()
            throw error
        }

        await queue.flush()
        let completedCount = await queue.completedCount
        guard completedCount == plan.chunkCount else {
            throw SpeechModelDownloaderError.httpStatus(-2)
        }

        let digest: String
        do {
            digest = try verifyFinalHash(at: partialURL, expected: expectedSHA256)
        } catch {
            discardPartial(partialURL: partialURL, sidecarURL: sidecarURL, fileManager: fileManager)
            throw error
        }

        try? fileManager.removeItem(at: sidecarURL)
        onProgress(SpeechDownloadProgress(
            bytesReceived: plan.totalBytes,
            totalBytes: plan.totalBytes,
            bytesPerSecond: 0
        ))

        return SpeechModelDownloadResult(tempURL: partialURL, sizeBytes: plan.totalBytes, sha256: digest)
    }

    private static func downloadChunk(
        chunk: SpeechDownloadChunkRange,
        from url: URL,
        validator: String?,
        session: URLSession,
        delegate: SpeechRangedDownloadDelegate,
        requestTimeout: TimeInterval,
        writer: SpeechRandomAccessFileWriter,
        queue: SpeechChunkWorkQueue,
        tracker: SpeechProgressTracker,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
        if let validator {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        request.timeoutInterval = requestTimeout

        try Task.checkCancellation()
        try await delegate.download(
            request: request,
            chunk: chunk,
            session: session,
            writer: writer,
            tracker: tracker,
            onProgress: onProgress
        )
        await queue.markDone(chunk.index)
        tracker.maybeEmit(onProgress)
    }

    private static func makeURLSession(
        configuration: SpeechModelDownloadConfiguration,
        delegate: URLSessionDataDelegate? = nil
    ) -> URLSession {
        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.httpMaximumConnectionsPerHost = configuration.parallelConnections
        urlSessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlSessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        urlSessionConfiguration.timeoutIntervalForResource = configuration.requestTimeout
        urlSessionConfiguration.urlCache = nil
        urlSessionConfiguration.waitsForConnectivity = true

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.carbocation.CarbocationLocalSpeech.SpeechModelDownloader"
        delegateQueue.maxConcurrentOperationCount = 1

        return URLSession(
            configuration: urlSessionConfiguration,
            delegate: delegate,
            delegateQueue: delegate == nil ? nil : delegateQueue
        )
    }

    private struct ProbeResult: Sendable {
        let totalBytes: Int64
        let etag: String?
        let lastModified: String?
    }

    private static func probeServer(url: URL) async throws -> ProbeResult? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30

        let (_, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            return nil
        }
        guard let totalBytes = parseContentRangeTotal(http), totalBytes > 0 else {
            return nil
        }

        return ProbeResult(
            totalBytes: totalBytes,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    private static func downloadSingleStream(
        url: URL,
        partialURL: URL,
        sidecarURL: URL,
        prior: PartialSpeechDownloadState?,
        displayName: String?,
        fileManager: FileManager,
        expectedSHA256: String?,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void
    ) async throws -> SpeechModelDownloadResult {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 3_600

        if let prior {
            request.setValue("bytes=\(prior.existingSize)-", forHTTPHeaderField: "Range")
            if let validator = prior.etag ?? prior.lastModified {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
            speechModelDownloaderLog.info(
                "Resuming single-stream \(url.lastPathComponent, privacy: .public) from byte \(prior.existingSize)"
            )
        }

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpeechModelDownloaderError.httpStatus(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SpeechModelDownloaderError.httpStatus(http.statusCode)
        }

        let isResume = http.statusCode == 206
        let existingSize: Int64
        let totalBytes: Int64
        if isResume, let prior {
            if let rangeTotal = parseContentRangeTotal(http), rangeTotal != prior.totalBytes {
                discardPartial(partialURL: partialURL, sidecarURL: sidecarURL, fileManager: fileManager)
                throw SpeechModelDownloaderError.httpStatus(200)
            }
            existingSize = prior.existingSize
            totalBytes = prior.totalBytes
        } else {
            existingSize = 0
            totalBytes = http.expectedContentLength
            discardPartial(partialURL: partialURL, sidecarURL: sidecarURL, fileManager: fileManager)
            try fileManager.createDirectory(
                at: partialURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: partialURL.path, contents: nil)
            if totalBytes > 0 {
                writeSingleStreamSidecar(
                    to: sidecarURL,
                    sourceURL: url,
                    totalBytes: totalBytes,
                    etag: http.value(forHTTPHeaderField: "ETag"),
                    lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                    displayName: displayName
                )
            }
        }

        var hasher = SHA256()
        if existingSize > 0 {
            try updateHasher(&hasher, withPrefixOf: partialURL, byteCount: existingSize)
        }

        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        if isResume {
            try handle.seekToEnd()
        }

        let started = Date()
        var lastEmit = Date(timeIntervalSince1970: 0)
        var received = existingSize
        var buffer: [UInt8] = []
        buffer.reserveCapacity(1 << 20)

        do {
            for try await byte in stream {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    let data = Data(buffer)
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    received += Int64(data.count)
                    emitProgressIfNeeded(
                        received: received,
                        total: totalBytes,
                        started: started,
                        lastEmit: &lastEmit,
                        onProgress: onProgress
                    )
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        } catch is CancellationError {
            throw SpeechModelDownloaderError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw SpeechModelDownloaderError.cancelled
        }

        if !buffer.isEmpty {
            let data = Data(buffer)
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            received += Int64(data.count)
        }

        guard totalBytes <= 0 || received == totalBytes else {
            throw SpeechModelDownloaderError.incompleteResponse
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = expectedSHA256?.lowercased(),
           !expected.isEmpty,
           expected != digest.lowercased() {
            discardPartial(partialURL: partialURL, sidecarURL: sidecarURL, fileManager: fileManager)
            throw SpeechModelDownloaderError.hashMismatch(expected: expected, actual: digest)
        }

        try? fileManager.removeItem(at: sidecarURL)
        onProgress(SpeechDownloadProgress(
            bytesReceived: received,
            totalBytes: max(totalBytes, received),
            bytesPerSecond: 0
        ))
        return SpeechModelDownloadResult(tempURL: partialURL, sizeBytes: received, sha256: digest)
    }

    private static func partialPaths(
        for url: URL,
        root: URL,
        fileManager: FileManager
    ) throws -> (partial: URL, sidecar: URL) {
        let directory = try partialsDirectory(in: root, fileManager: fileManager)
        let key = partialKey(for: url)
        return partialURLs(prefix: partialPrefix, key: key, directory: directory)
    }

    private static func partialURLs(
        prefix: String,
        key: String,
        directory: URL
    ) -> (partial: URL, sidecar: URL) {
        (
            directory.appendingPathComponent("\(prefix)\(key).bin"),
            directory.appendingPathComponent("\(prefix)\(key).json")
        )
    }

    private static func partialKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isPartialSidecar(_ url: URL) -> Bool {
        guard url.pathExtension == "json" else { return false }
        return partialKey(fromStem: url.deletingPathExtension().lastPathComponent) != nil
    }

    private static func partialKey(fromStem stem: String) -> String? {
        guard stem.hasPrefix(partialPrefix) else { return nil }
        return String(stem.dropFirst(partialPrefix.count))
    }

    private static func loadChunkedState(
        partialURL: URL,
        sidecarURL: URL,
        sourceURL: URL,
        fileManager: FileManager
    ) -> (SpeechDownloadChunkPlan, PartialSpeechSidecar)? {
        guard fileManager.fileExists(atPath: partialURL.path),
              fileManager.fileExists(atPath: sidecarURL.path),
              let data = try? Data(contentsOf: sidecarURL),
              var sidecar = try? JSONDecoder().decode(PartialSpeechSidecar.self, from: data),
              sidecar.schemaVersion == 2,
              sidecar.url == sourceURL.absoluteString,
              sidecar.totalBytes > 0
        else { return nil }

        let chunkSize = sidecar.chunkSize ?? SpeechDownloadChunkPlan.defaultChunkSize
        var plan = SpeechDownloadChunkPlan(
            totalBytes: sidecar.totalBytes,
            chunkSize: chunkSize,
            doneChunks: Set(sidecar.doneChunks ?? [])
        )
        plan.doneChunks = plan.doneChunks.filter { $0 >= 0 && $0 < plan.chunkCount }
        sidecar.doneChunks = Array(plan.doneChunks).sorted()
        return (plan, sidecar)
    }

    private static func loadSingleStreamState(
        partialURL: URL,
        sidecarURL: URL,
        sourceURL: URL,
        fileManager: FileManager
    ) -> PartialSpeechDownloadState? {
        guard fileManager.fileExists(atPath: partialURL.path),
              fileManager.fileExists(atPath: sidecarURL.path),
              let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(PartialSpeechSidecar.self, from: data),
              sidecar.schemaVersion == nil || sidecar.schemaVersion == 1,
              sidecar.url == sourceURL.absoluteString,
              sidecar.totalBytes > 0
        else { return nil }

        let existingSize = fileSize(at: partialURL, fileManager: fileManager)
        guard existingSize > 0, existingSize < sidecar.totalBytes else {
            discardPartial(partialURL: partialURL, sidecarURL: sidecarURL, fileManager: fileManager)
            return nil
        }

        return PartialSpeechDownloadState(
            existingSize: existingSize,
            totalBytes: sidecar.totalBytes,
            etag: sidecar.etag,
            lastModified: sidecar.lastModified
        )
    }

    private static func writeSingleStreamSidecar(
        to url: URL,
        sourceURL: URL,
        totalBytes: Int64,
        etag: String?,
        lastModified: String?,
        displayName: String?
    ) {
        let sidecar = PartialSpeechSidecar(
            url: sourceURL.absoluteString,
            etag: etag,
            lastModified: lastModified,
            totalBytes: totalBytes,
            displayName: displayName,
            schemaVersion: 1,
            chunkSize: nil,
            doneChunks: nil
        )
        writeSidecarValue(sidecar, to: url)
    }

    private static func writeSidecarValue(_ sidecar: PartialSpeechSidecar, to url: URL) {
        if let data = try? JSONEncoder().encode(sidecar) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func discardPartial(
        partialURL: URL,
        sidecarURL: URL,
        fileManager: FileManager
    ) {
        try? fileManager.removeItem(at: partialURL)
        try? fileManager.removeItem(at: sidecarURL)
    }

    private static func matchingPartialFile(
        stem: String,
        in partialsRoot: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: partialsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries.first {
            $0.deletingPathExtension().lastPathComponent == stem && $0.pathExtension != "json"
        }
    }

    private static func bytesOnDisk(
        for sidecar: PartialSpeechSidecar,
        partialURL: URL,
        fileManager: FileManager
    ) -> Int64 {
        if sidecar.schemaVersion == 2,
           let chunkSize = sidecar.chunkSize,
           let doneChunks = sidecar.doneChunks {
            var plan = SpeechDownloadChunkPlan(
                totalBytes: sidecar.totalBytes,
                chunkSize: chunkSize,
                doneChunks: Set(doneChunks)
            )
            plan.doneChunks = plan.doneChunks.filter { $0 >= 0 && $0 < plan.chunkCount }
            return plan.completedBytes()
        }
        return fileSize(at: partialURL, fileManager: fileManager)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let value = try? fileManager
            .attributesOfItem(atPath: url.path)[.size]
        else { return 0 }

        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let size = value as? Int64 {
            return size
        }
        if let size = value as? UInt64 {
            return Int64(size)
        }
        if let size = value as? Int {
            return Int64(size)
        }
        return 0
    }

    private static func updateHasher(_ hasher: inout SHA256, withPrefixOf url: URL, byteCount: Int64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var remaining = byteCount
        while remaining > 0 {
            let count = Int(min(Int64(1 << 20), remaining))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
    }

    private static func emitProgressIfNeeded(
        received: Int64,
        total: Int64,
        started: Date,
        lastEmit: inout Date,
        onProgress: @escaping @Sendable (SpeechDownloadProgress) -> Void
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.25 else { return }
        lastEmit = now
        let elapsed = now.timeIntervalSince(started)
        let bytesPerSecond = elapsed > 0 ? Double(received) / elapsed : 0
        onProgress(SpeechDownloadProgress(bytesReceived: received, totalBytes: total, bytesPerSecond: bytesPerSecond))
    }

    private static func verifyFinalHash(at url: URL, expected: String?) throws -> String {
        let actual = try computeSHA256(at: url)
        if let expected = expected?.lowercased(),
           !expected.isEmpty,
           expected != actual.lowercased() {
            throw SpeechModelDownloaderError.hashMismatch(expected: expected, actual: actual)
        }
        return actual
    }

    private static func computeSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func parseContentRangeTotal(_ response: HTTPURLResponse) -> Int64? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = header.lastIndex(of: "/")
        else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    private static func parseHFCoords(from url: URL) -> (repo: String, filename: String)? {
        guard url.host()?.contains("huggingface.co") == true else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5,
              parts[2] == "resolve" || parts[2] == "blob"
        else { return nil }
        return ("\(parts[0])/\(parts[1])", parts.suffix(from: 4).joined(separator: "/"))
    }
}

public struct HuggingFaceSpeechModelURL: Hashable, Sendable {
    public var repo: String
    public var filename: String

    public init(repo: String, filename: String) {
        self.repo = repo
        self.filename = filename
    }

    public static func parse(_ rawValue: String) -> HuggingFaceSpeechModelURL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let host = url.host(),
           host.contains("huggingface.co") {
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 5,
                  let markerIndex = components.firstIndex(where: { $0 == "resolve" || $0 == "blob" }),
                  markerIndex >= 2,
                  markerIndex + 2 < components.count
            else { return nil }
            let repo = components[0..<markerIndex].joined(separator: "/")
            let filename = components[(markerIndex + 2)...].joined(separator: "/")
            guard filename.lowercased().hasSuffix(".bin") else { return nil }
            return HuggingFaceSpeechModelURL(repo: repo, filename: filename)
        }

        let pieces = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard pieces.count >= 3 else { return nil }
        let repo = pieces[0...1].joined(separator: "/")
        let filename = pieces[2...].joined(separator: "/")
        guard filename.lowercased().hasSuffix(".bin") else { return nil }
        return HuggingFaceSpeechModelURL(repo: repo, filename: filename)
    }
}
