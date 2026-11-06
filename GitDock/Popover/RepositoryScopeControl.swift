import GitDockCore
import SwiftUI

struct RepositoryScopeControl: View {
    @Bindable var appModel: AppModel
    var onManage: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Picker("Repositories", selection: Binding(
                get: { appModel.state.repositoryScope },
                set: { appModel.send(.selectRepositoryScope($0)) }
            )) {
                Text("All").tag(RepositoryScope.all)
                Text("Pinned \(appModel.state.pinnedRepositoryIDs.count)").tag(RepositoryScope.pinned)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button(action: onManage) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain)
                .help("Manage pinned repositories in Settings")
                .accessibilityLabel("Manage pinned repositories")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }
}
