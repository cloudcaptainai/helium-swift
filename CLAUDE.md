# CLAUDE.md

## Project overview

iOS SDK for Helium paywalls. Lets mobile apps show remotely-configured, A/B-tested paywalls via a simple trigger-based API.

- Docs: https://docs.tryhelium.com/sdk/quickstart-ios
- Docs MCP server: https://docs.tryhelium.com/mcp

## Key principles

- **Never crash the host app.** This SDK is distributed to apps with millions of users.
- **Avoid using "fallback" in code and comments** unless referring to the Helium fallback paywall flow. This term has a specific meaning in this SDK.

## Repository structure

- `Sources/Helium/HeliumPublic.swift` — All public API surface. Start here.
- `Sources/Helium/HeliumCore/` — Internal implementation.
- `Sources/Helium/HeliumPaywallPresentation/` — Paywall presentation and resolution logic.
- `Sources/HeliumRevenueCat/` — Optional RevenueCat integration.
- `Tests/helium-swiftTests/` — Unit tests.
- `HeliumExample/` — Example app with UI tests.

## Conventions

- Version is tracked in `Sources/Helium/HeliumCore/BuildConstants.swift`.
- No external SPM dependencies — third-party code (Segment, SwiftyJSON, AnyCodable) is vendored.
- Releases are automated (see `CONTRIBUTING.md`).
