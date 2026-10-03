import Foundation
import Testing
@testable import YDeliveryKit

@Suite("The string catalogs")
struct LocalizationTests {
    /// A bundle pinned to Russian: `Bundle(path: xx.lproj)` resolves that
    /// language's table regardless of the test host's locale — the lookup the
    /// app's own UI makes, minus the device language.
    private func ru(_ key: String, in bundle: Bundle) -> String? {
        guard let lproj = bundle.path(forResource: "ru", ofType: "lproj"),
              let ru = Bundle(path: lproj) else { return nil }
        return ru.localizedString(forKey: key, value: nil, table: nil)
    }

    @Test("Every status word resolves in Russian")
    func statusWordsResolve() {
        for status in OrderStatus.allCases {
            let key = String(describing: status.words.key)
            let word = ru(key, in: .kit)
            #expect(word != nil && word != key,
                    "\(status) has no ru entry in the kit catalog")
        }
    }

    @Test("Kit catalog: interpolated keys keep their format")
    func kitInterpolations() {
        #expect(ru("No. %@", in: .kit) == "№%@")
        #expect(ru("Stop %lld", in: .kit) == "Точка %lld")
    }

    @Test("Data catalog: the honest waits resolve")
    func dataPhrasesResolve() throws {
        // `Bundle.data` is internal to the data module; the resource bundle
        // still sits beside the kit's own in every packaging style.
        let dataURL = Bundle.kit.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("YDeliveryKit_YDeliveryData.bundle")
        let data = try #require(Bundle(url: dataURL))
        // D2's two truth-splits, in the provider's own language.
        #expect(ru("Needs a decision", in: .kit) == "Нужно решение")
        #expect(ru("Ended before delivery", in: data) == "Завершился до вручения")
        #expect(ru("%@, ext. %@", in: data) == "%@, доб. %@")
    }

    @Test("English falls back to the key — an untranslated entry still reads")
    func englishFallback() {
        // Key-spelling check the other way: the en value IS the key.
        #expect(Bundle.kit.localizedString(forKey: "Needs a decision",
                                           value: nil, table: nil) == "Needs a decision")
    }
}
