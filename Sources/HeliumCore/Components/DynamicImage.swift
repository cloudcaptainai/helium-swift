import Foundation
import SwiftUI
import Kingfisher
import SwiftyJSON

public struct DynamicImage: View {
    private let imageSource: ImageSource
    private let tintColor: ColorConfig?
    
    public init(json: JSON) {
        if json["isSystemImage"].boolValue {
            self.imageSource = .system(name: json["systemImageName"].stringValue)
        } else {
            self.imageSource = .url(json["imageURL"].stringValue)
        }
        
        if json["tintColor"] != JSON.null {
            self.tintColor = ColorConfig(json: json["tintColor"])
        } else {
            self.tintColor = nil
        }
    }
    
    public var body: some View {
        Group {
            switch imageSource {
            case .url(let urlString):
                KFImage(URL(string: urlString))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .system(let name):
                Image(systemName: name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .modifyForegroundColor(with: tintColor)
    }
}

private enum ImageSource {
    case url(String)
    case system(name: String)
}

extension View {
    func modifyForegroundColor(with colorConfig: ColorConfig?) -> some View {
        Group {
            if let colorConfig = colorConfig {
                self.foregroundColor(Color(colorConfig: colorConfig))
            } else {
                self
            }
        }
    }
}

