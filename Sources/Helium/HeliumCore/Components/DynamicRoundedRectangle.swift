import SwiftUI

public struct DynamicRoundedRectangle: View {
    var fillColor: ColorConfig? = nil
    var strokeColor: ColorConfig? = nil
    var cornerRadius: CGFloat? = 0
    var strokeWidth: CGFloat? = 1
    var inset: CGFloat? = 0  // New inset property
    
    init(json: JSON) {
        if (json["fillColor"].exists()) {
            self.fillColor = ColorConfig(json: json["fillColor"])
        }
        if (json["strokeColor"].exists()) {
            self.strokeColor = ColorConfig(json: json["strokeColor"])
        }
        if (json["strokeWidth"].exists()) {
            self.strokeWidth = CGFloat(json["strokeWidth"].doubleValue)
        }
        if (json["cornerRadius"].exists()) {
            self.cornerRadius = CGFloat(json["cornerRadius"].doubleValue)
        }
        if (json["inset"].exists()) {  // New inset initialization
            self.inset = CGFloat(json["inset"].doubleValue)
        }
    }
    
    public var body: some View {
        if (self.fillColor != nil) {
            RoundedRectangle(cornerRadius: self.cornerRadius!)
                .inset(by: self.inset ?? 0)  // Apply inset
                .fill(Color(hex: self.fillColor!.colorHex, opacity: self.fillColor!.opacity))
        } else if (self.strokeColor != nil) {
            RoundedRectangle(cornerRadius: self.cornerRadius!)
                .inset(by: self.inset ?? 0)  // Apply inset
                .stroke(Color(hex: self.strokeColor!.colorHex, opacity: self.strokeColor!.opacity), lineWidth: self.strokeWidth!)
        } else {
            RoundedRectangle(cornerRadius: self.cornerRadius!)
                .inset(by: self.inset ?? 0)  // Apply inset
        }
    }
}
