import Foundation
import SwiftUI



@available(iOS 15.0, *)
public struct DynamicImage: View {
    private let imageSource: ImageSource
    private let tintColor: ColorConfig?
    private let isResizable: Bool
    private let aspectRatio: AspectRatioConfig?
    private let frame: FrameConfig?
    
    public init(json: JSON) {
        if json["isSystemImage"].boolValue {
            self.imageSource = .system(name: json["systemImageName"].stringValue)
        } else if json["isLocalImage"].boolValue {
            self.imageSource = .local(name: json["localImageName"].stringValue)
        } else {
            self.imageSource = .url(json["imageURL"].stringValue)
        }
        
        if json["tintColor"] != JSON.null {
            self.tintColor = ColorConfig(json: json["tintColor"])
        } else {
            self.tintColor = nil
        }
        
        self.isResizable = json["isResizable"].boolValue
        
        if json["aspectRatio"] != JSON.null {
            self.aspectRatio = AspectRatioConfig(json: json["aspectRatio"])
        } else {
            self.aspectRatio = nil
        }
        
        if json["frame"] != JSON.null {
            self.frame = FrameConfig(json: json["frame"])
        } else {
            self.frame = nil
        }
    }
    
    public var body: some View {
        Group {
            switch imageSource {
            case .url(let urlString):
                if (isResizable) {
                    AsyncImage(url: URL(string: urlString))
                        .aspectRatioIfNeeded(aspectRatio)
                } else {
                    AsyncImage(url: URL(string: urlString))
                        .aspectRatioIfNeeded(aspectRatio)
                }
            case .system(let name):
                Image(systemName: name)
                    .resizable(isResizable)
                    .aspectRatioIfNeeded(aspectRatio)
            case .local(let name):
                Image(uiImage: UIImage(named: name) ?? UIImage())
                    .resizable(isResizable)
                    .aspectRatioIfNeeded(aspectRatio)
            }
        }
        .modifyForegroundColor(with: tintColor)
        .frame(width: frame?.width, height: frame?.height)
    }
}

private enum ImageSource {
    case url(String)
    case system(name: String)
    case local(name: String)
}

struct AspectRatioConfig {
    let contentMode: SwiftUI.ContentMode
    
    init(json: JSON) {
        switch json["contentMode"].stringValue.lowercased() {
        case "fit":
            self.contentMode = .fit
        case "fill":
            self.contentMode = .fill
        default:
            self.contentMode = .fit
        }
    }
}

struct FrameConfig {
    let width: CGFloat?
    let height: CGFloat?
    
    init(json: JSON) {
        self.width = json["width"].double.map { CGFloat($0) }
        self.height = json["height"].double.map { CGFloat($0) }
    }
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
    
    func aspectRatioIfNeeded(_ config: AspectRatioConfig?) -> some View {
        Group {
            if let config = config {
                self.aspectRatio(contentMode: config.contentMode)
            } else {
                self
            }
        }
    }
}

extension Image {
    func resizable(_ isResizable: Bool) -> some View {
        if isResizable {
            return AnyView(self.resizable())
        } else {
            return AnyView(self)
        }
    }
}
