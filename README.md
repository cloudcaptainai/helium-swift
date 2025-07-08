### NOTE: For the most up-to-date documentation visit https://docs.tryhelium.com/welcome

## **Background**

Thanks for getting started with Helium 🎈

Helium is an upsell experimentation and optimization platform for mobile apps of all sizes. We take your app’s existing paywalls and turn them into remotely editable templates that you can experiment with and optimize without waiting for new app releases.

Email founders@tryhelium.com for help/questions.


## **Installation**

Install **helium-swift** via SPM. In Xcode, go to "Add Package Dependencies", and copy in [`https://github.com/cloudcaptainai/helium-swift`](https://github.com/cloudcaptainai/helium-swift)

Set the `upToNextMajor` rule to be `2.0.8 < 3.0.0`:

![Dependency Example](/images/ios-dependency.png)

## Configuration

### Set up your HeliumPaywallDelegate

To integrate Helium paywalls, create a subclass of `HeliumPaywallDelegate` or use one of our pre-built delegates. This class is responsible for handling the purchase logic for your paywalls.

```swift
public protocol HeliumPaywallDelegate: AnyObject {

    // [REQUIRED] - Trigger the purchase of a product with the following App Store Connect Product ID.
    // This method should return a HeliumPaywallTransactionStatus enum, described below.
    // Loading states/UI/UX here gets configured in the Helium dashboard, so this method should just trigger the purchase.
    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus

    // [OPTIONAL] - Restore any existing subscriptions.
    // This method should return a boolean indicating whether the restore was successful.
    // This method gets called if you've configured a CTA in the editor to restore purchases, which is recommended.
    func restorePurchases() async -> Bool

    // [OPTIONAL] Custom analytics/error logging for paywall/helium
    // related events can be added here.
    // By default, we log events to your analytics service (Amplitude, etc.), but you can override this method to add additional custom logging/handling.
    // For example, you can log failure events to a Sentry instance, or add custom alerts/notifications on certain paywall events here.
    func onHeliumPaywallEvent(event: HeliumPaywallEvent)
}
```

HeliumPaywallTransactionStatus is an enum that defines the possible states of a paywall transaction.

```swift
import Helium

public enum HeliumPaywallTransactionStatus {
    // if the subscription succeeded
    case purchased
    
    // if the subscription was cancelled
    case cancelled
    
    // if the subscription was abandoned
    case abandoned
    
    // if the subscription failed. Pass in the error as an argument for both logging and downstream handling.
    case failed(Error)
    
    // if the user restored their subscription
    case restored
    
    // if the subscription is 'pending' (requires action from developer)
    case pending
}
```

### Example Delegates:

#### StoreKit 2

Use the StoreKitDelegate to handle purchases using native StoreKit 2:

```swift
import Helium

let delegate = StoreKitDelegate(productIds: [
    "<product-id-1>",
    "<product-id-2>",
])
```

If you would like to implement `onHeliumPaywallEvent`, simply create a subclass of StoreKitDelegate.

#### RevenueCat

```swift
import HeliumRevenueCat

let delegate = RevenueCatDelegate(entitlementId: "<revenue-cat-entitlement-id>")
```

If you would like to implement `onHeliumPaywallEvent`, simply create a subclass of RevenueCatDelegate. Make sure to initialize RevenueCat before initializing Helium or alternatively you can supply your RevenueCat API key to RevenueCatDelegate() and have Helium initialize RevenueCat for you.

### Initialize Helium and Download Paywall Configs

Somewhere in your app's initialization code (e.g. your `main App` if using SwiftUI, or `AppDelegate` if using ViewController), add the following line to actually download paywall config/variants.

_We schedule it on a background thread, so you don't have to worry about it blocking your app's launch time. Helium will automatically retry downloads as needed for up to 90 seconds._

```swift
Helium.shared.initialize(
    // you'll get this from Helium founders during setup!
    apiKey: "<your-helium-api-key>",
        
    // The delegate you created earlier.
    heliumPaywallDelegate: YourHeliumPaywallDelegate(),

    // Defines a fallback paywall to show in case the user's device is not connected to the internet.
    fallbackView: (any View)? = nil,

    // If set, a custom user id to use instead of Helium's. (e.g. an amplitude user id, or a custom user id from your own analytics service)
    customUserId: String? = nil

    // Pass in custom user traits to be used for targeting, personalization, and dynamic content.
    customUserTraits: HeliumUserTraits? = nil,

    // RevenueCat ONLY: supply RevenueCat appUserID here (and initialize RevenueCat before Helium initialize).
    revenueCatAppUserId: String? = Purchases.shared.appUserID,
)
```

#### Passing in Custom User Traits

HeliumUserTraits is a struct that defines the possible user traits that can be passed in. It can be created with any dictionary, as long as the key is a string and the value is a `Codable` type.

```swift
let customUserTraits = HeliumUserTraits(traits: [
    "account_age": 100,
    "subscription_status": "active",
    "user_intent": "upgrade",
])
```

#### Passing in a Custom User ID

By default, Helium generates a UUID per app session and identifies each user \+ interaction with this. You can pass override this value with a custom user id (e.g. from a 3rd party analytics service)
by passing it in as a parameter in `Helium.shared.initializeAndFetchVariants`, or by explicitly calling `Helium.shared.overrideUserId`:

```swift
// Somewhere BEFORE initialize:
Helium.shared.overrideUserId(newUserId: '<your-custom-user-id>');
```

#### Checking Download Status

After the initialization code above runs, you can check the status of the paywall configuration download using the `Helium.shared.downloadStatus()` method. This method returns a value of type `HeliumFetchedConfigStatus`, which is defined as follows:

```swift
public enum HeliumFetchedConfigStatus: Codable {
    case notDownloadedYet
    case downloadSuccess(fetchedConfigId: UUID)
    case downloadFailure
}
```

`notDownloadedYet`: Indicates that the download has not been initiated or is still in progress.

`downloadSuccess(fetchedConfigId: UUID)`: Indicates a successful download. The returned `fetchedConfigID` provides the UUID of the fetched configuration.

`downloadFailure`: Indicates that the download attempt failed.

You can use this to handle different states in your app, for example:

```swift
switch Helium.shared.downloadStatus() {
    case .notDownloadedYet:
        print("Download not started or in progress")
    case .downloadSuccess(let configId):
        print("Download successful with config ID: \(configId)")
    case .downloadFailure:
        print("Download failed")
}
```

## Presenting Paywalls

Now, anywhere in your iOS app, you can use the `triggerUpsell` modifier to (conditionally) trigger a Helium paywall\!

- You don't actually specify the paywall version name here - we load the paywall from the backend based on the trigger.
- What _is_ specified is a "trigger name". These trigger names should be **unique** across your app. User interactions with paywalls will be tracked and used to optimize the paywall for each trigger.

### Via SwiftUI ViewModifier

You can use the `.triggerUpsell` view modifier from any SwiftUI view. It can be provided with a boolean binding var parameter to control the visibility of the paywall.

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

### Via Programmatic invokation (UIKit/ViewController)

In addition to using the triggerUpsell modifier, you can also present upsells programmatically using the `presentUpsell(trigger:)` method. This is particularly useful when you need to show a paywall in response to a specific action or event in your app.

```swift
Button("Try Premium") {
    Helium.shared.presentUpsell(trigger: "postOnboardingButtonPress")
}
```

### Explicitly getting the Helium Paywall View

You can also explicitly get the Helium paywall view via `Helium.shared.upsellViewForTrigger`. This method takes a trigger and returns the paywall
as an `AnyView`.

```swift
let heliumView: AnyView = Helium.shared.upsellViewForTrigger(trigger: "postOnboardingButtonPress")
```

### Custom dismissal/navigation actions

By default, Helium uses a `DismissAction` to support dismissing the paywall. However, in cases where you want to control dismissal yourself (e.g. if you're using a custom ViewController, or a NavigationStack),
you can use `HeliumPaywallDelegate` to wire up dismissal (or any custom action\!) events from a given paywall.

To wire up actions, implement the `onCTAPressed` method as follows:

```swift

class YourHeliumPaywallDelegate: HeliumPaywallDelegate {
    
    func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        switch (event) {
            case .ctaPressed(let ctaName, let triggerName, let paywallTemplateName): {
                if (ctaName == 'dismiss') {
                    // your custom dismissal action for this trigger
                }
            }
            ... other cases
        }
    }    

    // ...rest of your methods
}
```

How it works is that any component (e.g. an X out icon, decline text, etc.) can be remotely configured to be a wrapped in a `Button` with a name. When this button component
is tapped, we fire the delegate's `onCTAPressed` method with the button name. So, once you've implemented custom swift code from your delegate, you can remotely configure
components in the paywall to trigger those methods.

## Testing

Docs here coming soon\! After integration, please message us directly to get set up with a test app \+ in-app test support.

## Paywall Events

### User Interaction Events

#### CTA Pressed

```swift
case ctaPressed(ctaName: String, triggerName: String, paywallTemplateName: String)
```

Triggered when a user presses a Call-To-Action (CTA) button on the paywall.

- `ctaName`: The name or identifier of the CTA button pressed.
- `triggerName`: The name of the trigger that initiated the paywall.
- `paywallTemplateName`: The name of the paywall template being used.

#### Offer Selected

```swift
case offerSelected(productKey: String, triggerName: String, paywallTemplateName: String)
```

Triggered when a user selects a specific offer or product.

- `productKey`: The key or identifier of the selected product or offer.
- `triggerName`: The name of the trigger that initiated the paywall.
- `paywallTemplateName`: The name of the paywall template being used.

#### Subscription Pressed

```swift
case subscriptionPressed(productKey: String, triggerName: String, paywallTemplateName: String)
```

Triggered when a user presses the subscribe button for a specific product.

- `productKey`: The key or identifier of the product being subscribed to.
- `triggerName`: The name of the trigger that initiated the paywall.
- `paywallTemplateName`: The name of the paywall template being used.

### Subscription Status Events

#### Subscription Cancelled

```swift
case subscriptionCancelled(productKey: String, triggerName: String, paywallTemplateName: String)
```

Triggered when a subscription process is cancelled by the user.

#### Subscription Succeeded

```swift
case subscriptionSucceeded(productKey: String, triggerName: String, paywallTemplateName: String)
```

Triggered when a subscription is successfully completed.

#### Subscription Failed

```swift
case subscriptionFailed(productKey: String, triggerName: String, paywallTemplateName: String, error: String?)
```

Triggered when the subscription process fails for any reason. `error` will be the localizedDescription of the underlying
error returned by HeliumPaywallDelegate.makePurchase().

#### Subscription Restored

```swift
case subscriptionRestored(productKey: String, triggerName: String, paywallTemplateName: String)
```

Triggered when a previous subscription is successfully restored.

#### Subscription Pending

```swift
case subscriptionPending(productKey: String, triggerName: String, paywallTemplateName: String)
```

Triggered when a subscription is in a pending state (e.g., waiting for approval).

### Paywall Lifecycle Events

#### Paywall Open

```swift
case paywallOpen(triggerName: String, paywallTemplateName: String)
```

Triggered when a paywall is successfully opened and displayed to the user.

#### Paywall Open Failed

```swift
case paywallOpenFailed(triggerName: String, paywallTemplateName: String)
```

Triggered when there's an error opening or displaying the paywall.

#### Paywall Close

```swift
case paywallClose(triggerName: String, paywallTemplateName: String)
```

Triggered when the paywall is closed programmatically.

#### Paywall Dismissed

```swift
case paywallDismissed(triggerName: String, paywallTemplateName: String)
```

Triggered when the user dismisses the paywall.

### Paywall Configuration Events

#### Paywalls Download Success

```swift
case paywallsDownloadSuccess(configId: UUID)
```

Triggered when paywall configurations are successfully downloaded.

- `configId`: The unique identifier of the downloaded configuration.

#### Paywalls Download Error

```swift
case paywallsDownloadError(error: String)
```

Triggered when there's an error downloading paywall configurations.

- `error`: A string describing the error that occurred during download.

---

Note: For all events related to subscriptions and paywall interactions, the following parameters are consistently used:

- `productKey`: Identifies the specific product or subscription tier.
- `triggerName`: Indicates what caused the paywall to be displayed.
- `paywallTemplateName`: Specifies which paywall design template is being used.
