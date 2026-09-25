import SwiftUI

/// Palette shared with the app icon: indigo → midnight backdrop, violet/cyan
/// portal ring, teal "flow" ribbons.
enum Theme {
    static let indigo = Color(red: 38 / 255, green: 22 / 255, blue: 92 / 255)
    static let midnight = Color(red: 6 / 255, green: 12 / 255, blue: 30 / 255)
    static let violet = Color(red: 120 / 255, green: 90 / 255, blue: 255 / 255)
    static let cyan = Color(red: 60 / 255, green: 220 / 255, blue: 255 / 255)
    static let teal = Color(red: 70 / 255, green: 235 / 255, blue: 210 / 255)
    static let sky = Color(red: 90 / 255, green: 160 / 255, blue: 255 / 255)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.42)
    static let slate = Color(red: 0.55, green: 0.58, blue: 0.75)
}

/// Full-screen backdrop matching the icon.
struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.indigo, Theme.midnight],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 30 / 255, green: 70 / 255, blue: 120 / 255).opacity(0.45), .clear],
                           center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// Translucent rounded card used across the main screens.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

extension View {
    func glassCard(radius: CGFloat = 20) -> some View { modifier(GlassCard(radius: radius)) }
}

/// Small capsule tag.
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var color: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let s = systemImage { Image(systemName: s) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundColor(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// One sine period across the rect; `phase` is animatable for a flowing look.
struct WaveShape: Shape {
    var amplitude: CGFloat = 0.14   // fraction of height
    var yOffset: CGFloat = -0.04    // fraction of height from the centre
    var phase: CGFloat = 0
    var cycles: CGFloat = 1

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = 72
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let x = r.minX + t * r.width
            let y = r.midY + r.height * (yOffset + amplitude * sin(t * 2 * .pi * cycles + phase))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

/// Vector version of the app icon's mark: portal ring crossed by a ribbon.
struct LogoMark: View {
    var body: some View {
        GeometryReader { g in
            mark(size: min(g.size.width, g.size.height))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func mark(size s: CGFloat) -> some View {
        ZStack {
            // Ring with a transparent gap where the ribbon passes (weave).
            ZStack {
                Circle()
                    .stroke(LinearGradient(colors: [Theme.violet, Theme.cyan],
                                           startPoint: .leading, endPoint: .trailing),
                            lineWidth: s * 0.08)
                    .padding(s * 0.1)
                WaveShape()
                    .stroke(Color.black, style: StrokeStyle(lineWidth: s * 0.2, lineCap: .round))
                    .padding(.horizontal, s * 0.04)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            WaveShape()
                .stroke(LinearGradient(colors: [Theme.teal, Theme.sky],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: s * 0.11, lineCap: .round))
                .padding(.horizontal, s * 0.04)
        }
        .frame(width: s, height: s)
    }
}
