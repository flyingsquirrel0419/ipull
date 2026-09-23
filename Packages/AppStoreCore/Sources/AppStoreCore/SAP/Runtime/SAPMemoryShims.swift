import Foundation

/// Guest heap for the SAP runtime: malloc/calloc/realloc/free plus the
/// mem*/str* family, backed by a mapped region in the emulator with a
/// free-list allocator. Behavior modeled after ipatool's shim_memory.go
/// (MIT).
extension SAPShims {

    static let heapBase: UInt64 = 0x0000400000000000
    static let heapSize: UInt64 = 64 << 20
    static let maxGuestTransfer: UInt64 = 64 << 20

    struct GuestAllocation {
        var size: UInt64
        var reserved: UInt64
    }

    struct FreeBlock {
        var address: UInt64
        var size: UInt64
    }

    // Heap allocator state lives in SAPShims via associated storage — kept
    // as instance members declared here through a secondary class to avoid
    // stored properties in extensions.
    final class HeapState {
        var allocations: [UInt64: GuestAllocation] = [:]
        var freeBlocks: [FreeBlock] = []
        var cursor: UInt64 = 0
    }

    func registerMemoryServices(heap: HeapState) throws {
        try register(names: ["_malloc"]) { shims in
            let size = try shims.argument(0)
            try shims.setReturn(shims.allocate(size, heap: heap))
        }
        try register(names: ["_malloc_good_size"]) { shims in
            let size = try shims.argument(0)
            try shims.setReturn(Self.align(max(size, 1), to: 16))
        }
        try register(names: ["_malloc_size"]) { shims in
            let address = try shims.argument(0)
            try shims.setReturn(heap.allocations[address]?.reserved ?? 0)
        }
        try register(names: ["_calloc"]) { shims in
            let count = try shims.argument(0)
            let size = try shims.argument(1)
            if count != 0 && size > UInt64.max / count {
                throw Error.dispatchFailed("calloc overflow")
            }
            let total = count * size
            let address = try shims.allocate(total, heap: heap)
            if total != 0 {
                try shims.engine.write(address: address, data: Data(count: Int(total)))
            }
            try shims.setReturn(address)
        }
        try register(names: ["_realloc", "_reallocf"]) { shims in
            let oldAddress = try shims.argument(0)
            let newSize = try shims.argument(1)

            if oldAddress == 0 {
                try shims.setReturn(shims.allocate(newSize, heap: heap))
                return
            }
            guard let old = heap.allocations[oldAddress] else {
                throw Error.dispatchFailed("realloc unknown pointer")
            }
            if newSize <= old.reserved {
                heap.allocations[oldAddress] = GuestAllocation(size: newSize, reserved: old.reserved)
                try shims.setReturn(oldAddress)
                return
            }
            let newAddress = try shims.allocate(newSize, heap: heap)
            let data = try shims.engine.read(address: oldAddress, size: Int(old.size))
            try shims.engine.write(address: newAddress, data: data)
            try shims.release(oldAddress, heap: heap)
            try shims.setReturn(newAddress)
        }
        try register(names: ["_free"]) { shims in
            let address = try shims.argument(0)
            if address != 0 {
                try shims.release(address, heap: heap)
            }
            try shims.setReturn(0)
        }

        // mem*/str* family
        try register(names: ["_memcpy", "_memmove"]) { shims in
            let dest = try shims.argument(0)
            let src = try shims.argument(1)
            let count = try shims.argument(2)
            let data = try shims.engine.read(address: src, size: Int(count))
            try shims.engine.write(address: dest, data: data)
            try shims.setReturn(dest)
        }
        try register(names: ["_memset"]) { shims in
            let dest = try shims.argument(0)
            let value = try shims.argument(1)
            let count = try shims.argument(2)
            try shims.engine.write(address: dest, data: Data(repeating: UInt8(value & 0xFF), count: Int(count)))
            try shims.setReturn(dest)
        }
        try register(names: ["___bzero"]) { shims in
            let dest = try shims.argument(0)
            let count = try shims.argument(1)
            try shims.engine.write(address: dest, data: Data(count: Int(count)))
            try shims.setReturn(0)
        }
        try register(names: ["_memcmp"]) { shims in
            let a = try shims.argument(0)
            let b = try shims.argument(1)
            let count = Int(try shims.argument(2))
            let dataA = try shims.engine.read(address: a, size: count)
            let dataB = try shims.engine.read(address: b, size: count)
            var result: Int32 = 0
            for i in 0..<count where result == 0 {
                result = Int32(dataA[i]) - Int32(dataB[i])
            }
            try shims.setReturn(UInt64(bitPattern: Int64(result)))
        }
        try register(names: ["_strlen"]) { shims in
            let address = try shims.argument(0)
            var length: UInt64 = 0
            while true {
                let byte = try shims.engine.read(address: address + length, size: 1)
                if byte[0] == 0 { break }
                length += 1
            }
            try shims.setReturn(length)
        }
        try register(names: ["_strcmp", "_strncmp"]) { shims in
            let a = try shims.readGuestString(at: try shims.argument(0))
            let b = try shims.readGuestString(at: try shims.argument(1))
            let result: Int64 = a == b ? 0 : (a < b ? -1 : 1)
            try shims.setReturn(UInt64(bitPattern: result))
        }
    }

    // MARK: - Allocator

    static func align(_ value: UInt64, to alignment: UInt64) -> UInt64 {
        (value + alignment - 1) & ~(alignment - 1)
    }

    func allocate(_ size: UInt64, heap: HeapState) throws -> UInt64 {
        guard size <= Self.maxGuestTransfer else {
            throw Error.dispatchFailed("allocation exceeds limit")
        }
        let reserved = Self.align(max(size, 1), to: 16)

        for (index, block) in heap.freeBlocks.enumerated() where block.size >= reserved {
            let address = block.address
            if block.size == reserved {
                heap.freeBlocks.remove(at: index)
            } else {
                heap.freeBlocks[index] = FreeBlock(address: block.address + reserved,
                                                   size: block.size - reserved)
            }
            heap.allocations[address] = GuestAllocation(size: size, reserved: reserved)
            return address
        }

        guard heap.cursor + reserved <= Self.heapSize else {
            throw Error.dispatchFailed("guest heap exhausted")
        }
        let address = Self.heapBase + heap.cursor
        heap.cursor += reserved
        heap.allocations[address] = GuestAllocation(size: size, reserved: reserved)
        return address
    }

    func release(_ address: UInt64, heap: HeapState) throws {
        guard let allocation = heap.allocations[address] else {
            throw Error.dispatchFailed("free unknown pointer")
        }
        try engine.write(address: address, data: Data(count: Int(allocation.reserved)))
        heap.allocations.removeValue(forKey: address)
        heap.freeBlocks.append(FreeBlock(address: address, size: allocation.reserved))
        heap.freeBlocks.sort { $0.address < $1.address }
        // Coalesce adjacent blocks
        var merged: [FreeBlock] = []
        for block in heap.freeBlocks {
            if let last = merged.last, last.address + last.size == block.address {
                merged[merged.count - 1] = FreeBlock(address: last.address, size: last.size + block.size)
            } else {
                merged.append(block)
            }
        }
        heap.freeBlocks = merged
    }
}
