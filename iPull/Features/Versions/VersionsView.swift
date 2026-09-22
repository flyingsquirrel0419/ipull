import SwiftUI
import AppStoreCore

/// Full version list sheet from App Detail.
struct VersionsView: View {
    @ObservedObject var viewModel: AppDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.versionState {
                case .loading:
                    ProgressView("Loading versions…")
                case .requiresSignIn:
                    ContentUnavailableView("Sign In Required", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text("Sign in to browse versions."))
                case .unavailable(let message):
                    ContentUnavailableView("Versions Unavailable", systemImage: "clock.badge.exclamationmark",
                                           description: Text(message))
                case .loaded(let versions):
                    List(versions) { version in
                        Button {
                            viewModel.select(version)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(version.displayVersion ?? "Version \(version.externalVersionID)")
                                        .foregroundStyle(.primary)
                                    if let date = version.releaseDate {
                                        Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if version.isLatest {
                                    Text("Latest").font(.caption).foregroundStyle(.secondary)
                                }
                                if viewModel.selectedVersion == version {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
