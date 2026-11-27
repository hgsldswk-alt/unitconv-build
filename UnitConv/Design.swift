import SwiftUI

enum Design {
    static let ink = Color(red: 23/255, green: 41/255, blue: 34/255)
    static let subtle = Color(red: 82/255, green: 102/255, blue: 93/255)
    static let green = Color(red: 18/255, green: 98/255, blue: 78/255)
    static let tint = Color(red: 227/255, green: 239/255, blue: 233/255)
    static let paper = Color(red: 246/255, green: 248/255, blue: 246/255)
    static let line = Color(red: 219/255, green: 230/255, blue: 223/255)
}

struct ActionStyle: ButtonStyle {
    var primary = false

    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(primary ? Color.white : Design.green)
            .background(primary ? Design.green : Color.white, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(primary ? Color.clear : Design.line))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

struct CardSurface: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.white, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Design.line).allowsHitTesting(false))
    }
}

extension View {
    func cardSurface(_ radius: CGFloat) -> some View { modifier(CardSurface(radius: radius)) }
}
