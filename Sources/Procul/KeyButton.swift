import SwiftUI

/// A remote button. Fires `tap` on release, or `hold` once the press has
/// lasted long enough. A repeating button fires `tap` again and again
/// while it is held, the way a volume key does.
struct KeyButton<S: Shape, Label: View>: View {
    enum Held {
        case nothing
        case action(() -> Void)
        case repeats
    }

    let shape: S
    let help: String
    var held: Held = .nothing
    let tap: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var pressing = false
    @State private var fired = false
    @State private var timer: Timer?

    private static var holdDelay: TimeInterval { 0.45 }
    private static var repeatInterval: TimeInterval { 0.16 }

    var body: some View {
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(Color.primary.opacity(pressing ? 0.24 : 0.09)))
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed() }
                    .onEnded { _ in released() }
            )
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
    }

    private func pressed() {
        guard !pressing else { return }
        pressing = true
        fired = false
        switch held {
        case .nothing:
            break
        case .action(let action):
            timer = .scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { _ in
                fired = true
                action()
            }
        case .repeats:
            timer = .scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { _ in
                fired = true
                tap()
                timer = .scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { _ in tap() }
            }
        }
    }

    private func released() {
        timer?.invalidate()
        timer = nil
        pressing = false
        if !fired { tap() }
    }
}

/// A quarter of the ring around the select button, centred on `angle`.
struct Sector: Shape {
    var angle: Angle
    var inner: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = angle - .degrees(45)
        let end = angle + .degrees(45)
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: radius * inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}
