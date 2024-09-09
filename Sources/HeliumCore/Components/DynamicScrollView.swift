//
//  File.swift
//  
//
//  Created by Anish Doshi on 9/5/24.
//
import SwiftUI
import SwiftyJSON

import Foundation

// DynamicScrollView
public struct DynamicScrollView<Content: View>: View {
    let axes: Axis.Set
    let showsIndicators: Bool
    let content: Content
    
    public init(json: JSON, @ViewBuilder content: () -> Content) {
        self.axes = json["axes"].string == "vertical" ? .vertical : .horizontal
        self.showsIndicators = json["showsIndicators"].boolValue
        self.content = content()
    }
    
    public var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content
        }
    }
}
