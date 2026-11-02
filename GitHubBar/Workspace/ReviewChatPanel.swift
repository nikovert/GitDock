import GitHubBarCore
import SwiftUI

struct ReviewChatPanel: View {
    @Bindable var review: ReviewWorkspaceModel
    @Bindable var workspace: WorkspaceModel
    let pullRequest: PullRequestPresentation?
    @Binding var showsSettings: Bool
    @AppStorage("githubbar.chat.configuration") private var configurationData = Data()

    private var configuration: ReviewChatConfiguration {
        (try? JSONDecoder().decode(ReviewChatConfiguration.self, from: configurationData)) ?? ReviewChatConfiguration()
    }
    private var configured: Bool { (try? configuration.validated()) != nil }
    private let policy = "Advisory chat only. Use the supplied PR context. Do not modify files, run tools, publish comments, or reply on GitHub. Explain missing evidence."
    private var canSend: Bool {
        configured && !review.chatting && review.snapshot != nil && review.local.canSave &&
            !review.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text(configuration.displayName.nilIfEmpty ?? "Ask an agent").font(.headline)
                Spacer()
                Button { showsSettings = true } label: { Image(systemName: "gearshape") }.help("Configure chat agent")
            }
            HStack(spacing: 6) {
                Circle().fill(review.chatting ? Color.orange : configured ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(review.chatting ? "Working…" : configured ? "Configured · available on request" : "Chat not configured")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if let snapshot = review.snapshot {
                Text("Context: #\(snapshot.key.number) · \(snapshot.headSHA.prefix(8))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if review.contextIsIncomplete {
                    Label("Partial context · some files or diff lines are unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let selected = review.selection {
                    Text("\(selected.path):\(selected.line)").font(.caption.monospaced()).lineLimit(2)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if review.draft.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Understand the change before you decide.").font(.subheadline.weight(.medium))
                                Text("Ask about risks, tests, or a selected line. The agent receives this PR's description and available diff context.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(["Summarize this PR and its main risks.", "Which tests are missing?", "What should I check before approving?"], id: \.self) { prompt in
                                    Button(prompt) { review.question = prompt }.buttonStyle(.plain).foregroundStyle(.blue)
                                        .font(.caption).padding(.vertical, 3)
                                }
                            }.padding(.vertical, 12)
                        }
                        ForEach(review.draft.messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "You" : configuration.displayName.nilIfEmpty ?? "Agent")
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                                AgentMarkdownView(text: message.text)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.role == "user" ? Color(nsColor: .windowBackgroundColor) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                                .id(message.id)
                        }
                        if review.chatting {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Agent is thinking…").font(.caption).foregroundStyle(.secondary) }
                                .accessibilityElement(children: .combine)
                        }
                        ForEach(Array(review.citations.enumerated()), id: \.offset) { _, citation in
                            Button("\(citation.path):\(citation.line)") { review.follow(citation) }
                                .font(.caption.monospaced()).buttonStyle(.link)
                        }
                    }
                }
                .onChange(of: review.draft.messages.count) { _, _ in
                    if let last = review.draft.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if !configured {
                Button("Connect a chat adapter…") { showsSettings = true }
            }
            if let error = review.chatErrorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if review.canRetryChat {
                    Button("Retry question") { review.retryQuestion(configuration: configuration, policy: policy) }
                        .disabled(!configured || review.chatting || !review.local.canSave)
                }
            }
            MultilineComposer(text: $review.question, placeholder: "Ask about this PR…", isEnabled: canSend, actionLabel: "Ask agent") {
                review.sendQuestion(configuration: configuration, policy: policy)
            }.frame(height: 88)
            HStack {
                if review.chatting { Button("Stop") { review.stopChat() } }
                Spacer()
                Button("Ask agent") { review.sendQuestion(configuration: configuration, policy: policy) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
            Text("Answers stay here. GitHub reviews are submitted separately.").font(.caption2).foregroundStyle(.secondary)

        }.padding(16).background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ReviewChatSettingsView: View {
    @AppStorage("githubbar.chat.configuration") private var configurationData = Data()
    @State private var provider: ReviewChatProvider = .custom
    @State private var name = ""
    @State private var executable = ""
    @State private var arguments = ""
    @State private var directory = ""
    @State private var status: String?
    @State private var testing = false
    @State private var connectionTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private let detection = ReviewChatProviderDetection()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect a chat and review agent").font(.title2.bold())
            Text("This provider is used for workspace chat and the PR’s Agent review button. Use your existing local Codex or Claude account, or a compatible custom adapter.")
                .foregroundStyle(.secondary)
            Picker("Provider", selection: Binding(get: { provider }, set: { value in
                provider = value; status = nil
                if value != .custom { useInstalledCLI(value) }
            })) {
                ForEach(ReviewChatProvider.allCases) { value in Text(value.displayName).tag(value) }
            }.pickerStyle(.segmented).disabled(testing)
            if provider == .custom {
                Form {
                    TextField("Display name", text: $name)
                    TextField("Executable (absolute path)", text: $executable)
                    TextField("Working directory", text: $directory)
                    TextField("Arguments (JSON array or one per line)", text: $arguments, axis: .vertical).lineLimit(3...6)
                }.disabled(testing)
            } else {
                Label(detection.executable(for: provider)?.path ?? "\(provider.displayName) is not installed in a known executable location.",
                      systemImage: detection.executable(for: provider) == nil ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption).textSelection(.enabled)
                Text("Sign in first from Terminal using \(provider == .codex ? "codex login" : "claude auth login"). Test connection sends a small chat request; a full PR review takes longer and also requires structured findings. Tests and reviews may use your provider allowance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let guide = Bundle.main.url(forResource: "agent-chat", withExtension: "md") {
                Button("Open chat setup guide") { NSWorkspace.shared.open(guide) }
            }
            if testing {
                HStack { ProgressView().controlSize(.small); Text("Testing connection…").font(.caption) }
            }
            if let status { Text(status).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Cancel") { connectionTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if !configurationData.isEmpty {
                    Button("Disconnect") { connectionTask?.cancel(); configurationData = Data(); dismiss() }
                }
                Button(testing ? "Stop test" : "Test connection") {
                    if testing { connectionTask?.cancel() } else { testConnection() }
                }
                Spacer()
                Button("Save") {
                    do {
                        configurationData = try JSONEncoder().encode(makeConfiguration())
                        dismiss()
                    } catch { status = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(testing)
            }
        }.padding(24).frame(width: 590)
        .onAppear {
            if let value = try? JSONDecoder().decode(ReviewChatConfiguration.self, from: configurationData) {
                provider = value.provider
                name = value.displayName; executable = value.executable; directory = value.workingDirectory
                arguments = encodedArguments(value.arguments)
            } else {
                provider = detection.selection(persisted: nil)
                if provider != .custom { useInstalledCLI(provider) }
            }
        }
        .onDisappear { connectionTask?.cancel() }
    }

    private func makeConfiguration() throws -> ReviewChatConfiguration {
        try ReviewChatConfiguration(displayName: name, executable: executable,
            arguments: ReviewAgentConnection.parseArguments(arguments), workingDirectory: directory,
            provider: provider).validated()
    }

    private func encodedArguments(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values)) ?? Data(), as: UTF8.self)
    }

    private func useInstalledCLI(_ value: ReviewChatProvider) {
        name = value.displayName
        executable = ""; arguments = ""; directory = NSHomeDirectory()
        let interpreters = ReviewChatProviderDetection(searchPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        guard let cli = detection.executable(for: value),
              let python = interpreters.executable(named: "python3"),
              let adapter = Bundle.main.url(forResource: "review-chat-adapter", withExtension: "py") else {
            status = "Install and sign into \(value.displayName), then reopen settings. This connection also requires Python 3 and GitHubBar's bundled adapter. Use Custom adapter for another installation."
            return
        }
        executable = python.path
        arguments = encodedArguments([adapter.path, "--provider", value.rawValue, "--cli", cli.path])
    }

    private func testConnection() {
        do {
            let configuration = try makeConfiguration()
            testing = true; status = nil
            connectionTask = Task { @MainActor in
                defer { testing = false; connectionTask = nil }
                do {
                    let request = ReviewChatRequest(accountLogin: "connection-test",
                        prURL: "https://github.com/githubbar/connection-test/pull/1", headSHA: "connection-test",
                        question: "Reply briefly that this chat connection works. Do not run tools.",
                        context: "Connection test only. No repository or PR context is available.",
                        policy: "Advisory only. No tools, file edits, or publication.", messages: [])
                    _ = try await ReviewChatClient(timeout: 30).send(request, configuration: configuration)
                    try Task.checkCancellation()
                    status = "Connection successful. The adapter returned a valid response."
                } catch is CancellationError {
                    status = "Connection test stopped."
                } catch {
                    status = "Connection failed: \(error.localizedDescription) Check local CLI sign-in and the setup guide."
                }
            }
        } catch { status = error.localizedDescription }
    }
}
