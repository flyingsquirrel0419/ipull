import Foundation
import CUnicorn

/// Swift wrapper over the CUnicorn ABI — an x86-64 emulator session with
/// mapped memory, registers, and code hooks. Used by the SAP runtime to
/// execute Apple's signing binary under emulation on non-jailbroken iOS
/// (Unicorn is built in TCG interpreter mode: no executable memory, so it
/// runs under LiveContainer without JIT).
public final class UnicornEngine {

    public enum Error: Swift.Error, Equatable {
        case openFailed(String)
        case memMapFailed(String)
        case memWriteFailed(String)
        case memReadFailed(String)
        case regAccessFailed(String)
        case emuFailed(String)
        case hookFailed(String)
    }

    public enum Register: Int32 {
        case rax = 35, rbx = 36, rcx = 38, rdi = 39, rdx = 40
        case rip = 41, rsi = 43, rsp = 44
        case r8 = 106, r9 = 107
    }

    private var engine: UnsafeMutableRawPointer?

    public init() throws {
        var handle: UnsafeMutableRawPointer?
        let status = cu_open(&handle)
        guard status == 0, let handle else {
            throw Error.openFailed(Self.describe(status))
        }
        self.engine = handle
    }

    deinit {
        if let engine { cu_close(engine) }
    }

    // MARK: - Memory

    public func map(address: UInt64, size: UInt64) throws {
        let status = cu_mem_map(engine, address, size)
        guard status == 0 else { throw Error.memMapFailed(Self.describe(status)) }
    }

    public func write(address: UInt64, data: Data) throws {
        let status = data.withUnsafeBytes { ptr -> Int32 in
            cu_mem_write(engine, address, ptr.baseAddress, ptr.count)
        }
        guard status == 0 else { throw Error.memWriteFailed(Self.describe(status)) }
    }

    public func read(address: UInt64, size: Int) throws -> Data {
        var out = Data(count: size)
        let status = out.withUnsafeMutableBytes { ptr -> Int32 in
            cu_mem_read(engine, address, ptr.baseAddress, ptr.count)
        }
        guard status == 0 else { throw Error.memReadFailed(Self.describe(status)) }
        return out
    }

    // MARK: - Registers

    public func write(_ register: Register, _ value: UInt64) throws {
        let status = cu_reg_write(engine, register.rawValue, value)
        guard status == 0 else { throw Error.regAccessFailed(Self.describe(status)) }
    }

    public func read(_ register: Register) throws -> UInt64 {
        var value: UInt64 = 0
        let status = cu_reg_read(engine, register.rawValue, &value)
        guard status == 0 else { throw Error.regAccessFailed(Self.describe(status)) }
        return value
    }

    // MARK: - Execution

    public func run(from begin: UInt64, until: UInt64,
                    timeoutMicroseconds: UInt64 = 60_000_000,
                    instructionCount: Int = 0) throws {
        let status = cu_emu_start(engine, begin, until, timeoutMicroseconds, instructionCount)
        guard status == 0 else { throw Error.emuFailed(Self.describe(status)) }
    }

    public func stop() {
        cu_emu_stop(engine)
    }

    // MARK: - Code hooks

    public typealias CodeHook = @convention(c) (UInt64, UInt32, UnsafeMutableRawPointer?) -> Void

    public func addCodeHook(begin: UInt64, end: UInt64,
                            callback: CodeHook, userData: UnsafeMutableRawPointer?) throws -> UInt64 {
        var hookID: UInt64 = 0
        let status = cu_hook_add_code(engine, callback, begin, end, userData, &hookID)
        guard status == 0 else { throw Error.hookFailed(Self.describe(status)) }
        return hookID
    }

    public func removeHook(_ hookID: UInt64) {
        cu_hook_del(engine, hookID)
    }

    public typealias InvalidMemHook = @convention(c) (UInt64, UInt32, Int32, UnsafeMutableRawPointer?) -> Int32

    /// Hook unmapped memory accesses. Return 1 to continue past the fault.
    public func addInvalidMemHook(callback: InvalidMemHook, userData: UnsafeMutableRawPointer?) throws -> UInt64 {
        var hookID: UInt64 = 0
        let status = cu_hook_add_invalid_mem(engine, callback, userData, &hookID)
        guard status == 0 else { throw Error.hookFailed(Self.describe(status)) }
        return hookID
    }

    // MARK: - Helpers

    private static func describe(_ status: Int32) -> String {
        String(cString: cu_strerror(status))
    }
}
