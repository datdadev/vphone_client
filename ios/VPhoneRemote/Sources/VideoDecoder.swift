import AVFoundation
import CoreMedia
import Foundation

/// Reassembles the host's HEVC packets into CMSampleBuffers for hardware decode.
///
/// Wire format (one WS binary message per packet): `[1-byte type][payload]`
/// where 1 = parameter sets, 2 = keyframe, 3 = delta frame. Frame payloads are
/// AVCC (length-prefixed NALUs) exactly as VideoToolbox emitted them, so they
/// need no Annex-B conversion -- just a format description built from the
/// parameter sets.
final class VideoDecoder {
    enum PacketType: UInt8 {
        case parameterSets = 1
        case keyFrame = 2
        case deltaFrame = 3
    }

    private var formatDescription: CMFormatDescription?
    /// Delta frames are undecodable until a keyframe establishes a reference.
    private var awaitingKeyFrame = true

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Host capture time of the most recent frame (ms since epoch).
    var onCaptureTimestamp: ((UInt64) -> Void)?
    /// Frames went missing downstream -- the decoder now has no valid reference
    /// and needs a keyframe, or the picture stays frozen until the next
    /// periodic one.
    var onFrameGap: (() -> Void)?

    private var lastSequence: UInt32?

    func handlePacket(_ data: Data) {
        // [1-byte type][8-byte BE capture ms][4-byte BE sequence][payload]
        guard data.count > 13, let first = data.first,
              let type = PacketType(rawValue: first)
        else { return }

        let base = data.startIndex
        let captureMs = data[(base + 1)..<(base + 9)]
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let sequence = data[(base + 9)..<(base + 13)]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        onCaptureTimestamp?(captureMs)

        if type != .parameterSets {
            if let last = lastSequence, sequence != last &+ 1, sequence > last {
                // Something upstream dropped frames. Decoding onward from here
                // produces artefacts, so wait for a keyframe and ask for one.
                awaitingKeyFrame = true
                onFrameGap?()
            }
            lastSequence = sequence
        }

        let payload = Data(data[(base + 13)...])

        switch type {
        case .parameterSets:
            buildFormatDescription(from: payload)
        case .keyFrame, .deltaFrame:
            if type == .keyFrame { awaitingKeyFrame = false }
            guard !awaitingKeyFrame else { return }
            decode(payload)
        }
    }

    func reset() {
        formatDescription = nil
        awaitingKeyFrame = true
        lastSequence = nil
    }

    /// `[1-byte count][ per set: 4-byte BE length + bytes ]`
    private func buildFormatDescription(from data: Data) {
        var cursor = data.startIndex
        guard cursor < data.endIndex else { return }
        let count = Int(data[cursor])
        cursor += 1

        var sets: [[UInt8]] = []
        for _ in 0..<count {
            guard cursor + 4 <= data.endIndex else { return }
            let length = data[cursor..<cursor + 4].reduce(0) { ($0 << 8) | UInt32($1) }
            cursor += 4
            let end = cursor + Int(length)
            guard end <= data.endIndex else { return }
            sets.append([UInt8](data[cursor..<end]))
            cursor = end
        }
        guard sets.count == count, count > 0 else { return }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        // Keep the buffers alive across the create call.
        let storage = sets.map { UnsafeMutablePointer<UInt8>.allocate(capacity: $0.count) }
        defer { storage.forEach { $0.deallocate() } }
        for (index, set) in sets.enumerated() {
            storage[index].update(from: set, count: set.count)
            pointers.append(UnsafePointer(storage[index]))
            sizes.append(set.count)
        }

        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { return }

        formatDescription = format
        awaitingKeyFrame = true
    }

    private func decode(_ frameData: Data) {
        guard let formatDescription else { return }

        var blockBuffer: CMBlockBuffer?
        var mutableData = frameData
        let dataLength = mutableData.count

        let status = mutableData.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: base,
                blockLength: dataLength,
                blockAllocator: kCFAllocatorNull, // data is copied below before escaping
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataLength,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == noErr, let sourceBuffer = blockBuffer else { return }

        // The block above borrows `mutableData`'s storage, which dies with this
        // scope -- copy into a buffer that owns its memory before handing it off.
        var ownedBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(
            allocator: kCFAllocatorDefault,
            sourceBuffer: sourceBuffer,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: kCMBlockBufferAlwaysCopyDataFlag,
            blockBufferOut: &ownedBuffer
        ) == noErr, let ownedBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: ownedBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        // No timeline/clock: render each frame the moment it arrives, which is
        // what we want for interactive remote control.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        onSampleBuffer?(sampleBuffer)
    }
}
