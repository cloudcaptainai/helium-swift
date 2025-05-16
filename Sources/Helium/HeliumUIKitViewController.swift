//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/20/24.
//

import Foundation
import SwiftUI
import UIKit

public class HeliumPaywallPresentationState: ObservableObject {
    @Published var isFullyPresented = false
}

class HeliumViewController: UIViewController {
    private let contentView: AnyView
    let presentationState = HeliumPaywallPresentationState()
    
    init(contentView: AnyView) {
        self.contentView = AnyView(contentView
            .environmentObject(presentationState))
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let modalView = UIHostingController(rootView: contentView)
        addChild(modalView)
        view.addSubview(modalView.view)
        modalView.view.frame = view.bounds
        modalView.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        modalView.didMove(toParent: self)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
            self?.presentationState.isFullyPresented = true
        }
    }
    
    // Only allow portrait paywalls for now
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }
    
}
