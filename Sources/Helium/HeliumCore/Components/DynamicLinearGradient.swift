//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/22/24.
//

import Foundation
import SwiftUI
import SwiftyJSON

public struct DynamicLinearGradient: View {
    private let stops: [Gradient.Stop]
    private let startPoint: UnitPoint
    private let endPoint: UnitPoint
    private let ignoresSafeArea: Bool
    private let ignoredSafeAreaEdges: Edge.Set
    
    public init(json: JSON) {
        self.stops = json["stops"].arrayValue.map { stopJson in
            let color = Color(
                red: stopJson["color"]["red"].doubleValue,
                green: stopJson["color"]["green"].doubleValue,
                blue: stopJson["color"]["blue"].doubleValue
            )
            let location = stopJson["location"].doubleValue
            return Gradient.Stop(color: color, location: location)
        }
        
        self.startPoint = UnitPoint(
            x: json["startPoint"]["x"].doubleValue,
            y: json["startPoint"]["y"].doubleValue
        )
        
        self.endPoint = UnitPoint(
            x: json["endPoint"]["x"].doubleValue,
            y: json["endPoint"]["y"].doubleValue
        )
        
        self.ignoresSafeArea = json["ignoresSafeArea"].boolValue
        if let edges = json["ignoredSafeAreaEdges"].arrayObject as? [String] {
            self.ignoredSafeAreaEdges = Edge.Set(edges.compactMap { stringValue in
                switch stringValue.lowercased() {
                case "leading":
                    return .leading
                case "trailing":
                    return .trailing
                case "top":
                    return .top
                case "bottom":
                    return .bottom
                default:
                    return nil
                }
            })
        } else {
            self.ignoredSafeAreaEdges = .all
        }
    }
    
    public var body: some View {
        LinearGradient(
            stops: stops,
            startPoint: startPoint,
            endPoint: endPoint
        )
        .modifier(SafeAreaIgnoringModifier(ignoresSafeArea: ignoresSafeArea, edges: ignoredSafeAreaEdges))
    }
}

private struct SafeAreaIgnoringModifier: ViewModifier {
    let ignoresSafeArea: Bool
    let edges: Edge.Set
    
    func body(content: Content) -> some View {
        if ignoresSafeArea {
            content.edgesIgnoringSafeArea(edges)
        } else {
            content
        }
    }
}
