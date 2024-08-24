//
//  ContentView.swift
//  helium-demo
//
//  Created by Anish Doshi on 8/8/24.
//

import SwiftUI
import Helium

struct ContentView: View {
    @State var isPresented: Bool = false
    var body: some View {
        VStack {
            Button {
                isPresented = true;
            } label: {
                Text("Show paywall")
            }

        }.triggerUpsell(isPresented: $isPresented, trigger: "cameraPress")
    }
}
#Preview {
    ContentView()
}
