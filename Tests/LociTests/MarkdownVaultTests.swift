import Testing
import Foundation
@testable import Loci

@Suite("MarkdownVault")
struct MarkdownVaultTests {

    @Test("Slug generation is deterministic")
    func testSlugDeterministic() throws {
        let item = ReferenceItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "My Test Document",
            subtitle: "test",
            fileName: "test.pdf",
            kind: .typography,
            group: .file,
            theme: .aurora,
            aspectRatio: 1.0,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )

        let slug1 = MarkdownVault.slug(for: item)
        let slug2 = MarkdownVault.slug(for: item)
        #expect(slug1 == slug2)
        #expect(slug1.contains("my-test-document"))
        #expect(slug1.contains("00000000"))
    }

    @Test("Slug handles special characters")
    func testSlugSpecialChars() throws {
        let item = ReferenceItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Hello & World: A Test!",
            subtitle: "",
            fileName: "test.txt",
            kind: .typography,
            group: .file,
            theme: .aurora,
            aspectRatio: 1.0,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )

        let slug = MarkdownVault.slug(for: item)
        #expect(!slug.contains("&"))
        #expect(!slug.contains(":"))
        #expect(!slug.contains("!"))
        #expect(slug.contains("hello-world-a-test"))
    }

    @Test("Slug for empty title uses fallback")
    func testSlugEmptyTitle() throws {
        let item = ReferenceItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: "",
            subtitle: "",
            fileName: "test.txt",
            kind: .typography,
            group: .file,
            theme: .aurora,
            aspectRatio: 1.0,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )

        let slug = MarkdownVault.slug(for: item)
        #expect(slug.hasPrefix("reference-"))
    }

    @Test("Default vault URL is in Application Support")
    func testDefaultVaultURL() throws {
        let url = MarkdownVault.defaultVaultURL()
        #expect(url.path.contains("Application Support"))
        #expect(url.path.contains(AppBrand.name) || url.path.contains(AppBrand.legacyName))
    }

    @Test("X bookmarks enrich the graph with author, media, domain, and tag nodes")
    func testXBookmarkGraphEnrichment() throws {
        let referenceID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let item = ReferenceItem(
            id: referenceID,
            title: "Designer @designer: Useful visual reference",
            subtitle: "https://x.com/designer/status/123456789",
            fileName: "x-post.webloc",
            kind: .website,
            group: .link,
            theme: .aurora,
            aspectRatio: 0.92,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )
        let slug = MarkdownVault.slug(for: item)
        let document = VaultDocument(
            id: referenceID,
            title: item.title,
            slug: slug,
            relativePath: "wiki/references/\(slug).md",
            outgoingLinks: [],
            outgoingRelations: [:],
            backlinks: [],
            tags: ["x-bookmarked"],
            kind: item.kind,
            group: item.group
        )
        let payload = BrowserExtensionReferencePayload(
            url: item.subtitle,
            title: item.title,
            note: "Designer @designer",
            selectedText: "Useful visual reference",
            pageHTML: nil,
            articleMarkdown: nil,
            transcriptText: nil,
            imageURLs: ["https://pbs.twimg.com/media/example.jpg"],
            autoTags: ["x-bookmarked", "design"],
            source: "x-bookmark-sync",
            faviconURL: nil,
            ogImageURL: nil,
            alsoBookmarkOnX: true
        )

        let graph = MarkdownVault.buildGraph(
            from: [document],
            items: [item],
            xPayloadsByReferenceID: [referenceID: payload]
        )

        #expect(graph.nodes.contains { $0.kind == .xAuthor && $0.title == "Designer @designer" })
        #expect(graph.nodes.contains { $0.kind == .xMedia })
        #expect(graph.nodes.contains { $0.kind == .domain && $0.title == "x.com" })
        #expect(graph.nodes.contains { $0.kind == .tag && $0.title == "#design" })

        let relations = Set(graph.edges.map(\.relation))
        #expect(relations.contains(.authoredBy))
        #expect(relations.contains(.containsMedia))
        #expect(relations.contains(.domain))
        #expect(relations.contains(.tagged))
    }
}
