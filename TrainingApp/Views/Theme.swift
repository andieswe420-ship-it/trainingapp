import SwiftUI

/// Appens formspråk, hämtat från ikonen: djupblå bakgrund, cyan–blå ring och vita, rundade siffror.
/// Appen är alltid mörk (`preferredColorScheme(.dark)` i `TrainingApp`).
enum Theme {
    static let backgroundTop = Color(red: 0.03, green: 0.08, blue: 0.20)
    static let backgroundBottom = Color(red: 0.05, green: 0.17, blue: 0.40)
    static let card = Color(red: 0.10, green: 0.21, blue: 0.43).opacity(0.72)
    static let cardRaised = Color(red: 0.13, green: 0.27, blue: 0.52).opacity(0.85)
    static let border = Color.white.opacity(0.08)
    static let cyan = Color(red: 0.36, green: 0.88, blue: 1.0)
    static let blue = Color(red: 0.26, green: 0.56, blue: 1.0)
    static let hot = Color(red: 1.0, green: 0.48, blue: 0.36)
    static let secondaryText = Color.white.opacity(0.62)

    static let background = LinearGradient(
        colors: [backgroundTop, backgroundBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Ringens gradient i ikonen.
    static let accent = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Rundade siffror för puls, tempo, tider och nyckeltal.
    static func metric(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func color(for intensity: PlannedWorkout.Intensity) -> Color {
        switch intensity {
        case .easy: cyan
        case .moderate: blue
        case .hard: hot
        }
    }
}

extension View {
    /// Mörk gradientbakgrund bakom en hel skärm (även listor och scrollvyer).
    func themedScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }

    /// Mörk flikrad. Måste sättas på varje fliks innehåll, inte på TabView.
    func themedTabBar() -> some View {
        toolbarBackground(Theme.backgroundTop, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }

    /// Kortbakgrund för rader i en `List`.
    func themedRow() -> some View {
        listRowBackground(Theme.card)
    }

    /// Fristående kort i en scrollvy.
    func card(raised: Bool = false) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(raised ? Theme.cardRaised : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.border)
            )
    }
}

/// Liten rubrik ovanför ett kort.
struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Huvudknappen: ikonens cyan–blå gradient med mörk text.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration)
    }

    /// `isEnabled` kan bara läsas i en vy, inte i själva knappstilen.
    private struct PrimaryButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(Theme.backgroundTop)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Theme.accent))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}

/// Sekundär knapp: genomskinlig kapsel med vit text.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButton(configuration: configuration)
    }

    private struct SecondaryButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10)))
                .overlay(Capsule().strokeBorder(Theme.border))
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Ringen från ikonen: ett spår och en gradientbåge som fylls från toppen.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
    }
}

/// Ett nyckeltal: stor rundad siffra med etikett under.
struct MetricView: View {
    let value: String
    let label: String
    var size: CGFloat = 26

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.metric(size))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}
