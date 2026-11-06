import SwiftUI
import UIKit

enum FormFlowTheme {
    static let forest = Color(red: 23 / 255, green: 33 / 255, blue: 27 / 255)
    static let lime = Color(red: 216 / 255, green: 255 / 255, blue: 82 / 255)

    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 23 / 255, green: 33 / 255, blue: 27 / 255, alpha: 1)
            : UIColor(red: 246 / 255, green: 242 / 255, blue: 233 / 255, alpha: 1)
    })

    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 216 / 255, green: 255 / 255, blue: 82 / 255, alpha: 1)
            : UIColor(red: 41 / 255, green: 78 / 255, blue: 45 / 255, alpha: 1)
    })
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .foregroundStyle(FormFlowTheme.forest)
            .background(FormFlowTheme.lime, in: RoundedRectangle(cornerRadius: 16))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

extension View {
    func formFlowBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(FormFlowTheme.canvas)
    }
}
