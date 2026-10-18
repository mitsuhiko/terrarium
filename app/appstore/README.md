# Publishing to the App Store

How the app gets to the App Store (D51): what the repository has, what is left
to do by hand in App Store Connect, and the open risks for review.

- `metadata.md`: name, subtitle, description, keywords, URLs, categories
- `review-notes.md`: notes for App Review and the test sign-in
- `../../docs/privacy.md`: the privacy policy (its GitHub URL is the policy URL)

## In the repository

- **Privacy manifest** `ios/Sources/PrivacyInfo.xcprivacy`: no tracking and no
  collected data. It gives the required reasons for UserDefaults (CA92.1) and
  file timestamps (DDA9.1, C617.1, 3B52.1).
- **Info.plist**: `ITSAppUsesNonExemptEncryption` = NO (HTTPS through
  URLSession and WebKit, the Keychain; hashing only otherwise), so builds need
  no export compliance answers. The category is Developer Tools
  (`LSApplicationCategoryType`). There are usage descriptions for every device
  module.
- **No self-test SPI in store builds**: the self-test's private-API hooks
  (`_killWebContentProcess`, `UIKeyboardImpl`) are compiled only with
  `SELFTEST_SPI`. Debug builds set it and so does `run.sh --device`;
  `scripts/archive.sh` does not, and fails if the strings are in the binary.
- **Consent for the agent**: before the first message to a model provider,
  an alert asks to allow sending messages and project data to it
  (guideline 5.1.2(i)). It asks once per provider and stores the answer under
  `agent.sharingAllowed` in UserDefaults.
- **Settings → About**: the version, the privacy policy, support and
  acknowledgements. The acknowledgements are `web/licenses.json`, written by
  the web build from the npm packages that are in the bundle, plus
  `web/licenses-extra.json` (Pyodide, CPython, Emscripten).
- **Archive and upload**: `make archive` (or `app/scripts/archive.sh`) builds
  `build/Terrarium.xcarchive` and an `.ipa`. `make upload` uploads it with
  the Xcode account, or with an App Store Connect API key (`ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_PATH`). The build number is the UTC time
  (`YYYYMMDD.HHMM`). The version is `MARKETING_VERSION` in the project
  (now 0.1).
- **Screenshots**: `app/scripts/store-screenshots.sh` takes them in the
  iPhone 6.9" and iPad 13" simulators (`build/screenshots/`). Those are the
  two sizes App Store Connect needs; it scales them down for smaller
  devices.

## By hand, once

1. Agreements, Tax and Banking in App Store Connect: the Free Apps agreement
   is enough for a free app.
2. App Store Connect → Apps → New App: iOS, name "Terrarium" (names are
   unique across the store; if it is taken, "Terrarium – Python IDE", with
   the app's display name still "Terrarium"), primary language English (U.S.), bundle ID
   `eu.ronacher.Terrarium` (automatic signing registers it with the first
   device build or archive),
   SKU e.g. `terrarium`.
3. App Information: categories and URLs from `metadata.md`.
   - Content rights: yes, it contains third-party content (the Python
     documentation, under the PSF license), and you have the rights.
   - EU Digital Services Act: declare trader status before distributing in
     the EU.
4. Pricing and Availability: free; countries.
5. App Privacy: privacy policy URL, then "Data Not Collected". This answers
   for the developer and the code in the app; the agent sends data only to
   providers the user signs in to and allows. If Radius counts as the
   developer's own service (Earendil), revisit this: then messages and
   project files sent to it are "User Content: Other User Content", used for
   App Functionality and not linked to identity unless Radius links them.
6. Age rating questionnaire: answer for the app as it is.
   - Unrestricted web access: yes. Programs fetch any URL, and HTML outputs
     and links open web content.
   - The agent is a generative-AI chat with outside models.
   - User-generated content: no sharing between users.
   - Expect the highest bracket because of unrestricted web access.
7. Version page: screenshots, the texts from `metadata.md`, the sign-in
   information and the notes from `review-notes.md`.

## Each release

1. `make selftest` (and `make device` with `--selftest`) pass.
2. Bump `MARKETING_VERSION` in `ios/Terrarium.xcodeproj` for a new
   version (both target configurations).
3. `make upload`. The first export creates the Apple Distribution
   certificate if the account has none. The build shows up in TestFlight
   after processing. Test it there on a device: it is the first build
   without `SELFTEST_SPI` and with distribution signing.
4. Select the build on the version page and submit it for review.

## Open risks for review

- **Private API in features (not only tests)**:
  - `_setEnabled:forFeature:` / `_features` on WKPreferences: the 120 Hz
    page rendering, `WebHost.renderAtDisplayRate`.
  - A WKContentView subclass for the key bar, and `_updateTextInputTraits:`
    for plain keyboard traits in code fields (`KeyboardAccessory`).
  - `_elementDidFocus:userIsInteracting:…` for programmatic focus (as
    Capacitor's keyboard plugin does).
  These are in the binary. If review rejects them, the fallbacks are:
  pages at 60 Hz; the key bar on the native fields only, or as a view above
  the keyboard instead of its accessory; HTML attributes for traits; a tap
  to focus `input()`.
- **2.5.2 / 4.7 (Q9)**: packages download from PyPI and run in WebKit. The
  review notes explain this. Pythonista, Pyto, Carnets and a-Shell ship
  similar features.
- **Subscription sign-ins (Q21)**: Claude Pro/Max, ChatGPT and Copilot
  sign-ins from a third-party app may be against those providers' terms,
  and review may ask about them.
- **Name** (D52): "Terrarium" is a common word; other apps and
  trademarks may use it. Check the store and trademarks before creating the
  record. "Python" is only in the subtitle, which describes what the app
  is for, as the PSF's trademark policy allows.
- **4.8 / 5.1.1(v)**: the app has no login of its own; provider sign-ins
  are for using those services. If a Radius account can be created through
  the app's sign-in, account deletion must be reachable from the app too.
