import SwiftUI
import AppStoreCore

/// The App Store download control on App Detail. It morphs through the same
/// stages the App Store's GET button does: pill → spinning ring while Apple
/// resolves the file → progress ring (tap to stop) → a bouncing checkmark.
struct DetailDownloadButton: View {
    @ObservedObject var manager: DownloadManager
    let appID: Int64
    let isResolving: Bool
    let isEnabled: Bool
    let start: @MainActor () -> Void
    let openDownloads: @MainActor () -> Void

    private enum Phase: Equatable {
        case idle, preparing, downloading(Double), done
    }

    private var record: DownloadRecord? {
        manager.records.last { $0.appID == appID }
    }

    private var phase: Phase {
        if isResolving { return .preparing }
        guard let record else { return .idle }
        switch record.state {
        case .queued: return .preparing
        case .downloading: return .downloading(manager.progress[record.id]?.fraction ?? record.progress)
        case .completed: return .done
        default: return .idle
        }
    }

    private var phaseKey: Int {
        switch phase {
        case .idle: 0
        case .preparing: 1
        case .downloading: 2
        case .done: 3
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            switch phase {
            case .idle:
                Button { start() } label: { Text("Download") }
                    .buttonStyle(.pillProminent)
                    .disabled(!isEnabled)
                    .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
            case .preparing:
                SpinnerRing()
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .accessibilityLabel("Preparing download")
            case .downloading(let fraction):
                Button {
                    if let record { manager.cancel(record.id) }
                } label: {
                    DownloadRing(fraction: fraction, size: 32)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .accessibilityLabel("Downloading, \(Int(fraction * 100)) percent. Double-tap to stop.")
            case .done:
                Button { openDownloads() } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.green)
                        .symbolEffect(.bounce, value: phaseKey)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
                .accessibilityLabel("Downloaded. Double-tap to open Downloads.")
            }
        }
        .frame(height: 34, alignment: .leading)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: phaseKey)
        .sensoryFeedback(.impact(weight: .light), trigger: phaseKey) { _, new in new == 1 }
        .sensoryFeedback(.success, trigger: phaseKey) { _, new in new == 3 }
    }
}

/// Indeterminate ring the App Store shows while a purchase is being set up.
struct SpinnerRing: View {
    var size: CGFloat = 32
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .background(Circle().stroke(Color(.tertiarySystemFill), lineWidth: 2.5))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// One in-flight icon travelling from App Detail to the Downloads tab.
struct IconFlight: Identifiable, Equatable {
    let id = UUID()
    let iconURL: URL?
    let name: String
    /// Start frame in global coordinates.
    let from: CGRect
}

/// Full-screen overlay that plays the flight: the icon pops, then arcs down
/// to the Downloads tab while shrinking and spinning. Driven frame by frame
/// by a TimelineView so the curve is exact.
struct FlyingIconOverlay: View {
    let flight: IconFlight
    /// Tab index of Downloads and the number of tabs, to find its x position.
    let tabIndex: Int
    let tabCount: Int
    let onLanded: @MainActor () -> Void

    @State private var startDate = Date()

    private static let popDuration = 0.14
    private static let flyDuration = 0.72

    private struct FrameState {
        var point: CGPoint
        var scale: CGFloat
        var rotation: Double
        var shadow: Double
        var opacity: Double
    }

    private func frameState(at date: Date, in geo: GeometryProxy) -> FrameState {
        let elapsed: Double = date.timeIntervalSince(startDate)
        let pop: Double = min(max(elapsed / Self.popDuration, 0), 1)
        let raw: Double = min(max((elapsed - Self.popDuration) / Self.flyDuration, 0), 1)
        // Ease-in cubic: slow lift-off, accelerating into the tab.
        let t = CGFloat(raw * raw * raw)
        let u: CGFloat = 1 - t

        let origin = geo.frame(in: .global).origin
        let start = CGPoint(x: flight.from.midX - origin.x, y: flight.from.midY - origin.y)
        let tabWidth: CGFloat = geo.size.width / CGFloat(tabCount)
        let end = CGPoint(x: tabWidth * (CGFloat(tabIndex) + 0.5), y: geo.size.height - 26)
        // Quadratic Bézier with the control point lifted above both ends, so
        // the icon rises briefly before dropping into the tab.
        let control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 140)
        let a: CGFloat = u * u
        let b: CGFloat = 2 * u * t
        let c: CGFloat = t * t
        let x: CGFloat = a * start.x + b * control.x + c * end.x
        let y: CGFloat = a * start.y + b * control.y + c * end.y

        let popScale = CGFloat(1 + 0.12 * sin(pop * Double.pi))
        let fade: Double = t > 0.9 ? Double(u / 0.1) : 1
        return FrameState(
            point: CGPoint(x: x, y: y),
            scale: popScale * (1 - 0.8 * t),
            rotation: Double(t) * 220,
            shadow: 0.25 * Double(u),
            opacity: fade
        )
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let frame = frameState(at: context.date, in: geo)
                AppIconView(url: flight.iconURL, name: flight.name, size: flight.from.width)
                    .scaleEffect(frame.scale)
                    .rotationEffect(.degrees(frame.rotation))
                    .shadow(color: .black.opacity(frame.shadow), radius: 14, y: 8)
                    .opacity(frame.opacity)
                    .position(frame.point)
            }
        }
        .allowsHitTesting(false)
        .task {
            startDate = Date()
            try? await Task.sleep(nanoseconds: UInt64((Self.popDuration + Self.flyDuration) * 1_000_000_000))
            onLanded()
        }
    }
}
