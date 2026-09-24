import SwiftUI
import AppStoreCore

/// Account screen: sign-in form, two-factor continuation, or the signed-in
/// summary. Credentials live in the view model only while a sign-in is in
/// flight and are passed to AppEnvironment.signIn as arguments; they are
/// never persisted, never logged, and are cleared as soon as the attempt
/// resolves, except across the two-factor handoff where clearing the
/// password would make the code un-submittable.
struct AccountView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = AccountViewModel()
    @FocusState private var focusedField: AccountField?

    private enum AccountField: Hashable {
        case email, password, twoFactorCode
    }

    var body: some View {
        Form {
            if let session = environment.session {
                signedInSection(session)
            } else {
                if environment.needsTwoFactorCode {
                    twoFactorSection
                } else {
                    credentialsSection
                }
                statusSection
                actionSection
                privacySection
            }
        }
        .navigationTitle("Account")
        .onChange(of: environment.needsTwoFactorCode) { _, needed in
            if needed {
                viewModel.twoFactorCode = ""
                focusedField = .twoFactorCode
            }
        }
        .onChange(of: viewModel.email) { _, _ in
            if environment.needsTwoFactorCode {
                environment.cancelTwoFactor()
                viewModel.twoFactorCode = ""
            }
        }
        .onDisappear {
            viewModel.clearCredentials()
        }
    }

    @ViewBuilder
    private func signedInSection(_ session: AppleAccountSession) -> some View {
        Section {
            LabeledContent("Name", value: session.displayName)
            LabeledContent("Email", value: session.email)
            LabeledContent("Storefront", value: session.countryCode?.uppercased() ?? session.storefront)
        } header: {
            Label("Signed In", systemImage: "checkmark.circle.fill")
        }

        Section {
            Button(role: .destructive) {
                Task { await environment.signOut() }
            } label: {
                HStack {
                    Spacer()
                    if environment.isAuthenticating { ProgressView() }
                    Text("Sign Out")
                    Spacer()
                }
            }
            .disabled(environment.isAuthenticating)
            .accessibilityHint("Ends the session and removes the stored token from this device")
        } footer: {
            Text("Signing out removes the session token from the Keychain on this device.")
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Apple Account email", text: $viewModel.email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .accessibilityLabel("Apple Account email")
            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
        } footer: {
            Text("Use the Apple Account that owns the apps you want to download.")
        }
    }

    private var twoFactorSection: some View {
        Section {
            TextField("123 456", text: $viewModel.twoFactorCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .twoFactorCode)
                .accessibilityLabel("Six-digit verification code")
                .accessibilityHint("Shown on a device trusted by your Apple Account")
        } header: {
            Label("Two-Factor Authentication", systemImage: "lock.shield")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the six-digit code shown on a trusted device. Your email and password are kept from the previous step.")
                Button("Use a different account") {
                    environment.cancelTwoFactor()
                    viewModel.clearCredentials()
                    focusedField = .email
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let error = viewModel.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
        if environment.isAuthenticating && !environment.needsTwoFactorCode {
            Section {
                if let progress = environment.authenticationProgress {
                    switch progress {
                    case .downloadingAssets(let completed, let total):
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(completed == 0 ? "Connecting to Apple download server…" :
                                        "Downloading sign-in assets from Apple", systemImage: "arrow.down.circle")
                                if completed == 0 {
                                    ProgressView()
                                } else {
                                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                                }
                                Text(downloadDetail(completed: completed, total: total, now: context.date))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case .extractingAssets:
                        Label("Preparing downloaded sign-in assets…", systemImage: "archivebox")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    default:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(progressTitle(progress))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("Preparing secure signing… first sign-in downloads assets from Apple.",
                          systemImage: "arrow.down.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func progressTitle(_ progress: AuthenticationProgress) -> String {
        switch progress {
        case .fetchingConfiguration: "Checking Apple service settings…"
        case .fetchingCertificate: "Getting Apple's signing certificate…"
        case .downloadingAssets: "Downloading sign-in assets from Apple…"
        case .extractingAssets: "Preparing downloaded sign-in assets…"
        case .initializingSigner: "Initializing secure signing…"
        case .establishingSession: "Establishing secure signing session…"
        case .signingRequest: "Signing authentication request…"
        case .authenticating: "Waiting for Apple's sign-in response…"
        case .retryingAfterRateLimit(let seconds): "Apple is busy. Retrying in \(seconds) seconds…"
        case .savingSession: "Saving your session securely…"
        }
    }

    private func downloadDetail(completed: Int64, total: Int64, now: Date) -> String {
        let received = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
        let expected = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        guard let started = environment.sapDownloadStartedAt else {
            return "\(received) / \(expected)"
        }
        let elapsed = now.timeIntervalSince(started)
        if completed == 0 {
            return elapsed >= 30
                ? "No data yet after \(Int(elapsed)) seconds. Checking the connection and retrying if needed."
                : "Waiting for the first data… \(Int(max(0, elapsed))) seconds"
        }
        guard elapsed >= 5, completed >= 1_048_576, total > completed else {
            return "\(received) / \(expected) · Estimating time remaining…"
        }
        let seconds = Int64(Double(total - completed) * elapsed / Double(completed))
        let minutes = max(1, (seconds + 59) / 60)
        return "\(received) / \(expected) · About \(minutes) min remaining"
    }

    private var actionSection: some View {
        Section {
            Button {
                focusedField = nil
                Task { await viewModel.signIn(environment: environment) }
            } label: {
                HStack {
                    Spacer()
                    if environment.isAuthenticating { ProgressView() }
                    Text(environment.needsTwoFactorCode ? "Verify" : "Sign In")
                    Spacer()
                }
            }
            .disabled(!viewModel.canSubmit(needsTwoFactor: environment.needsTwoFactorCode)
                      || environment.isAuthenticating)
        }
    }

    private var privacySection: some View {
        Section {
            Text("Your credentials are sent only to Apple. iPull has no server. Your password is never stored; the session token is kept in the iOS Keychain on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class AccountViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var twoFactorCode = ""
    @Published var errorMessage: String?

    /// The password is intentionally NOT cleared while a two-factor code is
    /// pending: Apple requires the same password resubmitted with the code
    /// appended, and wiping it here was the bug that made 2FA accounts
    /// impossible to sign in. It is cleared on success, on a non-2FA error,
    /// when the user edits the email, cancels, or leaves the screen.
    func signIn(environment: AppEnvironment) async {
        errorMessage = nil
        let result = await environment.signIn(
            email: email,
            password: password,
            twoFactorCode: environment.needsTwoFactorCode ? twoFactorCode : nil
        )
        switch result {
        case .success:
            clearCredentials()
        case .failure(let error):
            if error == .twoFactorRequired {
                return
            }
            if error == .invalidTwoFactorCode {
                twoFactorCode = ""
            } else {
                clearCredentials()
            }
            errorMessage = error.userMessage
        }
    }

    func canSubmit(needsTwoFactor: Bool) -> Bool {
        if needsTwoFactor {
            return twoFactorCode.filter { $0.isNumber }.count == 6
        }
        return !email.isEmpty && !password.isEmpty
    }

    func clearCredentials() {
        password = ""
        twoFactorCode = ""
        errorMessage = nil
    }
}
