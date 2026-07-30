# Signing the Network Extension (precise mode)

Precise mode enforces per-app routes with a `NETransparentProxyProvider` system
extension. Unlike the system-proxy takeover it works for apps that ignore proxy
settings, and no VPN tunnel can shadow it — but macOS refuses to load a system
extension unless the signature carries a **Network Extension entitlement**, and
that entitlement can only be issued to a paid Apple Developer team.

That is a platform rule, not an App Store rule. Being open source and
self-distributed does not remove it.

Everything else in EyesOnYou (traffic monitoring, the system-proxy enforcement
path, the CLI) works with the default ad-hoc build and needs none of this.

## What happens without it

The app builds and runs. Turning on precise mode reports
`precise.state.notEntitled` — a named state, not a crash:

> This build cannot load the system extension: its signature carries no Network
> Extension entitlement.

Enforcement stays on the system-proxy path, which is fully functional.

## Repository policy: no account material in git

Nothing that identifies or authenticates an Apple Developer account belongs in
this repository — see [CONTRIBUTING.md](../CONTRIBUTING.md). The tracked files
deliberately carry placeholders (`com.example.EyesOnYou`,
`CODE_SIGN_IDENTITY = "-"`, empty entitlements), and the real values live only in
gitignored local files.

Consequences worth stating plainly:

- A contributor or fork **cannot** sign as your team. The signing capability is
  the private key in your keychain, not anything in the source tree.
- The Network Extension entitlement is granted to **your** App ID in your Apple
  account. A fork cannot inherit it; a PR cannot take it.
- A fork signing with its own paid team produces a build whose developer name is
  theirs, not yours.
- What *is* public in any signed release: your Team ID and developer name, which
  is already true of every release you ship today.

The real risk of maintainer-signed open source is **supply chain**, not account
theft: code merged from outside, signed by you, is distributed under your
identity. Mitigations: review network / NE / process-execution changes carefully
before cutting a release, sign and notarize only from a machine you control
(never with secrets exposed to fork PRs in CI), and keep the notarization
credentials out of any shared environment.

## One-time setup (maintainer)

1. **Apple Developer portal** → Identifiers. Register (or edit) two App IDs under
   your own reverse-DNS prefix, not `com.example`:
   - `<your.prefix>.EyesOnYou` — enable **Network Extensions** and **System
     Extension** capabilities.
   - `<your.prefix>.EyesOnYou.NetworkExtension` — enable **Network Extensions**.
2. **App Group — not needed for precise mode; skip it.** Nothing in the code reads
   an App Group container: the host and the extension talk over
   `sendProviderMessage` (see `TransparentProxyController`), and
   `EyesOnYouConstants.appGroupIdentifier` is currently an unused declaration.
   The `com.apple.security.application-groups` key in the `.entitlements.example`
   templates is therefore optional — leaving it in an entitlement that your
   provisioning profile does not grant is a common "profile doesn't match
   entitlements" failure, so drop the key unless you actually need it.

   If you do keep it: on **macOS** an app group identifier must be prefixed with
   your Team ID (`$(TeamIdentifierPrefix)com.yourname.EyesOnYou`, which is what
   `config/EyesOnYou.xcconfig.example` already does) — the `group.` prefix is the
   iOS convention and does not apply here.
3. **Network Extension entitlement for self-distribution.** Development signing
   works immediately. For a Developer ID build distributed outside the App Store,
   Apple additionally requires an approved request for the
   `com.apple.developer.networking.networkextension` entitlement — submit the
   Network Extension (Developer ID) request form describing the use case.
   Turnaround is typically a few business days.
4. **Local config** (gitignored):

   ```bash
   cp config/EyesOnYou.xcconfig.example config/Local.xcconfig
   ```

   Set your real `DEVELOPMENT_TEAM`, bundle IDs, and App Group there. Also create
   `config/LocalSigning.xcconfig` with your signing identity — `config/Signing.xcconfig`
   already includes it when present:

   ```
   EYESONYOU_CODE_SIGN_IDENTITY = Apple Development: you@example.com (XXXXXXXXXX)
   ```

5. **Entitlements**: copy the tracked templates into place (they are `.example`
   files precisely so the real ones stay untracked):

   ```bash
   cp config/HostApp.Development.entitlements.example         App/EyesOnYou/EyesOnYou.entitlements
   cp config/NetworkExtension.Development.entitlements.example NetworkExtension/EyesOnYouNetworkExtension.entitlements
   ```

   Use the `DeveloperID` variants for a distributable build. Do **not** commit
   the results.

6. **Info.plist**: the tracked `NetworkExtension/Info.plist` already maps
   `com.apple.networkextension.app-proxy` → `FlowTransparentProxyProvider` and
   `filter-data` → `FlowFilterDataProvider`, and the host app already declares
   `NSSystemExtensionUsageDescription`. Only `NEMachServiceName` needs your real
   prefix — it currently reads `$(TeamIdentifierPrefix)com.example.…`. Point it at
   `$(EYESONYOU_MACH_SERVICE)` from your local xcconfig (see
   `config/NetworkExtension.Info.plist.fragment.example`).

7. Regenerate and build:

   ```bash
   xcodegen generate && xcodebuild -project EyesOnYou.xcodeproj -scheme EyesOnYou -configuration Debug build
   ```

## Runtime notes

- The extension must be **embedded** in the app bundle at
  `Contents/Library/SystemExtensions/` — `project.yml` already does this. A
  system extension cannot be downloaded and installed separately after the fact;
  doing so would break the app's signature seal.
- macOS shows an approval prompt the first time; the user approves in **System
  Settings › General › Login Items & Extensions**. `precise.state.needsApproval`
  says so in the UI.
- Debug builds of a system extension need either SIP developer mode
  (`systemextensionsctl developer on`) or a notarized build.
- The extension and the app must be signed by the **same team**, or embedding is
  rejected at launch.
- Precise mode and the system-proxy takeover are mutually exclusive by
  construction (`AppModel.startEnforcement`): the transparent proxy already sees
  every flow, so running both would send app traffic through our own local proxy
  and back out through the extension.

## Verifying it actually loaded

```bash
systemextensionsctl list
```

The extension should appear as `[activated enabled]`. Then confirm flows are
being claimed — the Settings row reports `precise.state.active` with the rules
generation the provider acknowledged, which only advances when the provider has
decoded a real policy push.
