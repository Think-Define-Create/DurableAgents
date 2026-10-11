import SwiftUI

/// Colors for the chat and list chrome. Bubbles follow the system light and dark appearance.
enum Palette {
    static let background = Color(light: Color(white: 0.985), dark: Color(white: 0.04))
    static let card = Color(light: Color(white: 0.945), dark: Color(white: 0.13))
    static let userBubble = Color(light: Color(white: 0.07), dark: Color(white: 0.93))
    static let userText = Color(light: .white, dark: .black)
    static let secondaryText = Color(light: Color(white: 0.55), dark: Color(white: 0.6))
}

extension Color {
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}

/// How a bot looks in lists and chat headers. Stored by the app, not in the journal.
struct BotLook: Codable, Equatable, Sendable {
    var tint: Int
    var shape: Int

    static let tints: [Color] = [
        Color(red: 0.95, green: 0.62, blue: 0.22),
        Color(red: 0.93, green: 0.25, blue: 0.27),
        Color(red: 0.25, green: 0.51, blue: 0.96),
        Color(red: 0.92, green: 0.29, blue: 0.60),
        Color(red: 0.53, green: 0.36, blue: 0.22),
        Color(red: 0.42, green: 0.42, blue: 0.43),
        Color(red: 0.20, green: 0.68, blue: 0.45),
        Color(red: 0.55, green: 0.36, blue: 0.86),
    ]

    static let shapeCount = 4

    var color: Color { Self.tints[tint % Self.tints.count] }

    /// A stable look for a bot that was created before looks were stored.
    static func derived(from id: String) -> BotLook {
        let sum = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return BotLook(tint: sum % tints.count, shape: (sum / tints.count) % shapeCount)
    }
}

/// A soft colored blob with two eyes.
struct BlobAvatar: View {
    var look: BotLook
    var size: CGFloat

    var body: some View {
        ZStack {
            shape.fill(look.color)
            HStack(spacing: size * 0.1) {
                eye
                eye
            }
            .offset(x: size * 0.06, y: -size * 0.1)
        }
        .frame(width: size, height: look.shape == 1 ? size * 0.66 : size)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var eye: some View {
        Capsule()
            .fill(.white)
            .frame(width: size * 0.07, height: size * 0.2)
            .rotationEffect(.degrees(-18))
    }

    private var shape: AnyShape {
        switch look.shape % BotLook.shapeCount {
        case 0: AnyShape(Circle())
        case 1: AnyShape(Capsule())
        case 2: AnyShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        default: AnyShape(CloudShape())
        }
    }
}

/// Three overlapping lobes, used for the featured bot.
struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.addEllipse(in: CGRect(x: 0, y: h * 0.32, width: w * 0.62, height: h * 0.62))
        path.addEllipse(in: CGRect(x: w * 0.18, y: h * 0.06, width: w * 0.58, height: h * 0.62))
        path.addEllipse(in: CGRect(x: w * 0.42, y: h * 0.28, width: w * 0.58, height: h * 0.62))
        return path
    }
}

/// A round floating button, glass where the system supports it.
struct RoundButton<Label: View>: View {
    var size: CGFloat = 46
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassCircle())
    }
}

struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

/// Short relative day labels like the list in Messages: a time today, then a weekday, then a date.
enum DayLabel {
    static func text(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

extension View {
    /// Inline navigation titles on iOS. macOS has no inline mode.
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Hides the system bar where a screen draws its own floating header.
    func hidesNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}
