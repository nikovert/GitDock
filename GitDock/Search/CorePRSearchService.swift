import GitDockCore

struct CorePRSearchService: PRSearchServing {
    let engine: PRSearchEngine

    init(engine: PRSearchEngine = PRSearchEngine()) { self.engine = engine }
    func states() async -> AsyncStream<PRSearchState> { await engine.states() }
    func configure(login: String?, current: [PullRequestPresentation], repositories: [String]) async {
        await engine.setContext(selectedLogin: login, currentPRs: current, repositories: repositories)
    }
    func query(_ value: String) async { await engine.setQuery(value) }
    func search(extended: Bool) async { await engine.search(extended: extended) }
    func pause() async { await engine.pause() }
    func clear() async { await engine.clearCache() }
}
