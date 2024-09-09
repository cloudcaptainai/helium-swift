//
//  Sparkles.swift
//  interactivity-manager
//
//  Created by Anish Doshi on 8/21/24.
//

import SwiftUI


public struct StarShape: Shape {
    public func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let innerRadius = radius * 0.4
        var path = Path()

        for i in 0..<4 {
            let angle = Angle(degrees: Double(i) * 90)
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle.radians)) * radius,
                y: center.y + CGFloat(sin(angle.radians)) * radius
            )
            let innerPoint = CGPoint(
                x: center.x + CGFloat(cos(angle.radians + .pi/4)) * innerRadius,
                y: center.y + CGFloat(sin(angle.radians + .pi/4)) * innerRadius
            )

            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
            path.addLine(to: innerPoint)
        }
        path.closeSubpath()
        return path
    }
}

public struct Sparkle: View {
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.5
    @State private var rotation: Double = 0

    
    public var body: some View {
        StarShape()
            .fill(Color.white)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .opacity(opacity)
            .rotationEffect(Angle(degrees: rotation))
            .position(x: x, y: y)
            .onReceive(timer) { _ in
                withAnimation(Animation.easeInOut(duration: Double.random(in: 0.3...0.7))) {
                    self.scale = CGFloat.random(in: 0.5...1.5)
                    self.opacity = Double.random(in: 0.5...1.0)
                    self.rotation = Double.random(in: -15...15)
                }
            }
    }
}

public struct Sparkles: View {
    public var sparkleData: [(CGFloat, CGFloat, CGFloat)]
    public init(sparkleData: [(CGFloat, CGFloat, CGFloat)]) {
        self.sparkleData = sparkleData
    }
    public var body: some View {
        GeometryReader { geometry in
            ForEach(0..<sparkleData.count, id: \.self) { index in
                Sparkle(
                    x: geometry.size.width * sparkleData[index].0,
                    y: geometry.size.height * sparkleData[index].1,
                    size: sparkleData[index].2
                )
            }
        }
    }
}

