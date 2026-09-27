# ccs mini

ccs mini is a menu bar app for checking Codex and Claude Code subscription usage and switching saved CLI accounts. It has no conversation search or indexing, and does not register a global shortcut. It can be installed alongside the full ccs app.

Download `ccs-mini.zip` from the GitHub release, unzip it, move `ccs-mini.app` to Applications, and open it. Click the person icon in the menu bar to open a compact dropdown. Each ring shows the percentage used for its labeled usage window; hover over it for the reset time. Click **Switch** beside a saved account to make it active. The plus menu beside each provider contains **Import current login** and **Add account** for setup. The mini app shares the full app's saved account records and Keychain items. macOS may ask for Keychain access separately for the mini app.

Run `./build-mini.sh` on macOS to create `ccs-mini.app` and `ccs-mini.zip`. A local build uses ad hoc signing. For Developer ID signing, set `CCS_CODESIGN_IDENTITY` to a Developer ID Application identity and `CCS_OUTPUT_DIR` to the output directory. The current release is signed but not notarized, so macOS may require a Gatekeeper override on first launch. A future notarized build requires a configured Apple notarytool profile; staple the app and recreate the zip after approval.
