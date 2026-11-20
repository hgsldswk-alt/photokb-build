import SwiftUI

enum Theme {
    static let ink = Color(red: 18 / 255, green: 27 / 255, blue: 45 / 255)
    static let muted = Color(red: 80 / 255, green: 96 / 255, blue: 121 / 255)
    static let paper = Color(red: 249 / 255, green: 250 / 255, blue: 1)
    static let border = Color(red: 216 / 255, green: 224 / 255, blue: 238 / 255)
    static let blue = Color(red: 36 / 255, green: 72 / 255, blue: 192 / 255)
    static let soft = Color(red: 232 / 255, green: 237 / 255, blue: 252 / 255)
}

enum ActionStyle: ButtonStyle, Equatable {
    case primary, secondary, quiet, menu, preset, selected

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(self == .primary || self == .secondary ? .body.weight(.bold) : .subheadline.weight(.bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(self == .primary ? .white : Theme.blue)
            .padding(.horizontal, self == .menu ? 12 : 8)
            .padding(.vertical, 7)
            .frame(maxWidth: self == .menu ? nil : .infinity)
            .frame(minHeight: self == .primary || self == .secondary ? 50 : 44)
            .background(background, in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                if self == .secondary || self == .preset || self == .selected {
                    RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.border)
                }
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }

    private var background: Color {
        switch self {
        case .primary: return Theme.blue
        case .secondary, .preset: return .white
        case .quiet: return .clear
        case .menu, .selected: return Theme.soft
        }
    }
}

struct Card<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 23))
            .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(highlighted ? Theme.blue.opacity(0.28) : Theme.border) }
    }
}

struct PageHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L.t(title)).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(L.t(subtitle)).font(.subheadline).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActionPair<First: View, Second: View>: View {
    @Environment(\.dynamicTypeSize) private var type
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    var body: some View {
        let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            first
            second
        }
    }
}

struct Fact: View {
    let label: String
    let value: String
    var localized = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized ? L.t(label) : label).foregroundStyle(Theme.muted)
                Spacer(minLength: 12)
                Text(value).monospacedDigit().multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(localized ? L.t(label) : label).foregroundStyle(Theme.muted)
                Text(value).monospacedDigit()
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

struct Notice: View {
    let text: String
    var isShare = false

    var body: some View {
        Text(text)
            .accessibilityIdentifier(isShare ? "share.requested" : "status.notice")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.blue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension View {
    func shareSheet(_ model: PhotoModel) -> some View {
        sheet(item: Binding(get: { model.share }, set: { model.share = $0 })) { request in
            SystemShare(request: request) { completed in model.finishShare(request, completed: completed) }
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
    }
}
