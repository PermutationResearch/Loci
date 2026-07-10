import Testing
import Foundation
@testable import Loci

@Suite("VaultChatContext")
struct VaultChatContextTests {

    @Test("Search terms extraction")
    func testSearchTerms() throws {
        let terms = VaultChatContext.searchTerms(from: "What is the main topic of this document?")
        #expect(terms.contains("what"))
        #expect(terms.contains("main"))
        #expect(terms.contains("topic"))
        #expect(terms.contains("document"))
        #expect(terms.contains("this"))
        #expect(!terms.contains("is"))
        #expect(!terms.contains("of"))
    }

    @Test("Empty question returns no terms")
    func testEmptyQuestion() throws {
        let terms = VaultChatContext.searchTerms(from: "")
        #expect(terms.isEmpty)
    }

    @Test("Short words are filtered out")
    func testShortWordsFiltered() throws {
        let terms = VaultChatContext.searchTerms(from: "AI is a big deal")
        #expect(terms.contains("deal"))
        #expect(!terms.contains("ai"))
        #expect(!terms.contains("is"))
    }

    @Test("Word count calculation")
    func testWordCount() throws {
        let count = VaultChatContext.wordCount(in: "Hello world this is a test")
        #expect(count == 6)
    }

    @Test("Word count for empty string")
    func testWordCountEmpty() throws {
        let count = VaultChatContext.wordCount(in: "")
        #expect(count == 0)
    }

    @Test("Term scoring counts occurrences")
    func testTermScore() throws {
        let score = VaultChatContext.termScore(terms: ["hello"], in: "hello world hello test hello")
        #expect(score == 3)
    }

    @Test("Multiple term scoring")
    func testMultipleTermScore() throws {
        let score = VaultChatContext.termScore(terms: ["hello", "world"], in: "hello world hello")
        #expect(score == 3)
    }
}
