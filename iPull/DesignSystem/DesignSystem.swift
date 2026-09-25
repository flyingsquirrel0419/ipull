import SwiftUI

/// App Store–style building blocks shared by every screen.

/// App icon with the continuous "squircle" mask and hairline border Apple
/// draws around icons, falling back to a monogram tile when no artwork URL
/// is known (library items, downloads).
struct AppIconView: View {
    let url: URL?
    var name: String = ""
    var size: CGFloat = 60

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
    }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        MonogramTile(name: name, size: size)
                    }
                }
            } else {
                MonogramTile(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

private struct MonogramTile: View {
    let name: String
    let size: CGFloat

    private var tint: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green]
        let seed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(seed) % palette.count]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .top, endPoint: .bottom)
            Text(name.first.map { String($0).uppercased() } ?? "")
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

/// The capsule "GET" button used across the App Store: bold caption on a
/// tinted fill, or white on the accent color when prominent.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .frame(minWidth: 74)
            .foregroundStyle(prominent ? Color.white : Color.accentColor)
            .background(
                Capsule().fill(prominent ? Color.accentColor : Color(.tertiarySystemFill))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
}

/// App Store download ring: a determinate circular track with a stop glyph.
struct DownloadRing: View {
    let fraction: Double
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
    }
}

/// The circular profile button App Store places at the top trailing edge.
struct AccountAvatar: View {
    let name: String?
    var size: CGFloat = 32

    var body: some View {
        if let initials = Self.initials(name), !initials.isEmpty {
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(LinearGradient(colors: [Color(.systemGray2), Color(.systemGray)],
                                                         startPoint: .top, endPoint: .bottom)))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
        }
    }

    static func initials(_ name: String?) -> String? {
        guard let name else { return nil }
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}

/// Toolbar item that opens the account sheet, like the App Store profile icon.
struct AccountToolbarButton: ToolbarContent {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { router.isAccountPresented = true } label: {
                AccountAvatar(name: environment.session?.displayName)
            }
            .accessibilityLabel("Account")
        }
    }
}

/// Bold section title with an optional trailing action, as on App Store pages.
struct SectionTitle: View {
    let title: String
    var actionLabel: String?
    var action: (@MainActor () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.bold))
            Spacer()
            if let actionLabel, let action {
                Button(actionLabel) { action() }.font(.body)
            }
        }
    }
}

/// An App Store list row: icon, two lines of text and a trailing pill.
struct AppRow<Accessory: View>: View {
    let iconURL: URL?
    let name: String
    var subtitle: String?
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            AppIconView(url: iconURL, name: name, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body).foregroundStyle(.primary).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory()
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
