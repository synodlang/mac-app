import Testing
@testable import SynodWeb

let brandTheme: [(name: String, color: GIFColor)] = [
    ("Paper", GIFColor(hex: "#151A2E")!), ("Ink", GIFColor(hex: "#EDE9E1")!), ("Line", GIFColor(hex: "#3A4366")!),
    ("Quiet", GIFColor(hex: "#8A90A8")!), ("Accent", GIFColor(hex: "#F4A340")!), ("Good", GIFColor(hex: "#5CC8B8")!),
    ("Warning", GIFColor(hex: "#E8C35A")!), ("Critical", GIFColor(hex: "#E86F5A")!),
]

let brandSceneLine = """
{"format":"synod-scene/1","duration":18450,"canvas":{"w":1600,"h":1000},"theme":{"Paper":"#151A2E","Ink":"#EDE9E1","Line":"#3A4366","Quiet":"#8A90A8","Accent":"#F4A340","Good":"#5CC8B8","Warning":"#E8C35A","Critical":"#E86F5A"},"shapes":[
{"id":"a","kind":"label","props":{},"keys":[{"at":0,"text":"\\"theme\\":{\\"x\\":\\"#000000\\"}"}]}
]}

"""

// Entries 0, 7, 8, 15, 22, 112, 113, 119, 154; the mixes agree with the player's mixOklab (src/math/oklab.ts).
let goldenPicks = ["#151a2e", "#e86f5a", "#202538", "#777a83", "#dedad5", "#d96a58", "#d4d3d1", "#4e5675", "#eb806b"]

@Suite struct GIFPaletteTests {
    @Test func hex() {
        #expect(GIFColor(hex: "#F4a340") == GIFColor(r: 0xF4, g: 0xA3, b: 0x40))
        #expect(GIFColor(hex: "F4A340") == nil)
        #expect(GIFColor(hex: "#F4A34") == nil)
        #expect(GIFColor(hex: "#GGGGGG") == nil)
        #expect(GIFColor(r: 1, g: 2, b: 255).hex == "#0102ff")
    }

    @Test func themeInFileOrderFromFirstLineOnly() {
        let t = GIFPalette.theme(inSceneText: brandSceneLine)
        #expect(t.map(\.name) == ["Paper", "Ink", "Line", "Quiet", "Accent", "Good", "Warning", "Critical"])
        #expect(t.map(\.color) == brandTheme.map(\.color))
    }

    @Test func brandPaletteLayout() {
        let p = GIFPalette(theme: brandTheme)
        // n = 8: s = min(15, 248 / 7) = 15 -> 8 + 105 = 113; remaining 143, s2 = min(7, 143 / 6) = 7 -> + 42 = 155.
        #expect(p.colors.count == 155)
        #expect(Array(p.colors[0..<8]) == brandTheme.map(\.color))
        #expect(p.colors[0] == brandTheme[0].color)
        // The first Paper -> Ink mix is at u = 1/16 and lies between the two.
        let m = p.colors[8]
        #expect(m.r > 0x15 && m.r < 0xED)
        #expect(p == GIFPalette(sceneText: brandSceneLine))
        #expect(p == GIFPalette(theme: brandTheme))
    }

    @Test func goldenEntries() {
        let p = GIFPalette(theme: brandTheme)
        let picks = [0, 7, 8, 15, 22, 112, 113, 119, 154].map { p.colors[$0].hex }
        #expect(picks == goldenPicks)
    }

    @Test func mixEndpointsAndOrder() {
        let paper = brandTheme[0].color, ink = brandTheme[1].color
        #expect(OKLab.mix(paper, ink, 0) == paper)
        #expect(OKLab.mix(paper, ink, 1) == ink)
        // OKLab round trip of 8-bit colors is exact.
        for c in [paper, ink, GIFColor(r: 0, g: 0, b: 0), GIFColor(r: 255, g: 255, b: 255), brandTheme[4].color] {
            #expect(OKLab.color(OKLab.lab(c)) == c)
        }
    }

    @Test func degenerateThemes() {
        #expect(GIFPalette(theme: []).colors == [GIFPalette.defaultPaper])
        let two = GIFPalette(theme: [("Paper", GIFColor(r: 0, g: 0, b: 0)), ("Ink", GIFColor(r: 255, g: 255, b: 255))])
        #expect(two.colors.count == 2 + 15)   // s = 15 mixes Paper -> Ink; no third color for Ink -> c
        let many = (0..<300).map { (name: "c\($0)", color: GIFColor(r: UInt8($0 % 256), g: 0, b: 0)) }
        #expect(GIFPalette(theme: many).colors.count == 256)
    }

    @Test func quantizerTiesGoToLowerIndex() {
        let c = GIFColor(r: 10, g: 20, b: 30)
        var q = GIFQuantizer(palette: GIFPalette(colors: [GIFColor(r: 200, g: 0, b: 0), c, c, GIFColor(r: 0, g: 0, b: 0)]))
        #expect(q.index(r: 10, g: 20, b: 30) == 1)
        #expect(q.index(r: 10, g: 20, b: 30) == 1)   // cached
        #expect(q.index(r: 255, g: 0, b: 0) == 0)
        #expect(q.index(r: 0, g: 0, b: 1) == 3)
    }

    @Test func quantizerNearestInOKLab() {
        let pal = GIFPalette(colors: [GIFColor(r: 0, g: 0, b: 0), GIFColor(r: 255, g: 255, b: 255), GIFColor(r: 255, g: 0, b: 0)])
        var q = GIFQuantizer(palette: pal)
        #expect(q.index(r: 250, g: 20, b: 20) == 2)
        #expect(q.index(r: 20, g: 20, b: 20) == 0)
        #expect(q.index(r: 240, g: 240, b: 240) == 1)
    }
}
