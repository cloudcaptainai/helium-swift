//
//  DynamicButton.swift
//  interactivity-manager
//
//  Created by Anish Doshi on 8/22/24.
//

import Foundation

import SwiftUI

public struct DynamicButtonComponent: View {
    let buttonTextComponents: [JSON]
    let action: () -> Void
    let width: CGFloat
    let height: CGFloat
    let backgroundColor: Color
    let cornerRadius: CGFloat
    
    public init(json: JSON, action: @escaping () -> Void) {
        self.buttonTextComponents = json["buttonTextComponents"].arrayValue
        self.action = action
        self.width = CGFloat(json["width"].doubleValue)
        self.height = CGFloat(json["height"].doubleValue)
        self.backgroundColor = Color(hex: json["backgroundColor"].stringValue)
        self.cornerRadius = CGFloat(json["cornerRadius"].doubleValue)
    }
    
    public var body: some View {
        Button(action: action) {
            DynamicTextComponent(json: JSON(["components": buttonTextComponents]))
                .background(backgroundColor)
                .cornerRadius(cornerRadius)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

