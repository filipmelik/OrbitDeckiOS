import Testing
import Foundation
@testable import OrbitDeck

// Packet stack: FCS, AX.25, KISS, APRS, and the AFSK 1200 modem end to end.

struct PacketFrameTests {
    @Test func fcsMatchesCRC16X25ReferenceVector() {
        #expect(AX25FCS.compute(Array("123456789".utf8)) == 0x906E)
    }

    @Test func addressParsingAndFormatting() throws {
        let a = try #require(AX25Address("n8hm-7"))
        #expect(a.call == "N8HM" && a.ssid == 7)
        #expect(a.description == "N8HM-7")
        #expect(AX25Address("WIDE2-1*")?.repeated == true)
        #expect(AX25Address("TOOLONGCALL") == nil)
        #expect(AX25Address("N8HM-16") == nil)
    }

    @Test func frameRoundTrip() throws {
        let frame = AX25Frame(destination: AX25Address(call: "APZODK"),
                              source: AX25Address(call: "N8HM", ssid: 9),
                              digipeaters: [AX25Address(call: "ARISS"), AX25Address(call: "WIDE2", ssid: 1, repeated: true)],
                              info: Array("=3854.00N/07702.00W`Test".utf8))
        let decoded = try #require(AX25Frame.decode(frame.encoded()))
        #expect(decoded == frame)
        #expect(decoded.monitorText == "N8HM-9>APZODK,ARISS,WIDE2-1*:=3854.00N/07702.00W`Test")
        #expect(decoded.wasDigipeated)
    }

    @Test func kissEscapesAndStreams() {
        let payload: [UInt8] = [0x01, KISS.fend, 0x02, KISS.fesc, 0x03]
        let wire = KISS.encode(payload)
        #expect(wire == [0xC0, 0x00, 0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03, 0xC0])
        var decoder = KISS.Decoder()
        // Split across two reads, as BLE notifications arrive.
        let first = decoder.feed(Array(wire.prefix(4)))
        let second = decoder.feed(Array(wire.dropFirst(4)))
        #expect(first.isEmpty)
        #expect(second.count == 1)
        #expect(second.first?.data == payload)
        #expect(second.first?.port == 0 && second.first?.command == 0)
    }
}

struct APRSTests {
    @Test func positionEncodesAndParses() {
        let info = APRS.position(latitude: 38.9, longitude: -77.0333, comment: "FM18")
        #expect(info == "=3854.00N/07702.00W`FM18")
        let p = APRS.parse(info)
        #expect(p.kind == .position)
        #expect(abs((p.latitude ?? 0) - 38.9) < 0.001)
        #expect(abs((p.longitude ?? 0) + 77.0333) < 0.001)
        #expect(p.comment == "FM18")
    }

    @Test func messageAckAndID() {
        let info = APRS.message(to: "w1aw-5", text: "Hi from the ISS{pass}", id: "12")
        // Reserved `{` is stripped from the text; the message ID goes after the only `{`.
        #expect(info == ":W1AW-5   :Hi from the ISSpass}{12")
        let p = APRS.parse(":N8HM     :Thanks for the contact{7")
        #expect(p.kind == .message && p.addressee == "N8HM" && p.text == "Thanks for the contact" && p.messageID == "7")
        #expect(APRS.ack(to: "N8HM", id: "7") == ":N8HM     :ack7")
        let ack = APRS.parse(":N8HM     :ack7")
        #expect(ack.kind == .ack && ack.messageID == "7")
    }

    @Test func compressedPosition() {
        // APRS 1.0.1 ch. 9 example: /5L!!<*e7> sT → 49.5°N, 72.75°W.
        let p = APRS.parse("!/5L!!<*e7>7P[")
        #expect(p.kind == .position)
        #expect(abs((p.latitude ?? 0) - 49.5) < 0.01)
        #expect(abs((p.longitude ?? 0) + 72.75) < 0.01)
    }

    @Test func micEDecodesLatitudeFromDestination() {
        // Destination S32UVT: latitude 33°25.64'N, +100° longitude offset ('V'), west ('T').
        // Info: degrees '(' = 12 (+100 = 112), minutes '#' = 07, hundredths 'f' = 74 → 112°07.74'W.
        let info = "`(#fn\"Oj/"
        let p = APRS.parse(info, destination: "S32UVT")
        #expect(p.kind == .micE)
        #expect(abs((p.latitude ?? 0) - (33 + 25.64 / 60)) < 0.001)
        #expect(abs((p.longitude ?? 0) + (112 + 7.74 / 60)) < 0.01)
    }
}

struct AFSKModemTests {
    private func testFrame(_ text: String = "Hello via satellite") -> AX25Frame {
        AX25Frame(destination: AX25Address(call: "APZODK"), source: AX25Address(call: "N8HM", ssid: 7),
                  digipeaters: [AX25Address(call: "ARISS")], info: Array(text.utf8))
    }

    @Test func hdlcRoundTripWithStuffing() {
        // 0xFF-heavy payload exercises zero-bit stuffing.
        let frame = AX25Frame(destination: AX25Address(call: "APZODK"), source: AX25Address(call: "N8HM"),
                              info: [0xFF, 0xFF, 0x7E, 0x7E, 0x00, 0xFE])
        let tones = HDLC.encode(frame.encoded(), preambleFlags: 4)
        var decoder = HDLC.Decoder()
        var out: [[UInt8]] = []
        for t in tones { if let f = decoder.push(level: t) { out.append(f) } }
        #expect(out.count == 1)
        #expect(out.first.flatMap { AX25Frame.decode($0) } == frame)
    }

    @Test(arguments: [48_000.0, 16_000.0, 44_100.0])
    func cleanLoopback(sampleRate: Double) {
        let frame = testFrame()
        let audio = AFSKModulator.transmission(frame, sampleRate: sampleRate, txDelayMs: 200)
        let demod = AFSKDemodulator(sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: Int(sampleRate / 5))
        let frames = demod.process(silence + audio + silence)
        #expect(frames == [frame])
    }

    @Test func survivesNoiseAndDeEmphasisTilt() {
        let fs = 48_000.0
        let frame = testFrame("De-emphasised audio with noise, like an FM receiver's speaker output")
        var audio = AFSKModulator.transmission(frame, sampleRate: fs, txDelayMs: 300, amplitude: 0.4)
        // Tilt: a one-pole low-pass (~1 kHz) cuts the 2200 Hz space tone ~5 dB more than mark.
        var y: Float = 0
        let a = Float(exp(-2 * Double.pi * 1000 / fs))
        for i in audio.indices { y = a * y + (1 - a) * audio[i]; audio[i] = y * 2.2 }
        // White noise at roughly 10 dB SNR (deterministic LCG so the test is stable).
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
        let noisy = audio.map { $0 + 0.09 * noise() }
        let demod = AFSKDemodulator(sampleRate: fs)
        #expect(demod.process(noisy) == [frame])
    }

    @Test func decodesBackToBackFramesAndReportsBusy() {
        let fs = 48_000.0
        let a = testFrame("first"), b = testFrame("second")
        let audio = AFSKModulator.transmission(a, sampleRate: fs, txDelayMs: 150)
            + AFSKModulator.transmission(b, sampleRate: fs, txDelayMs: 150)
        let demod = AFSKDemodulator(sampleRate: fs)
        let mid = audio.count / 4
        _ = demod.process(Array(audio[..<mid]))
        #expect(demod.channelBusy)
        let frames = demod.process(Array(audio[mid...]))
        #expect(frames.count == 2)
    }

    @Test func ignoresPureNoise() {
        var seed: UInt32 = 99
        let noise = (0..<96_000).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.3 }
        #expect(AFSKDemodulator(sampleRate: 48_000).process(noise).isEmpty)
    }
}
