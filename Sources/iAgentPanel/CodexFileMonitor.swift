import Darwin
import Foundation

final class CodexFileMonitor: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.openai.iagent.file-monitor", qos: .utility)
  private var sources: [DispatchSourceFileSystemObject] = []
  private var watchedPaths = Set<String>()

  func update(paths: [String], onChange: @escaping @Sendable () -> Void) {
    let existingPaths = Set(paths.filter { FileManager.default.fileExists(atPath: $0) })

    lock.lock()
    guard existingPaths != watchedPaths else {
      lock.unlock()
      return
    }

    sources.forEach { $0.cancel() }
    sources.removeAll()
    watchedPaths = existingPaths

    for path in existingPaths {
      let descriptor = open(path, O_EVTONLY)
      guard descriptor >= 0 else { continue }

      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .extend, .attrib, .rename, .delete],
        queue: queue
      )
      source.setEventHandler(handler: onChange)
      source.setCancelHandler {
        close(descriptor)
      }
      source.resume()
      sources.append(source)
    }
    lock.unlock()
  }

  func stop() {
    lock.lock()
    sources.forEach { $0.cancel() }
    sources.removeAll()
    watchedPaths.removeAll()
    lock.unlock()
  }

  deinit {
    stop()
  }
}
