//
//  SMCAccess.swift
//  AMD Power Gadget
//
//  Minimal AppleSMC bridge, used only for the fan side of the performance
//  profiles. The CPU side keeps using the existing AMDRyzenCPUPowerManagement
//  IOUserClient (setCPB / setPPM / setLPM), so nothing about the working
//  CPU path changes.
//
//  Reads are always allowed. Writes go through AppleSmcBridge's
//  KERNEL_INDEX_SMC write selector, which requires root: a non-root call
//  returns kIOReturnNotPrivileged and we surface that instead of silently
//  pretending the profile changed.
//

import Foundation
import IOKit

final class SMCAccess {

    static let shared = SMCAccess()

    // AppleSMC user client selectors (see VirtualSMC's AppleSmcBridge.hpp).
    private let kSMCUserClientOpen:    UInt32 = 0
    private let kSMCUserClientClose:   UInt32 = 1
    private let kSMCHandleYPCEvent:    UInt32 = 2
    private let kSMCReadKey:           UInt32 = 5
    private let kSMCWriteKey:          UInt32 = 6

    private let kSMCKeyNotFound: Int32 = -13987

    private var connect: io_connect_t = 0
    private var opened = false

    private init() {}

    // MARK: - connection

    /// Open a connection to AppleSMC. Returns false when AppleSMC is absent
    /// (e.g. no VirtualSMC), in which case callers fall back to "read only".
    @discardableResult
    func open() -> Bool {
        if opened { return true }

        let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        if service == 0 {
            NSLog("SMCAccess: AppleSMC not found")
            return false
        }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connect)
        if kr != KERN_SUCCESS {
            NSLog("SMCAccess: IOServiceOpen failed: %@",
                  String(cString: mach_error_string(kr)))
            return false
        }

        // Not all AppleSMC implementations need this, and a failure here is
        // not fatal; the read/write calls below are what actually matter.
        var dummy: UInt64 = 0
        var dummyCount: UInt64 = 0
        let openKr = IOConnectCallScalarMethod(connect, kSMCUserClientOpen,
                                               nil, 0, &dummy, &dummyCount)
        if openKr != KERN_SUCCESS {
            NSLog("SMCAccess: open selector returned %d (continuing)", openKr)
        }

        opened = true
        return true
    }

    func close() {
        guard opened else { return }
        var dummy: UInt64 = 0
        var dummyCount: UInt64 = 0
        IOConnectCallScalarMethod(connect, kSMCUserClientClose, nil, 0,
                                  &dummy, &dummyCount)
        IOServiceClose(connect)
        connect = 0
        opened = false
    }

    // MARK: - key plumbing

    /// SMC key string -> packed UInt32, the same way SMC_MAKE_IDENTIFIER does it.
    private func keyCode(_ key: String) -> UInt32? {
        guard key.count == 4 else { return nil }
        var v: UInt32 = 0
        for ch in key.utf8 {
            v = (v << 8) | UInt32(ch)
        }
        return v
    }

    /// SMCKeyData_t as used by AppleSMC.
    private struct SMCKeyData {
        struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }
        struct KeyData {
            var key: UInt32 = 0
            var vers: UInt8 = 0
            var pLimit: UInt16 = 0
            var lTotal: UInt16 = 0
            var result: UInt8 = 0
            var status: UInt8 = 0
            var data8: UInt8 = 0
            var data32: UInt32 = 0
            var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
                 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
        }
    }

    /// Read the 4-char type of a key ("ui8 ", "fpe2", ...). nil if absent.
    func keyType(_ key: String) -> String? {
        guard opened || open(), let code = keyCode(key) else { return nil }

        var input = SMCKeyData()
        input.key = code
        input.data8 = 9   // kSMCGetKeyInfo

        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let kr = withUnsafePointer(to: &input) { inPtr in
            inPtr.withMemoryRebound(to: UInt8.self, capacity: 1) { ptr in
                IOConnectCallStructMethod(connect, kSMCHandleYPCEvent,
                                          ptr, MemoryLayout<SMCKeyData>.stride,
                                          &output, &outputSize)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var t = output.keyInfo.dataType
        var s = ""
        for _ in 0..<4 {
            let c = Character(UnicodeScalar(UInt8(t >> 24)) )
            s.append(c)
            t <<= 8
        }
        return s
    }

    /// Raw bytes of a key, up to 32.
    func readBytes(_ key: String) -> [UInt8]? {
        guard opened || open(), let code = keyCode(key) else { return nil }

        var info = SMCKeyData()
        info.key = code
        info.data8 = 9
        var infoOut = SMCKeyData()
        var infoSize = MemoryLayout<SMCKeyData>.stride

        let infoKr = withUnsafePointer(to: &info) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: 1) {
                IOConnectCallStructMethod(connect, kSMCHandleYPCEvent,
                                          $0, MemoryLayout<SMCKeyData>.stride,
                                          &infoOut, &infoSize)
            }
        }
        guard infoKr == KERN_SUCCESS, infoOut.keyInfo.dataSize > 0 else { return nil }

        var req = SMCKeyData()
        req.key = code
        req.data8 = 5   // kSMCReadKey
        var out = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride

        let kr = withUnsafePointer(to: &req) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: 1) {
                IOConnectCallStructMethod(connect, kSMCHandleYPCEvent,
                                          $0, MemoryLayout<SMCKeyData>.stride,
                                          &out, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        // The byte tuple is laid out contiguously; copy the used prefix.
        let n = Int(min(infoOut.keyInfo.dataSize, 32))
        return withUnsafeBytes(of: out.bytes) { raw in
            Array(raw.prefix(n))
        }
    }

    /// Write up to 32 bytes. Returns a KERN_* result so the UI can explain a
    /// permission problem rather than silently dropping the write.
    ///
    /// Note: writing SMC keys requires root. A non-root write returns
    /// kIOReturnNotPrivileged and the caller surfaces that to the user
    /// instead of pretending the profile changed.
    func writeBytes(_ key: String, bytes: [UInt8]) -> kern_return_t {
        guard opened || open() else { return kIOReturnNotOpen }
        guard let code = keyCode(key), !bytes.isEmpty, bytes.count <= 32 else {
            return kIOReturnBadArgument
        }

        var req = SMCKeyData()
        req.key = code
        req.data8 = 6   // kSMCWriteKey
        req.keyInfo.dataSize = UInt32(bytes.count)
        req.keyInfo.dataType = 0

        withUnsafeMutableBytes(of: &req.bytes) { raw in
            for (i, b) in bytes.enumerated() where i < 32 {
                raw[i] = b
            }
        }

        var out = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = withUnsafePointer(to: &req) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: 1) {
                IOConnectCallStructMethod(connect, kSMCHandleYPCEvent,
                                          $0, MemoryLayout<SMCKeyData>.stride,
                                          &out, &outSize)
            }
        }
        return kr
    }

    // MARK: - typed helpers

    /// fpe2 is fixed point with 4 steps per RPM: stored = RPM * 4.
    func readFanRPM(_ key: String) -> Int? {
        guard let b = readBytes(key), b.count >= 2 else { return nil }
        return Int(b[0]) * 64 + Int(b[1]) / 4
    }

    /// ui8 key (plain 0-255 value).
    func readUInt8(_ key: String) -> Int? {
        guard let b = readBytes(key), let first = b.first else { return nil }
        return Int(first)
    }
}
