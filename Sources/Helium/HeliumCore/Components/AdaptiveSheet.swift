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
    let disableInteractiveDismiss: Bool
    
    init(
        isPresented: Binding<Bool>,
        heightFraction: CGFloat,
        disableInteractiveDismiss: Bool = false,
        @ViewBuilder content: @escaping () -> SheetContent
    ) {
        self._isPresented = isPresented
        self.heightFraction = heightFraction
        self.disableInteractiveDismiss = disableInteractiveDismiss
        self.sheetContent = content()
    }
    
    @ViewBuilder
    private func sheetContent(geometry: GeometryProxy) -> some View {
        VStack {
            Spacer()
            sheetContent
                .frame(height: geometry.size.height * heightFraction)
        }
        .background(Color.clear)
        .edgesIgnoringSafeArea(.all)
    }
    
    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                if #available(iOS 16.4, *) {
                    sheetContent
                        .presentationDetents([.fraction(heightFraction)])
                        .presentationBackground(.clear)
                        .interactiveDismissDisabled(disableInteractiveDismiss)
                } else {
                    GeometryReader { geometry in
                        if #available(iOS 15.0, *) {
                            sheetContent(geometry: geometry)
                                .interactiveDismissDisabled(disableInteractiveDismiss)
                        } else {
                            sheetContent(geometry: geometry)
                        }
                    }
                }
            }
    }
}

public extension View {
    func adaptiveSheet<Content: View>(
        isPresented: Binding<Bool>,
        heightFraction: CGFloat = 0.45,
        disableInteractiveDismiss: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.modifier(AdaptiveSheet(
            isPresented: isPresented,
            heightFraction: heightFraction,
            disableInteractiveDismiss: disableInteractiveDismiss,
            content: content
        ))
    }
}
