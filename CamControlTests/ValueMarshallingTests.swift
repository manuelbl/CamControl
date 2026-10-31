//
//  ValueMarshallingTests.swift
//  Tests for converting control values to and from their little-endian wire format,
//  and for packing the two Pan/Tilt axes into one SInt32 tuple.
//

import Testing

struct ValueMarshallingTests {
    // MARK: - Encode

    @Test func encodesToByteCountBytes() {
        #expect(VideoControlDataType.uInt8.encode(0x7f) == [0x7f])
        #expect(VideoControlDataType.boolean.encode(1) == [0x01])
        #expect(VideoControlDataType.uInt16.encode(6500) == [0x64, 0x19])
        #expect(VideoControlDataType.sInt16.encode(-1) == [0xff, 0xff])
        #expect(VideoControlDataType.sInt16.encode(-64) == [0xc0, 0xff])
    }

    @Test func encodesTupleAsTwoLittleEndianWords() {
        // pan = -36000 (0xffff7360), tilt = 7200 (0x00001c20)
        let tuple = VideoControlDataType.compose(
            into: VideoControlDataType.compose(into: 0, axis: 0, value: -36000), axis: 1, value: 7200)
        #expect(VideoControlDataType.sInt32Tuple.encode(tuple)
                == [0x60, 0x73, 0xff, 0xff, 0x20, 0x1c, 0x00, 0x00])
    }

    // MARK: - Decode

    @Test func decodesUnsignedTypesWithoutSignExtension() {
        #expect(VideoControlDataType.uInt8.decode([0xff]) == 255)
        #expect(VideoControlDataType.boolean.decode([0x01]) == 1)
        #expect(VideoControlDataType.uInt16.decode([0xff, 0xff]) == 65535)
        #expect(VideoControlDataType.uInt16.decode([0x64, 0x19]) == 6500)
    }

    @Test func decodesSInt16WithSignExtension() {
        #expect(VideoControlDataType.sInt16.decode([0xff, 0xff]) == -1)
        #expect(VideoControlDataType.sInt16.decode([0x00, 0x80]) == -32768)
        #expect(VideoControlDataType.sInt16.decode([0xff, 0x7f]) == 32767)
    }

    @Test func decodesTuple() {
        let tuple = VideoControlDataType.sInt32Tuple.decode([0x60, 0x73, 0xff, 0xff, 0x20, 0x1c, 0x00, 0x00])
        #expect(VideoControlDataType.decompose(tuple: tuple, axis: 0) == -36000)
        #expect(VideoControlDataType.decompose(tuple: tuple, axis: 1) == 7200)
    }

    @Test(arguments: [
        (VideoControlDataType.uInt8, Int64(200)),
        (.boolean, 1),
        (.uInt16, 65535),
        (.sInt16, -32768),
        (.sInt16, 32767),
        (.sInt32Tuple, Int64(bitPattern: 0x8000_0000_7fff_ffff)),
    ])
    func roundTrips(_ dataType: VideoControlDataType, _ value: Int64) {
        let data = dataType.encode(value)
        #expect(data.count == dataType.byteCount)
        #expect(dataType.decode(data) == value)
    }

    // MARK: - Pan/Tilt tuple

    @Test(arguments: [Int32.min, -36000, -1, 0, 1, 36000, Int32.max])
    func eachAxisRoundTrips(_ value: Int32) {
        for axis in 0...1 {
            let tuple = VideoControlDataType.compose(into: 0, axis: axis, value: value)
            #expect(VideoControlDataType.decompose(tuple: tuple, axis: axis) == value)
        }
    }

    @Test func composingOneAxisPreservesTheOther() {
        // Negative values set every high bit of their word; neither may leak into the other axis.
        var tuple = VideoControlDataType.compose(into: 0, axis: 0, value: -1)
        tuple = VideoControlDataType.compose(into: tuple, axis: 1, value: 7200)
        #expect(VideoControlDataType.decompose(tuple: tuple, axis: 0) == -1)
        tuple = VideoControlDataType.compose(into: tuple, axis: 1, value: -3600)
        tuple = VideoControlDataType.compose(into: tuple, axis: 0, value: 100)
        #expect(VideoControlDataType.decompose(tuple: tuple, axis: 0) == 100)
        #expect(VideoControlDataType.decompose(tuple: tuple, axis: 1) == -3600)
    }

    @Test func panIsTheLowWord() {
        #expect(VideoControlDataType.compose(into: 0, axis: 0, value: 1) == 1)
        #expect(VideoControlDataType.compose(into: 0, axis: 1, value: 1) == 1 << 32)
    }
}
