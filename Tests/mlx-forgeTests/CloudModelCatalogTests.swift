import XCTest

@testable import mlx_forge

/// Covers the read-side rules of the live model catalog: chat filtering of a
/// fetched list, custom-id layering, media model selection, and fallback to
/// the curated list before any fetch.
final class CloudModelCatalogTests: XCTestCase {
    private let keys = [
        "catalog.fetched.openAI", "catalog.custom.openAI",
        "catalog.fetched.xAI", "catalog.custom.xAI",
        "catalog.fetched.anthropic", "catalog.custom.anthropic",
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func seed(_ key: String, _ pairs: [[String]]) {
        UserDefaults.standard.set(pairs, forKey: key)
    }

    func testFallsBackToCuratedListBeforeFetch() {
        XCTAssertEqual(
            CloudModelCatalog.chatModels(.openAI).map(\.id),
            OpenAIClient.defaultModels.map(\.id))
    }

    func testFetchedOpenAIListIsFilteredToChatModels() {
        seed("catalog.fetched.openAI", [
            ["gpt-5.5", "GPT-5.5"], ["gpt-image-1", "GPT-Image 1"],
            ["sora-2", "sora-2"], ["o4-mini", "o4-mini"],
            ["text-embedding-3-large", "text-embedding-3-large"],
            ["whisper-1", "whisper-1"], ["gpt-4o-realtime", "GPT-4o Realtime"],
        ])
        XCTAssertEqual(
            CloudModelCatalog.chatModels(.openAI).map(\.id), ["gpt-5.5", "o4-mini"])
        XCTAssertEqual(CloudModelCatalog.imageModels(.openAI), ["gpt-image-1"])
        XCTAssertEqual(CloudModelCatalog.videoModels(), ["sora-2"])
    }

    func testCustomIdsLayerOnTopWithoutDuplicates() {
        seed("catalog.fetched.openAI", [["gpt-5.5", "GPT-5.5"]])
        CloudModelCatalog.addCustomModel(.openAI, id: "gpt-5.5")
        CloudModelCatalog.addCustomModel(.openAI, id: "  gpt-6-preview ")
        CloudModelCatalog.addCustomModel(.openAI, id: "")
        XCTAssertEqual(
            CloudModelCatalog.chatModels(.openAI).map(\.id), ["gpt-5.5", "gpt-6-preview"])
        CloudModelCatalog.removeCustomModel(.openAI, id: "gpt-6-preview")
        XCTAssertEqual(CloudModelCatalog.chatModels(.openAI).map(\.id), ["gpt-5.5"])
    }

    func testXAIImageModelsComeFromFetchedListWhenPresent() {
        XCTAssertEqual(CloudModelCatalog.imageModels(.xAI), ["grok-2-image"])
        seed("catalog.fetched.xAI", [["grok-4.3", "Grok 4.3"], ["grok-3-image", "Grok 3 Image"]])
        XCTAssertEqual(CloudModelCatalog.imageModels(.xAI), ["grok-3-image"])
        XCTAssertEqual(CloudModelCatalog.chatModels(.xAI).map(\.id), ["grok-4.3"])
    }
}
