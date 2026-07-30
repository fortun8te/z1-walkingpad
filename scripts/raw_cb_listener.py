#!/usr/bin/env python3
"""Raw CoreBluetooth listener — bypasses bleak entirely.

Connects to the Z1, enables notifications on ALL notify characteristics,
and prints every single delegate callback for N seconds.
"""

import sys
import time

import objc
from CoreBluetooth import (
    CBCentralManager, CBUUID, CBManagerAuthorizationAllowedAlways,
)
from Foundation import NSObject, NSRunLoop, NSDate

PERIPHERAL_UUID = "1DC6DC0D-BADF-6C1B-453D-A2DD53A298D2"
LISTEN_SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0

manager_holder = {}
peripheral_holder = {}


class CentralDelegate(NSObject):
    def centralManagerDidUpdateState_(self, central):
        print(f"central state: {central.state()}", flush=True)
        if central.state() == 5:  # poweredOn
            periphs = central.retrievePeripheralsWithIdentifiers_([objc.lookUpClass("NSUUID").alloc().initWithUUIDString_(PERIPHERAL_UUID)])
            if periphs:
                p = periphs[0]
                peripheral_holder["p"] = p
                print(f"connecting to {p.name()}...", flush=True)
                central.connectPeripheral_options_(p, None)
            else:
                print("peripheral not known to CoreBluetooth yet; scanning...", flush=True)
                central.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, central, p, adv, rssi):
        if p.name() and "KS-HD" in str(p.name()):
            print(f"discovered {p.name()}", flush=True)
            central.stopScan()
            peripheral_holder["p"] = p
            central.connectPeripheral_options_(p, None)

    def centralManager_didConnectPeripheral_(self, central, p):
        print("connected; discovering services...", flush=True)
        peripheral_holder["delegate"] = PeripheralDelegate.alloc().init()
        p.setDelegate_(peripheral_holder["delegate"])
        p.discoverServices_(None)

    def centralManager_didFailToConnectPeripheral_error_(self, central, p, err):
        print(f"connect failed: {err}", flush=True)

    def centralManager_didDisconnectPeripheral_error_(self, central, p, err):
        print(f"disconnected: {err}", flush=True)


class PeripheralDelegate(NSObject):
    def peripheral_didDiscoverServices_(self, p, err):
        print(f'services discovered, err={err}', flush=True)
        for s in p.services() or []:
            print(f"service {s.UUID()}", flush=True)
            p.discoverCharacteristics_forService_(None, s)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, p, s, err):
        print(f'chars for {s.UUID()}, err={err}', flush=True)
        for ch in s.characteristics() or []:
            props = ch.properties()
            if props & 0x10 or props & 0x20:  # notify or indicate
                print(f"enabling notify on {ch.UUID()}", flush=True)
                p.setNotifyValue_forCharacteristic_(True, ch)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, p, ch, err):
        print(f"notify state {ch.UUID()}: {'ON' if ch.isNotifying() else 'OFF'} err={err}", flush=True)

    def peripheral_didUpdateValueForCharacteristic_error_(self, p, ch, err):
        v = ch.value()
        hexstr = bytes(v).hex() if v else None
        print(f"!!! DATA [{ch.UUID()}] {hexstr} err={err}", flush=True)


def main():
    delegate = CentralDelegate.alloc().init()
    central = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)
    manager_holder["c"] = central

    deadline = time.time() + LISTEN_SECONDS
    while time.time() < deadline:
        NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.1))
    print("done", flush=True)


main()
