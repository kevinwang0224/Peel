import Darwin
import Foundation

public enum ExtractionError: Error, LocalizedError, Equatable {
  case timedOut, outputTooLarge, helperFailed
  public var errorDescription: String? {
    switch self {
    case .timedOut: return "Extraction timed out."
    case .outputTooLarge: return "Extraction result exceeds 16 MB."
    case .helperFailed: return "Extraction helper failed."
    }
  }
}

/// Each evaluation owns a disposable process. Cancellation kills and reaps it,
/// including scripts that never return from JavaScriptCore.
public struct ExtractionRunner: Sendable {
  public let executable: URL
  public init(executable: URL) { self.executable = executable }
  public func run(_ request: ExtractionRequest, timeout: TimeInterval = 1.2) async throws
    -> ExtractionResult
  {
    try await ScriptLimiter.shared.acquire()
    do {
      let value = try await evaluate(request, timeout: timeout)
      await ScriptLimiter.shared.release()
      return value
    } catch {
      await ScriptLimiter.shared.release()
      throw error
    }
  }
  private func evaluate(_ request: ExtractionRequest, timeout: TimeInterval) async throws
    -> ExtractionResult
  {
    let execution = ScriptExecution()
    let payload = try JSONEncoder().encode(request)
    return try await withTaskCancellationHandler(
      operation: {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(
              with: Result {
                try execution.evaluate(executable: executable, payload: payload, timeout: timeout)
              })
          }
        }
      }, onCancel: { execution.stop(CancellationError()) })
  }
}

private final class ScriptExecution: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var stopped: Error?
  func stop(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    if stopped == nil { stopped = error }
    if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
  func evaluate(executable: URL, payload: Data, timeout: TimeInterval) throws -> ExtractionResult {
    let child = Process()
    let input = Pipe()
    let output = Pipe()
    child.executableURL = executable
    child.standardInput = input
    child.standardOutput = output
    child.standardError = FileHandle.nullDevice
    lock.lock()
    if let stopped {
      lock.unlock()
      throw stopped
    }
    process = child
    do { try child.run() } catch {
      process = nil
      lock.unlock()
      throw error
    }
    lock.unlock()
    // No browser APIs, file or application objects are bridged into the JS context.
    let deadline = DispatchWorkItem { [weak self] in self?.stop(ExtractionError.timedOut) }
    DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout), execute: deadline)
    defer {
      deadline.cancel()
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
      lock.lock()
      if child.isRunning { kill(child.processIdentifier, SIGKILL) }
      lock.unlock()
      child.waitUntilExit()
      lock.lock()
      process = nil
      lock.unlock()
    }
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    var response = Data()
    do {
      try input.fileHandleForWriting.write(contentsOf: payload)
      try input.fileHandleForWriting.close()
      while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
        response.append(chunk)
        if response.count > 16 * 1024 * 1024 {
          stop(ExtractionError.outputTooLarge)
          break
        }
      }
    } catch {
      lock.lock()
      let reason = stopped
      lock.unlock()
      throw reason ?? error
    }
    child.waitUntilExit()
    lock.lock()
    let reason = stopped
    process = nil
    lock.unlock()
    if let reason { throw reason }
    guard child.terminationStatus == 0, !response.isEmpty else {
      throw ExtractionError.helperFailed
    }
    return try JSONDecoder().decode(ExtractionResult.self, from: response)
  }
}

private actor ScriptLimiter {
  static let shared = ScriptLimiter()
  private var active = 0
  func acquire() async throws {
    while active >= 2 { try await Task.sleep(for: .milliseconds(10)) }
    try Task.checkCancellation()
    active += 1
  }
  func release() { active -= 1 }
}
