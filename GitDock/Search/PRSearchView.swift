import GitDockCore
import SwiftUI

struct PRSearchView: View {
    @Bindable var model: PRSearchModel
    var openPullRequest: (PullRequestPresentation) -> Void = { _ in }
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Title, description, changed path or code…", text: Binding(
                    get: { model.query }, set: { model.setQuery($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { model.submit() }
                Button(model.isSearching ? "Search again" : "Search") { model.submit() }
                    .disabled(!model.canSearch)
                if model.isSearching {
                    Button("Pause") { model.pause() }
                } else if model.state.phase == .paused || model.state.phase == .rateLimited {
                    Button("Resume") { model.submit() }.disabled(!model.canSearch)
                }
            }

            Toggle("Extended search — all PR states in selected repositories", isOn: Binding(
                get: { model.extended }, set: { model.setExtended($0) }
            ))
            .disabled(model.accountLogin == nil)

            if model.extended { repositoryPicker }
            progress
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    resultSection("In your list", results: model.state.inYourList, limit: $model.visibleListCount,
                                  empty: "No matches in your current list's searched data.")
                    Divider()
                    resultSection("Extended results", results: model.extended ? model.state.extendedResults : [],
                                  limit: $model.visibleExtendedCount,
                                  empty: model.extended
                                    ? "No extended matches in the data searched so far."
                                    : "Turn on Extended search to search other PRs, including merged and closed PRs.")
                }
                .padding(.trailing, 8)
            }
            HStack {
                Text("Literal search · words match independently · quote a phrase")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear search cache") { model.clearCache() }
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
    }

    private var repositoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Search repositories").font(.headline)
                Spacer()
                Button("Use current scope") { model.useDefaultRepositories() }.controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.repositories, id: \.self) { repository in
                        HStack {
                            Text(repository).font(.callout)
                            Spacer()
                            Button { model.removeRepository(repository) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(repository) and its search cache")
                        }
                    }
                }
            }
            .frame(maxHeight: 100)
            if model.repositories.isEmpty {
                Text("Select at least one repository for extended search.").font(.caption)
            }
            HStack {
                TextField("owner/repository", text: $model.repositoryInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addRepository(model.repositoryInput) }
                Button("Add repository") { model.addRepository(model.repositoryInput) }
            }
            if let error = model.inputError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.accountLogin == nil {
                Label("Connect a monitored GitHub account in Settings to search.", systemImage: "person.crop.circle.badge.exclamationmark")
            } else {
                HStack(spacing: 8) {
                    if model.isSearching { ProgressView().controlSize(.small) }
                    Text(phaseLabel).font(.callout.weight(.medium))
                    Spacer()
                    Text("\(model.state.progress.indexed) indexed · \(model.state.progress.discovered) discovered")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.state.message {
                    Text(message).font(.caption).textSelection(.enabled)
                }
                if model.state.progress.partial > 0 {
                    Label("\(model.state.progress.partial) PRs have incomplete code coverage.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                if model.state.progress.hasEvictedHistory {
                    Text("Older diffs were evicted from the bounded cache. A new query may need to fetch them again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let date = model.state.progress.lastRefresh {
                    Text("Last indexed: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var phaseLabel: String {
        switch model.state.phase {
        case .idle: "Press Search to fetch descriptions and changed code."
        case .validating: "Checking account and repository access…"
        case .indexing: "Searching PR history… Results appear as it is indexed."
        case .paused: "Paused — cached matches only. Resume explicitly."
        case .complete: model.state.progress.partial == 0 ? "Scan complete" : "Scan finished with partial code coverage"
        case .rateLimited: "Paused for GitHub rate limits"
        case .connectionRequired: "Account connection required"
        case .failed: "Search paused after an error"
        }
    }

    private func resultSection(_ title: String, results: [PRSearchResult], limit: Binding<Int>, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) (\(results.count))").font(.headline)
            if results.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(results.prefix(limit.wrappedValue)) { result in
                    PRSearchResultRow(result: result, openPullRequest: openPullRequest)
                }
                if results.count > limit.wrappedValue {
                    Button("Show more (\(results.count - limit.wrappedValue) remaining)") { limit.wrappedValue += 50 }
                }
            }
        }
    }
}

struct PRSearchResultRow: View {
    let result: PRSearchResult
    let openPullRequest: (PullRequestPresentation) -> Void
    var openGitHub: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { openPullRequest(result.pullRequest) } label: {
                resultContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(result.pullRequest.title) in Workspace Board")
            if result.source == .code || result.source == .file {
                Link("Files changed", destination: result.filesURL).font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .background(SecondaryClickCapture { openGitHub(result.pullRequest.url) })
        .help("Click to open Workspace Board. Right-click to open on GitHub.")
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.pullRequest.title).font(.headline).multilineTextAlignment(.leading)
            HStack {
                Text("\(result.pullRequest.repositoryNameWithOwner)#\(result.pullRequest.number)")
                Text("· \(result.pullRequest.author?.displayName ?? "Unknown author")")
                Spacer()
                Text(result.pullRequest.isDraft ? "Draft" : result.pullRequest.state.rawValue.capitalized)
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text([result.source.rawValue, result.lineKind?.rawValue, result.path].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.weight(.medium))
                Spacer()
            }
            Text(result.excerpt)
                .font(result.source == .code ? .system(.caption, design: .monospaced) : .callout)
                .lineLimit(5)
            if !result.coverage.codeComplete || !result.coverage.fileListComplete {
                Text(result.coverage.reasons.isEmpty ? "Code coverage incomplete" : result.coverage.reasons.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
