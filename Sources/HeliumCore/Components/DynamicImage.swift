//
//  DynamicImage.swift
//  interactivity-manager
//
//  Created by Anish Doshi on 8/22/24.
//

import Foundation
import SwiftUI
import Kingfisher
import SwiftyJSON

public struct DynamicImage: View {
    private let imageURL: String
    private let frameSize: CGSize
    private let cornerRadius: CGFloat
    private let borderWidth: CGFloat
    private let borderColor: Color
    private let shadowRadius: CGFloat
    private let shadowColor: Color
    private let shadowOffset: CGSize
    
    public init(json: JSON) {
        self.imageURL = json["imageURL"].stringValue
        self.frameSize = CGSize(
            width: json["frameSize"]["width"].doubleValue,
            height: json["frameSize"]["height"].doubleValue
        )
        self.cornerRadius = json["cornerRadius"].doubleValue
        self.borderWidth = json["borderWidth"].doubleValue
        self.borderColor = Color(hex: json["borderColor"].stringValue)
        self.shadowRadius = json["shadowRadius"].doubleValue
        self.shadowColor = Color(hex: json["shadowColor"].stringValue)
        self.shadowOffset = CGSize(
            width: json["shadowOffset"]["width"].doubleValue,
            height: json["shadowOffset"]["height"].doubleValue
        )
    }
    
    public var body: some View {
        KFImage(URL(string: imageURL))
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: frameSize.width, height: frameSize.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: shadowOffset.width, y: shadowOffset.height)
    }
}

