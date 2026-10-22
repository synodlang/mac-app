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
}
