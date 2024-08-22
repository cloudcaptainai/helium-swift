## **Background**

Thanks for getting started with Helium 🎈

Helium is an upsell creation and optimization tool for mobile apps. We take your existing payalls (or help you create new ones!) in native code (SwiftUI),
and then we help you turn them into remotely controllable templates that you can edit, experiment, and optimize without waiting
for new app releases. See our [launch post](https://www.ycombinator.com/launches/LXq-helium-improve-your-paywall-at-the-speed-of-thought) for more info.

Email founders@tryhelium.com, or text/call @Anish Doshi at any time at 224-770-0305 for any help/questions.


## **How it works**

To get started, book a quick session with us [here](cal.com/anishdoshi/chat). 

- During this (15-20) minute meeting, we'll chat about your app, monetization goals, and tech stack.
- We'll take in your existing paywalls (or help you migrate them from 3rd party services), and then create handcrafted, native code paywall + upsell screens using best practices we've learned from 10 years of growth product experience @ Uber, Meta, and Apple.
- We provide an SDK that helps you trigger these paywalls from anywhere in your app. Right now, we support iOS (SwiftUI + UIKit), with other frameworks coming very soon.
- We onboard these paywalls into a service that lets you remotely configurate, test, and optimize them. 

## **Installation**

Install **helium-swift** via SPM. In Xcode, go to “Add Package Dependencies”, and copy in [`https://github.com/cloudcaptainai/helium-swift`](https://github.com/cloudcaptainai/helium-swift)

Select “Up to next Major Version” with minimum version set to **1.0.0** and maximum set to **2.0.0**

- About this package
    
    **helium-swift** is our open source SDK for SwiftUI. It contains general initialization code that hooks up to our backend, and the view modifier logic.
    

## Configuration

### Set up your HeliumPaywallDelegate

Helium doesn’t handle subscription logic [yet]. To integrate Helium paywalls with your subscription logic, first create a subclass of `HeliumPaywallDelegate` 

```swift
import Helium
import HeliumCore

public enum HeliumPaywallTransactionStatus {
		// if the subscription succeeded
    case purchased
    
    // if the subscription was cancelled
    case cancelled
    
    // if the subscription was abandoned
    case abandoned
    
    // if the subscription failed with another error
    case failed(Error)
    
    // if the user restored their subscription
    case restored
    
    // if the subscription is 'pending' (requires action from developer)
    case pending
}

public protocol HeliumPaywallDelegate: AnyObject {
		// [REQUIRED] - Actually make the purchase 
    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus
}

extension HeliumPaywallDelegate {
		// [OPTIONAL] Custom analytics/error logging for paywall/helium
		// related events can be added here. 
		// By default, we log events to Amplitude
    public func onHeliumPaywallEvent(event: HeliumPaywallEvent) {}
} 
```

### Example Delegate:

Here’s an example that uses StoreKit’s basic Product.purchase() method.

```swift
import Helium
import HeliumCore

class DemoHeliumPaywallDelegate: HeliumPaywallDelegate {
    var subscriptions: [Product]
    
    public init() {
        self.subscriptions = []
        Task {
            do {
                let products = try await Product.products(for: ["yearly_sub_subscription", "monthly_sub_id"])
                self.subscriptions = products
            } catch {
                print("failed to load subscriptions")
            }
        }
    }
    
    func makePurchase(productId: String) async -> HeliumCore.HeliumPaywallTransactionStatus {
        do {
            let result = try await self.subscriptions[1].purchase();
            switch (result) {
                case .success(let result):
                    return .purchased;
                case .userCancelled:
                    return .cancelled;
                case .pending:
                    return .pending
                @unknown default:
                    return .failed(NSError(domain:"", code: 401, userInfo:[ NSLocalizedDescriptionKey: "Unknown error making purchase"]))
            }
        } catch {
            return .failed(error)
        }
    }
}

```

### Initialize Helium and Download Paywall Configs

Somewhere in your app’s initialization code (e.g. your `main App` if using SwiftUI, or `AppDelegate` if using ViewController),

add the following line in an async context to actually download paywall config/variants.

```swift
await Helium.shared.initializeAndFetchVariants(
	// you'll get this from Helium founders during setup!
    apiKey: "<your-helium-api-key>",
        
    // The delegate you created earlier.
    heliumPaywallDelegate: YourHeliumPaywallDelegate(),
    
    // Whether or not to cache the upsell experience on device after fetching it.
    // Turn this off to enable experimentation and optimization over paywalls.
    useCache: false
)
```

Here’s a full example, using the demo paywall delegate from above.

```swift
import Helium
import HeliumCore

@main
struct helium_demoApp: App {
    
    init() {
        Task {
            let delegate = DemoHeliumPaywallDelegate()
            
            await Helium.shared.initializeAndFetchVariants(
                apiKey: "<your-helium-api-key>",
                heliumPaywallDelegate: delegate,
                useCache: true
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

## Usage

Now, anywhere in your SwiftUI app, you can use the `triggerUpsell` modifier to (conditionally) trigger a Helium paywall!

- You don’t actually specify the paywall version name here - we load that from the backend.
- What *is* specified is a “trigger name”. These trigger names should be **unique** across your app. User interactions with paywalls will be tracked and used to optimize the paywall for each trigger.

```swift
struct ContentView: View {
    @State var isPresented: Bool = false
    var body: some View {
        VStack {
            Button {
                isPresented = true;
            } label: {
                Text("Show paywall")
            }

        }.triggerUpsell(isPresented: $isPresented, trigger: "showPaywallPress")
    }
}
```

## Testing

Now, anywhere in your SwiftUI app, you can use the `triggerUpsell` modifier to (conditionally) trigger a Helium paywall!

- You don’t actually specify the paywall version name here - we load that from the backend.
- What *is* specified is a “trigger name”. These trigger names should be **unique** across your app. User interactions with paywalls will be tracked and used to optimize the paywall for each trigger.
