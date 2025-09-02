//
//  iOSDelegation.swift
//  Segment
//
//  Created by Brandon Sneed on 4/7/21.
//

import Foundation

#if os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)

import UIKit

// MARK: - Remote Notifications

protocol RemoteNotifications: Plugin {
    func declinedRemoteNotifications()
    func registeredForRemoteNotifications(deviceToken: Data)
    func failedToRegisterForRemoteNotification(error: Error?)
    func receivedRemoteNotification(userInfo: [AnyHashable: Any])
    func handleAction(identifier: String, userInfo: [String: Any])
}

extension RemoteNotifications {
    func declinedRemoteNotifications() {}
    func registeredForRemoteNotifications(deviceToken: Data) {}
    func failedToRegisterForRemoteNotification(error: Error?) {}
    func receivedRemoteNotification(userInfo: [AnyHashable: Any]) {}
    func handleAction(identifier: String, userInfo: [String: Any]) {}
}

extension Analytics {
    func declinedRemoteNotifications() {
        apply { plugin in
            if let p = plugin as? RemoteNotifications {
                p.declinedRemoteNotifications()
            }
        }
    }
    func registeredForRemoteNotifications(deviceToken: Data) {
        setDeviceToken(deviceToken.hexString)
        
        apply { plugin in
            if let p = plugin as? RemoteNotifications {
                p.registeredForRemoteNotifications(deviceToken: deviceToken)
            }
        }
    }
    
    func failedToRegisterForRemoteNotification(error: Error?) {
        apply { plugin in
            if let p = plugin as? RemoteNotifications {
                p.failedToRegisterForRemoteNotification(error: error)
            }
        }
    }
    
    func receivedRemoteNotification(userInfo: [AnyHashable: Any]) {
        apply { plugin in
            if let p = plugin as? RemoteNotifications {
                p.receivedRemoteNotification(userInfo: userInfo)
            }
        }
    }
    
    func handleAction(identifier: String, userInfo: [String: Any]) {
        apply { plugin in
            if let p = plugin as? RemoteNotifications {
                p.handleAction(identifier: identifier, userInfo: userInfo)
            }
        }
    }
}

// MARK: - User Activity

protocol UserActivities {
    func continueUserActivity(_ activity: NSUserActivity)
}

extension UserActivities {
    func continueUserActivity(_ activity: NSUserActivity) {}
}

extension Analytics {
    func continueUserActivity(_ activity: NSUserActivity) {
        apply { plugin in
            if let p = plugin as? UserActivities {
                p.continueUserActivity(activity)
            }
        }
        
        if activity.activityType == NSUserActivityTypeBrowsingWeb {
            if let url = activity.webpageURL {
                openURL(url, options: ["title": activity.title ?? ""])
            }
        }
    }
    
    func openURL(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
        var converted: [String: Any] = [:]
        for (key, value) in options {
            converted[String(describing:key)] = value
        }
        openURL(url, options: converted)
    }
}

#endif
