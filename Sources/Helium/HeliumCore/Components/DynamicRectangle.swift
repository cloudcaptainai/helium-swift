import SwiftUI

public struct DynamicRectangle: View {
    var foregroundColor: ColorConfig?
    var cornerRadius: CGFloat?
    
    init(json: JSON) {
        if json["foregroundColor"].exists() {
            self.foregroundColor = ColorConfig(json: json["foregroundColor"])
        }
        if json["cornerRadius"].exists() {
            self.cornerRadius = CGFloat(json["cornerRadius"].doubleValue)
        }
    }
    
    public var body: some View {
        Rectangle()
            .foregroundColor(foregroundColor.map { Color(hex: $0.colorHex, opacity: $0.opacity) } ?? .clear)
            .cornerRadius(cornerRadius ?? 0)
    }
}
