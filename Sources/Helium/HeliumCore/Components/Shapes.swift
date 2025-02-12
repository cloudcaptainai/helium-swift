//
//  Shapes.swift
//  interactivity-manager
//
//  Created by Anish Doshi on 8/21/24.
//

import Foundation
import SwiftUI

public struct RoundedCorner: Shape {
    let radius: CGFloat
    let corners: UIRectCorner

    init(radius: CGFloat = .infinity, corners: UIRectCorner = .allCorners) {
        self.radius = radius
        self.corners = corners
    }

    public func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

public struct PressableButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.2 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

public struct AnimatedGradientBorder: View {
    @State private var animationOffset: CGFloat = 0

    public var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .inset(by: 2)
            .stroke(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.15, green: 0.75, blue: 0.69),
                        Color(red: 0.65, green: 0.35, blue: 0.89),
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 4
            )
    }
}

public extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape( RoundedCorner(radius: radius, corners: corners) )
    }
}
