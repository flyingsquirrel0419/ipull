import SwiftUI
import AppStoreCore

struct AccountView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = AccountViewModel()

    var body: some View {
        Form {
            if let session = environment.session {
                Section("Signed In") {
                    LabeledContent("Name", value: session.displayName)
                    LabeledContent("Email", value: session.email)
                    LabeledContent("Storefront", value: session.countryCode?.uppercased() ?? session.storefront)
                }
                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await environment.signOut() }
                    }
                }
            } else {
                Section {
                    TextField("Apple Account email", text: $viewModel.email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $viewModel.password)
                        .textContentType(.password)
                }

                if viewModel.needsTwoFactor {
                    Section("Two-Factor Authentication") {
                        TextField("6-digit code", text: $viewModel.twoFactorCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        Text("Enter the code shown on your trusted device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    Button {
                        Task { await viewModel.signIn(environment: environment) }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isWorking { ProgressView() }
                            Text(viewModel.needsTwoFactor ? "Verify" : "Sign In")
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isWorking || viewModel.email.isEmpty || viewModel.password.isEmpty)
                }

                // First sign-in downloads the SAP assets (~1.2 GB from Apple).
                if viewModel.isWorking && !viewModel.needsTwoFactor {
                    Section {
                        Label("Preparing secure signing… this can take a few minutes on first sign-in.",
                              systemImage: "arrow.down.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Your credentials are sent only to Apple. iPull has no server. Your password is never stored; the session token is kept in the iOS Keychain on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Account")
    }
}

@MainActor
final class AccountViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var twoFactorCode = ""
    @Published var needsTwoFactor = false
    @Published var isWorking = false
    @Published var errorMessage: String?

    func signIn(environment: AppEnvironment) async {
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            password = "" // never keep the password around
        }
        do {
            let result = try await environment.client.auth.signIn(
                email: email,
                password: password,
                twoFactorCode: needsTwoFactor ? twoFactorCode : nil
            )
            switch result {
            case .success(let session):
                environment.session = session
                needsTwoFactor = false
                twoFactorCode = ""
            case .twoFactorRequired:
                needsTwoFactor = true
            }
        } catch let error as AppStoreError {
            errorMessage = error.userMessage
            if error == .invalidTwoFactorCode { twoFactorCode = "" }
        } catch {
            errorMessage = AppStoreError.unknown("signin").userMessage
        }
    }
}
