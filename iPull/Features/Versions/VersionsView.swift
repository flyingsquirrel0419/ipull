import SwiftUI
import AppStoreCore

/// Full version history sheet from App Detail.
struct VersionsView: View {
    @ObservedObject var viewModel: AppDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.versionState {
                case .loading:
                    ProgressView().controlSize(.large)
                case .requiresSignIn:
                    ContentUnavailableView("Sign In Required", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text("Sign in to browse versions."))
                case .unavailable(let message):
                    ContentUnavailableView("Versions Unavailable", systemImage: "clock.badge.exclamationmark",
                                           description: Text(message))
                case .loaded(let versions):
                    List(versions) { version in
                        VersionRow(version: version, isSelected: viewModel.selectedVersion == version) {
                            viewModel.select(version)
                            dismiss()
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Version History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
