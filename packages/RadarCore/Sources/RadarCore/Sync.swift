import Foundation

public struct Post: Codable, Sendable, Equatable {
    public let id: String; public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}
public struct PostPage: Sendable {
    public let posts: [Post]; public let next: String?
    public init(posts: [Post], next: String?) { self.posts = posts; self.next = next }
}
public protocol TiboDataSource: Sendable {
    func fetch(since: String?, page: String?) async throws -> PostPage
}
public enum SourceError: Error, Sendable { case network, invalidCredential, forbidden, rateLimited, insufficientCredit, server, invalidCursor }
public struct SyncState: Codable, Sendable {
    public var committed: String?; public var cursor: String?; public var newest: String?
    public var incomplete = false
    public init() {}
}
/// In-memory rehearsal repository; production persistence and retry timing are separate unfinished work.
public actor SyncCoordinator {
    private let source: any TiboDataSource
    private var task: Task<Void, Error>?
    public private(set) var state = SyncState()
    public private(set) var posts: [String: Post] = [:]
    public private(set) var analysisJobs: Set<String> = []
    public init(source: any TiboDataSource) { self.source = source }
    public func sync(maxPages: Int = 5) async throws {
        if let task { return try await task.value }
        let next = Task { try await self.run(maxPages: maxPages) }
        task = next
        defer { task = nil }
        try await next.value
    }
    private func run(maxPages: Int) async throws {
        state.incomplete = true
        for _ in 0..<max(0, maxPages) {
            let page: PostPage
            do { page = try await source.fetch(since: state.committed, page: state.cursor) }
            catch SourceError.invalidCursor { state.cursor = nil; state.newest = nil; throw SourceError.invalidCursor }
            for post in page.posts {
                if posts[post.id] != post { posts[post.id] = post; analysisJobs.insert(post.id) }
                if state.newest == nil || Self.newer(post.id, than: state.newest!) { state.newest = post.id }
            }
            state.cursor = page.next
            if page.next == nil {
                if let newest = state.newest { state.committed = newest }
                state.newest = nil; state.incomplete = false
                return
            }
        }
    }
    private static func newer(_ a: String, than b: String) -> Bool {
        a.count == b.count ? a > b : a.count > b.count
    }
}
