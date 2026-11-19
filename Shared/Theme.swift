import SwiftUI
import UIKit

enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static let blue = dyn(0x2C6E9B, 0x6FB1E0)
    static let navy = Color(UIColor(hex: 0x1F4E79))
    static let background = dyn(0xFFFFFF, 0x1C1C1E)
    static let green = Color(UIColor(hex: 0x2A893D))
    static let orange = Color(UIColor(hex: 0xE8890C))
    static let red = Color(UIColor(hex: 0xD0312D))
    /// Route line colour on the map (navy in light mode, lighter blue in dark mode).
    static let route = dyn(0x1F4E79, 0x5AA3D9)

    static func color(_ l: StatusLevel) -> Color {
        switch l { case .onTime: return green; case .delayed: return orange; case .late: return red }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

