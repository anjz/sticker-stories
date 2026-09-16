import Foundation

/// Persists a canvas snapshot per pack so placed stickers survive leaving the
/// story screen or closing the app. The app implementation writes to disk;
/// tests can use an in-memory one.
public protocol CanvasStateStore: Sendable {
    func load(packID: String) -> CanvasState?
    func save(_ state: CanvasState)
}
