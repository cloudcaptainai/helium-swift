//
//  File.swift
//  
//
//  Created by Anish Doshi on 9/5/24.
//

import Foundation
import SwiftUI

// DynamicSpacer
public struct DynamicSpacer: View {
    let minLength: CGFloat?
    
    public init(json: JSON) {
        self.minLength = json["minLength"].double.map { CGFloat($0) }
    }
    
    public var body: some View {
        Spacer(minLength: minLength)
    }
}
