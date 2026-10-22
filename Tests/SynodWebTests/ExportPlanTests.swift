import CoreMedia
import Testing
@testable import SynodWeb

@Suite struct ExportPlanTests {
    @Test func raft60() {
        let p = ExportPlan(duration: 147_982, fps: 60, rate: 1)
        #expect(p.frameCount == 8880)
        #expect(p.at(0) == 0)
        #expect(p.at(p.frameCount - 1) == 147_982)
        #expect(p.at(1) == 1000.0 / 60)
        var last = -1.0
        for k in 0..<p.frameCount {
            #expect(p.at(k) >= last)
            last = p.at(k)
        }
        #expect(p.pts(7) == CMTime(value: 7, timescale: 60))
        #expect(p.videoDuration == CMTime(value: 8880, timescale: 60))
    }

    @Test func doubleRate() {
        let p = ExportPlan(duration: 147_982, fps: 60, rate: 2)
        #expect(p.frameCount == 4441)
        #expect(p.at(1) == 2000.0 / 60)
        #expect(p.at(p.frameCount - 1) == 147_982)
    }

    @Test func thirtyFps() {
        let p = ExportPlan(duration: 147_982, fps: 30, rate: 1)
        #expect(p.frameCount == 4441)
        #expect(p.at(1) == 1000.0 / 30)
    }

    @Test func emptyScene() {
        let p = ExportPlan(duration: 0)
        #expect(p.frameCount == 1)
        #expect(p.at(0) == 0)
        #expect(p.batches(of: 8) == [0..<1])
    }

    @Test func exactDuration() {
        #expect(ExportPlan(duration: 1000, fps: 60).frameCount == 61)
    }

    @Test func batches() {
        let p = ExportPlan(duration: 1000, fps: 60)
        let b = p.batches(of: 8)
        #expect(b.first == 0..<8 && b.last == 56..<61)
        #expect(b.map(\.count).reduce(0, +) == 61)
    }

    @Test func sizes() {
        #expect(ExportSize.hd1080.pixelWidth == 1920 && ExportSize.hd1080.pixelHeight == 1080)
        #expect(ExportSize.uhd4k.pixelWidth == 3840 && ExportSize.uhd4k.pixelHeight == 2160)
        #expect(ExportSize.uhd4k.cssWidth == 1920)
    }

    @Test func bitrates() {
        #expect(VideoSettings(width: 1920, height: 1080, codec: .h264).bitrate == 24_000_000)
        #expect(VideoSettings(width: 1920, height: 1080, codec: .hevc).bitrate == 16_000_000)
        #expect(VideoSettings(width: 3840, height: 2160, codec: .h264).bitrate == 80_000_000)
        #expect(VideoSettings(width: 3840, height: 2160, codec: .hevc).bitrate == 50_000_000)
    }

    @Test func fullRangeEqualsTheVideoPlan() {
        let whole = ExportPlan(duration: 147_982, fps: 60, rate: 1)
        let explicit = ExportPlan(duration: 147_982, fps: 60, rate: 1, from: 0, to: 147_982)
        #expect(whole == explicit)
        #expect(whole.from == 0 && whole.to == 147_982)
        for k in stride(from: 0, to: whole.frameCount, by: 97) { #expect(whole.at(k) == explicit.at(k)) }
    }

    @Test func rangeSchedule() {
        // [2000, 5000] at 20 fps, rate 1: N = ceil(3000 * 20 / 1000) + 1 = 61.
        let p = ExportPlan(duration: 10_000, fps: 20, rate: 1, from: 2000, to: 5000)
        #expect(p.frameCount == 61)
        #expect(p.at(0) == 2000)
        #expect(p.at(1) == 2050)
        #expect(p.at(60) == 5000)
        #expect(p.pts(60) == CMTime(value: 60, timescale: 20))
        // A rate of 2 halves the frames: ceil(3000 * 20 / 2000) + 1 = 31; frame k is at 2000 + k * 100.
        let q = ExportPlan(duration: 10_000, fps: 20, rate: 2, from: 2000, to: 5000)
        #expect(q.frameCount == 31)
        #expect(q.at(1) == 2100 && q.at(30) == 5000)
        // The last frame is clamped to b when the step does not divide the range.
        let r = ExportPlan(duration: 10_000, fps: 25, rate: 1, from: 0, to: 1010)
        #expect(r.frameCount == 27)   // ceil(1010 * 25 / 1000) + 1 = 26 + 1
        #expect(r.at(26) == 1010)
    }

    @Test func rangeIsClamped() {
        let p = ExportPlan(duration: 5000, fps: 10, rate: 1, from: -5, to: 9000)
        #expect(p.from == 0 && p.to == 5000)
        let inverted = ExportPlan(duration: 5000, fps: 10, rate: 1, from: 4000, to: 1000)
        #expect(inverted.from == 1000 && inverted.to == 1000 && inverted.frameCount == 1)
    }

    @Test func gifFrameRatesAndCounts() {
        for fps in GIFLimits.frameRates {
            let p = ExportPlan(duration: 18_450, fps: fps, rate: 1)
            var last = -1.0
            for k in 0..<p.frameCount { #expect(p.at(k) >= last); last = p.at(k) }
            #expect(p.at(p.frameCount - 1) == 18_450)
        }
        #expect(ExportPlan(duration: 18_450, fps: 20).frameCount == 370)
    }
}
