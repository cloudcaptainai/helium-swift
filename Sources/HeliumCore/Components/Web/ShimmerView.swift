//
//  File.swift
//  
//
//  Created by Anish Doshi on 1/28/25.
//

import Foundation
import SwiftUI
import SwiftyJSON

struct RelativeDimension {
   let percentage: CGFloat
   var points: CGFloat {
       UIScreen.main.bounds.width * (percentage / 100)
   }
   
   init(from json: JSON) {
       self.percentage = json.doubleValue
   }
}

struct RelativeSize {
   let width: RelativeDimension?
   let height: RelativeDimension
   
   init(from json: JSON) {
       self.width = json["width"].exists() ? RelativeDimension(from: json["width"]) : nil
       self.height = RelativeDimension(from: json["height"])
   }
}

enum ShimmerElement {
   case rectangle(size: RelativeSize, cornerRadius: CGFloat?)
   case circle(diameter: RelativeDimension)
   
   init(from json: JSON) {
       switch json["elementType"].stringValue {
       case "rectangle":
           self = .rectangle(
               size: RelativeSize(from: json),
               cornerRadius: CGFloat(json["cornerRadius"].floatValue)
           )
       case "circle":
           self = .circle(diameter: RelativeDimension(from: json["diameter"]))
       default:
           self = .rectangle(size: RelativeSize(from: json), cornerRadius: nil)
       }
   }
}

enum ShimmerNode {
   case vStack(spacing: CGFloat, content: [ShimmerNode])
   case hStack(spacing: CGFloat, content: [ShimmerNode])
   case element(ShimmerElement)
   
   init(from json: JSON) {
       switch json["type"].stringValue {
       case "vStack":
           let content = json["content"].arrayValue.map { ShimmerNode(from: $0) }
           self = .vStack(spacing: json["spacing"].doubleValue, content: content)
       case "hStack":
           let content = json["content"].arrayValue.map { ShimmerNode(from: $0) }
           self = .hStack(spacing: json["spacing"].doubleValue, content: content)
       case "element":
           self = .element(ShimmerElement(from: json["content"]))
       default:
           self = .vStack(spacing: 0, content: [])
       }
   }
}

public struct Shimmer: ViewModifier {
   @State private var isInitialState = true
   let config: JSON
   
   public func body(content: Content) -> some View {
       buildNode(ShimmerNode(from: config["layout"]))
   }
   
    private func buildNode(_ node: ShimmerNode) -> AnyView {
        switch node {
        case .vStack(let spacing, let content):
            return AnyView(
                VStack(spacing: spacing) {
                    ForEach(content.indices, id: \.self) { idx in
                        buildNode(content[idx])
                    }
                }
            )
        case .hStack(let spacing, let content):
            return AnyView(
                HStack(spacing: spacing) {
                    ForEach(content.indices, id: \.self) { idx in
                        buildNode(content[idx])
                    }
                }
            )
        case .element(let element):
            return AnyView(
                buildElement(element)
                    .mask(shimmerMask())
            )
        }
    }

    private func buildElement(_ element: ShimmerElement) -> AnyView {
        switch element {
        case .rectangle(let size, let cornerRadius):
            return AnyView(
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(
                        width: size.width?.points,
                        height: size.height.points
                    )
                    .cornerRadius(cornerRadius ?? 0)
            )
        case .circle(let diameter):
            return AnyView(
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: diameter.points)
            )
        }
    }
   
   private func shimmerMask() -> some View {
       LinearGradient(
           gradient: .init(colors: [.black.opacity(0.4), .black, .black.opacity(0.4)]),
           startPoint: (isInitialState ? .init(x: -0.3, y: -0.3) : .init(x: 1, y: 1)),
           endPoint: (isInitialState ? .init(x: 0, y: 0) : .init(x: 1.3, y: 1.3))
       )
       .animation(.linear(duration: 1.5).delay(0.25).repeatForever(autoreverses: false), value: isInitialState)
       .onAppear {
           isInitialState = false
       }
   }
}

public extension View {
   @ViewBuilder
   func shimmer(when isLoading: Binding<Bool>, config: JSON) -> some View {
       if isLoading.wrappedValue {
           self.modifier(Shimmer(config: config))
       } else {
           self
       }
   }
}
