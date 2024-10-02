//
//  File.swift
//  
//
//  Created by Anish Doshi on 9/18/24.
//

import Foundation
import SwiftUI

public final class FontDownloader: ObservableObject {
  static func downloadRemoteFont(url: URL) -> CGFont? {
    // Create a data provider that provides data from a URL. This URL
    // can be remote, or local.
    guard let dataProvider = CGDataProvider(url: url as CFURL) else {
      assertionFailure("Unable to create CGDataProvider")
      return nil
    }

    guard let font = CGFont(dataProvider) else {
      assertionFailure("Unable to create font from data provider")
      return nil
    }

    let registrationResult = CTFontManagerRegisterGraphicsFont(font, nil);

    return font
  }
}

public func downloadRemoteFont(fontURL: URL) async -> HeliumAssetLoadStatus {
      // Load font from URL using our FontLoader.
      guard let font = FontDownloader.downloadRemoteFont(url: fontURL) else {
          return .downloadFailed;
      }
    
    guard let postScriptName = font.postScriptName else {
        return .downloadFailed;
    }
    
    return .fontDownloaded(postScriptName: postScriptName);
}


