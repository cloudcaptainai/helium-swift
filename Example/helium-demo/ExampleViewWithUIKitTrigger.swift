//
//  ExampleViewWithUIKitTrigger.swift
//  helium-demo
//
//  Created by Anish Doshi on 8/20/24.
//

import SwiftUI
import Helium

struct ExampleViewWithUIKitTrigger: View {
    @State var isPresented: Bool = false
    var body: some View {
        VStack {
            Button {
                isPresented = true;
                Helium.shared.presentUpsell(trigger: "");
            } label: {
                Text("Show paywall")
            }
        }
    }
}

#Preview {
    ExampleViewWithUIKitTrigger()
}
