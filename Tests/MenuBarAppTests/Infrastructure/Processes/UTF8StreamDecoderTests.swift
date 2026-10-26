import Foundation
import Testing
@testable import MenuBarApp

struct UTF8StreamDecoderTests {
    @Test func preservesCharactersAcrossEveryReadBoundary() {
        let text = "Olá, 世界 👋\n"
        let bytes = Data(text.utf8)
        for split in 0...bytes.count {
            var decoder = UTF8StreamDecoder()
            let first = decoder.append(bytes.prefix(split))
            let second = decoder.append(bytes.dropFirst(split))
            #expect(first + second + decoder.finish() == text)
        }
        var decoder = UTF8StreamDecoder()
        let pieces = bytes.map { decoder.append(Data([$0])) }.joined()
        #expect(pieces + decoder.finish() == text)
    }

    @Test func repairsInvalidBytesAndFlushesAnUnfinishedCharacter() {
        let bytes = Data([0xFF, 0x80, 0xE0, 0x80, 0x80, 0xF4, 0x90, 0x80, 0x80, 0xE2, 0x82])
        var decoder = UTF8StreamDecoder()
        let text = bytes.map { decoder.append(Data([$0])) }.joined() + decoder.finish()
        #expect(text == String(decoding: bytes, as: UTF8.self))
        #expect(decoder.finish().isEmpty)
    }
}
