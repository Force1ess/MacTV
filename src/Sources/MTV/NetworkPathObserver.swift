import Foundation
import Network

final class NetworkPathObserver {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "local.mtv.preview.network-path")
  func start(_ update: @escaping @Sendable (Bool) -> Void) {
    monitor.pathUpdateHandler = { update($0.status == .satisfied) }
    monitor.start(queue: queue)
  }
  func stop() { monitor.cancel() }
}
