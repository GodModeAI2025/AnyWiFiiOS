# App Store, English

**Name:** CaptiveAI
**Subtitle (30 characters):** Sign in to Wi-Fi automatically

## Description

Hotel, train, trade fair, café: many Wi-Fi networks make you click through a login page every single time. CaptiveAI does it for you.

Create a profile for a network and describe in a sentence or two what to do. For example: accept privacy and terms, ask for the room number, enter the last name, connect. An on-device model asks follow-up questions until everything is clear. The flow is then saved and replayed without AI on every visit, fast and reproducible.

**What the app can do**
- Login pages with consent, username and password, room number and last name, voucher code or email
- Multi-step portals
- Missing values are requested when needed, passwords live in the Keychain
- If a portal changes a label, the app repairs the flow and asks you first
- Share profiles, optionally with encrypted credentials
- Shortcuts, Siri and Control Center

**What the app does not do**
- It doesn't solve captchas, buy anything or subscribe you to newsletters
- No Wi-Fi scanning, no location data, no analytics, no servers of our own

All data stays on your device. Private Cloud Compute is optional and only for repairs, with redacted data and your consent.

Requires an iPhone or iPad with iOS 27. The chat needs Apple Intelligence.

## Keywords (100 characters)

Wi-Fi,hotspot,captive portal,login,hotel,sign in,guest,access,automation,shortcuts

## App Privacy

- Data used to track you: none
- Data linked to you: none
- Data collected: none. Profiles, values and logs stay on the device.

## Notes for App Review

- The app signs in to captive portals that users set up as profiles themselves. It claims only networks (exact SSID) with an enabled profile.
- Hotspot Helper is used solely for portal sign-in, not for location or scanning.
- Plain HTTP: captive portals speak only HTTP before sign-in. That's why `NSAllowsArbitraryLoads` is set.
- Microphone and speech recognition are used only for dictation in the profile chat. Recognition runs on the device.
- Testing without the entitlement: create a profile, tap "Sign In Now" on the portal Wi-Fi (manual mode).
