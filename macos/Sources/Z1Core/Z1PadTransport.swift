import CoreBluetooth
import Foundation

/// The BLE boundary used by the driver. Tests can provide a scripted transport
/// without creating a CoreBluetooth central or touching the real treadmill.
public protocol Z1PadTransport: AnyObject, Sendable {
    var notifications: AsyncStream<(String, Data)> { get }
    var onDisconnect: (@Sendable () -> Void)? { get set }
    var peripheralIdentifier: UUID? { get }

    func waitPoweredOn() async throws
    func adoptKnownPeripheral(identifier: UUID, namePrefix: String) -> String?
    func scanForTreadmill(timeout: TimeInterval) async throws -> String
    func connect(timeout: TimeInterval) async throws
    func discoverProfile(services: [CBUUID], characteristics: [CBUUID]) async throws
    func hasCharacteristic(_ uuid: CBUUID) -> Bool
    func setNotify(_ uuid: CBUUID, enable: Bool) async throws
    func read(_ uuid: CBUUID) async throws -> Data
    func write(_ uuid: CBUUID, _ data: Data, withResponse: Bool) async throws
    func disconnect() async
    func cancelConnectionNow()
}
