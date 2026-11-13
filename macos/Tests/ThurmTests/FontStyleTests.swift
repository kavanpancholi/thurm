import CoreText
import Metal
import XCTest
@testable import Thurm

/// `font.style` picks a face of the family for regular text, and bold and italic come in its
/// width. Futura and Helvetica Neue ship with macOS.
final class FontStyleTests: XCTestCase {
    private func faces(family: String, style: String?) throws -> [String] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let config = AppConfig()
        config.fontFamily = family
        config.fontStyle = style
        let shaper = try XCTUnwrap(FontShaper(config: config, fontSize: 14, scale: 2, device: device))
        return shaper.styleFonts.map { CTFontCopyPostScriptName($0) as String }
    }

    func testStyleKeepsWidthForBold() throws {
        let fonts = try faces(family: "Futura", style: "Condensed Medium")
        XCTAssertEqual(fonts[0], "Futura-CondensedMedium")
        XCTAssertEqual(fonts[1], "Futura-CondensedExtraBold")
        XCTAssertEqual(fonts[2], "Futura-MediumItalic")
    }

    func testStyleKeepsWeightForItalic() throws {
        let fonts = try faces(family: "Helvetica Neue", style: "Light")
        XCTAssertEqual(fonts, ["HelveticaNeue-Light", "HelveticaNeue-Bold",
                               "HelveticaNeue-LightItalic", "HelveticaNeue-BoldItalic"])
    }

    func testStyleIsCaseInsensitive() throws {
        XCTAssertEqual(try faces(family: "Futura", style: "condensed medium")[0], "Futura-CondensedMedium")
    }

    func testUnknownStyleFallsBackToTheFamily() throws {
        // All four faces, in families with several weights and widths.
        for family in ["Helvetica Neue", "Futura"] {
            XCTAssertEqual(try faces(family: family, style: "Semi-Condensed"),
                           try faces(family: family, style: nil), family)
        }
    }

    func testStyleRuleMatchesAnyCase() {
        XCTAssertTrue(FontStyleRule.offers(["Light", "Bold"], "light"))
        XCTAssertFalse(FontStyleRule.offers(["Light", "Bold"], "Semi-Condensed"))
    }

    func testDefaultStyleOverridesConfigFile() {
        XCTAssertTrue(FontStyleRule.defaultValue(fileValue: nil) is NSNull)
        XCTAssertTrue(FontStyleRule.defaultValue(fileValue: "") is NSNull)
        XCTAssertEqual(FontStyleRule.defaultValue(fileValue: "Semi-Condensed") as? String, "")
    }
}
