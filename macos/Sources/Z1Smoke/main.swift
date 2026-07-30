import Foundation
import Z1Core

// Hardware smoke test: scan -> connect -> unlock -> session init -> optionally
// observe one telemetry frame -> disconnect. NEVER moves the belt (no FTMS
// control point writes of any kind).
//
// Usage: z1smoke [telemetry-wait-seconds]   (default 8)

let waitSeconds: TimeInterval = CommandLine.arguments.count > 1
    ? (TimeInterval(CommandLine.arguments[1]) ?? 8)
    : 8

print("Z1 smoke test — no belt movement will be commanded.")
print("Scanning for \(Z1Constants.deviceNamePrefix)* …")

let treadmill = Z1Treadmill()

do {
    try await treadmill.connect()
} catch {
    fputs("FAIL: connect: \(error.localizedDescription)\n", stderr)
    exit(1)
}

var status = await treadmill.status
print("OK: connected + unlocked to \(status.deviceName ?? "?")")
print("    speed range: \(status.minSpeedKmh)–\(status.maxSpeedKmh) km/h")
if status.properties.isEmpty {
    print("    properties: (SETTING_GET returned nothing — pad still usable)")
} else {
    let props = status.properties
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=0x\(String($0.value, radix: 16))" }
        .joined(separator: " ")
    print("    properties: \(props)")
}

print("Waiting up to \(Int(waitSeconds))s for one telemetry frame (belt may be idle)…")
let gotFrame = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
        for await s in treadmill.statusUpdates where s.hasTelemetry {
            return true
        }
        return false
    }
    group.addTask {
        try? await Task.sleep(for: .seconds(waitSeconds))
        return false
    }
    let result = await group.next() ?? false
    group.cancelAll()
    return result
}

if gotFrame {
    status = await treadmill.status
    print("OK: telemetry frame — speed \(status.speedKmh) km/h, "
        + "elapsed \(status.elapsedS)s, distance \(status.distanceM)m, steps \(status.steps)")
} else {
    print("OK: no telemetry within \(Int(waitSeconds))s (belt idle — expected when not walking)")
}

await treadmill.disconnect()
print("OK: disconnected cleanly")
