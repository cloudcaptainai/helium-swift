//
//  File.swift
//
//
//  Created by Anish Doshi on 8/26/24.
//

import Foundation

import SwiftUI

public struct AdaptiveSheet<SheetContent: View>: ViewModifier {
    let sheetContent: SheetContent
    @Binding var isPresented: Bool
    let heightFraction: CGFloat
    
    init(isPresented: Binding<Bool>, heightFraction: CGFloat, @ViewBuilder content: @escaping () -> SheetContent) {
        self._isPresented = isPresented
        self.heightFraction = heightFraction
        self.sheetContent = content()
    }
    
    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                if #available(iOS 16.4, *) {
                    sheetContent
                        .presentationDetents([.fraction(heightFraction)])
                        .presentationBackground(.clear)
                } else {
                    GeometryReader { geometry in
                        VStack {
                            Spacer()
                            sheetContent
                                .frame(height: geometry.size.height * heightFraction)
                        }
                    }
                    .background(Color.clear)
                    .edgesIgnoringSafeArea(.all)
                }
            }
    }
}


public extension View {
    func adaptiveSheet<Content: View>(
        isPresented: Binding<Bool>,
        heightFraction: CGFloat = 0.45,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.modifier(AdaptiveSheet(isPresented: isPresented, heightFraction: heightFraction, content: content))
    }
}
