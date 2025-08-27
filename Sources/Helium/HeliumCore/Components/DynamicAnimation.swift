import SwiftUI

public struct DynamicAnimation: View {
    let animationType: AnimationType
    let libraryAnimation: LibraryAnimation?
    
    init(json: JSON) {
        if json["type"].stringValue == "library" {
            self.animationType = .library
            self.libraryAnimation = LibraryAnimation(json: json["animationProps"])
        } else {
            self.animationType = .lottie
            self.libraryAnimation = nil
        }
    }
    
    public var body: some View {
        switch animationType {
        case .library:
            if let libraryAnimation = libraryAnimation {
                switch libraryAnimation.name {
                case .sparkles:
                    Sparkles(sparkleData: libraryAnimation.sparkleData)
                }
            }
        case .lottie:
            // Placeholder for Lottie animation
            EmptyView()
        }
    }
}

enum AnimationType {
    case library
    case lottie
}

struct LibraryAnimation {
    let name: LibraryAnimationName
    let sparkleData: [(CGFloat, CGFloat, CGFloat)]
    
    init(json: JSON) {
        self.name = LibraryAnimationName(rawValue: json["name"].stringValue) ?? .sparkles
        self.sparkleData = json["sparkleData"].arrayValue.map { dataPoint in
            (CGFloat(dataPoint[0].doubleValue),
             CGFloat(dataPoint[1].doubleValue),
             CGFloat(dataPoint[2].doubleValue))
        }
    }
}

enum LibraryAnimationName: String {
    case sparkles = "Sparkles"
}
