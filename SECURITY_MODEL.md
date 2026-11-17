# Helium SDK security model

Scope: the Helium iOS SDK (`helium-swift`) and Android SDK (`helium-android`). Both repos carry this document. It was drafted from the code plus the Helium team's answers (marked **[team]**). Security scans read it to judge findings, so update it when the SDK or these priorities change.

## System overview and trust boundaries

1. **Host app**: the SDK runs inside a customer's app on an end user's device and shares that app's process, storage and permissions.
2. **Helium API**: the SDK fetches paywall config, products and entitlement state over HTTPS. It authenticates only with the app's SDK API key, which ships in the app binary and is public.
3. **Paywall content**: paywalls are HTML/JS written in the Helium dashboard by the app's team (with AI help). The SDK renders it in a WebView and exposes a JS bridge to native code. That content is less trusted than the host app.
4. **Payment providers**: purchases go through StoreKit / Google Play Billing, RevenueCat, or external web checkout (Stripe, Paddle) in a WebView or the browser.

## Components

| Component | Code |
|---|---|
| iOS SDK | helium-swift `Sources/**` (excluding vendored code, below) |
| Android SDK | helium-android `paywall-core`, `paywall-compose-ui`, `revenue-cat`, `stripe` |

## Entry points

- JS bridge: `WebViewMessageHandler.swift` / `WebViewMessageHandler.kt` (`@JavascriptInterface`) accept paywall messages such as select-product, subscribe, restore-purchases, navigate, open URL, custom-action and dismiss.
- WebView navigation and links that open external URLs or intents.
- Web checkout views: `WebCheckoutWebViewController.swift`, `ExternalWebCheckoutManager.kt`.
- Network responses from the Helium API (config, paywall bundles, products).
- User traits and other values the host app passes in, which are injected into paywall pages.
- Hidden control panel and paywall previews.

## Assets **[team]**

All weighted equally:

1. **Safety of host apps**: paywall content or network data must never harm the host app or its users (bridge abuse, arbitrary URL or intent launching, data exfiltration, crashes).
2. **Purchase and entitlement integrity**: no one gets paid access without paying.
3. **Payment credentials and end-user data**: purchase tokens, user IDs, traits and purchase history.

## Attackers that matter **[team]**

- **Malicious paywall author** whose paywall JS targets end users' devices through the WebView and bridge.
- **App end user** who extracts the SDK API key or tampers with the SDK's traffic to get entitlements without paying.
- **Prompt injection** through the AI paywall editor, steering it to write malicious paywall code that then runs in the SDK.
- **Anonymous network attacker** sending crafted responses or links.

## Existing controls

- The bridge validates message shape before dispatch.
- Checkout WebViews restrict navigation (`decidePolicyFor` on iOS).
- Key principle in both repos: never crash the host app.

## Out of scope / accepted risk **[team]**

- **Misuse of the public SDK API key itself is accepted.** Anyone can read it from an app and act as that app's SDK. Still in scope: acting as another end user, getting entitlements without paying, or harming the host app.
- **Vendored third-party code** (Segment, SwiftyJSON, AnyCodable under `Sources/Helium/HeliumCore/` in helium-swift) is out of scope.
