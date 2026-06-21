# Helm — Go-live prep (App Store + Google)

Operational checklist for shipping Helm. Split by **what the code/build needs** vs
**what only the account owner can do** (Google Cloud Console, App Store Connect).

---

## 1. Google Calendar sign-in — "just works" for normal users

**Goal:** a user taps *Sign in with Google* and it works — no OAuth client-ID entry.

**Mechanism (already coded):** the app reads its OAuth *iOS* client ID from
`Info.plist ▸ HelmGoogleClientID`. When set, `GoogleConfig.isConfigured` is true →
the "paste client ID" field hides and *Sign in with Google* shows. Auth is OAuth
Auth-Code + PKCE via `ASWebAuthenticationSession` (no client secret, no URL-scheme
registration). Scope is the minimal `https://www.googleapis.com/auth/calendar.app.created`
— Helm can touch only the "Helm Shifts" calendar it creates, never your other calendars.

### Code/build (Claude can do once given the value)
- [ ] Put the iOS OAuth Client ID into `Helm/Info.plist ▸ HelmGoogleClientID`
      (format `…apps.googleusercontent.com`). **Safe to commit** — an iOS client ID
      is public (PKCE, no secret).
- [ ] Build + verify on the sim: the paste field is gone; *Sign in with Google* shows.
- [ ] (Optional) remove the now-unused "paste client ID" fallback UI from Settings.

### Google Cloud Console (owner only — Claude has no access)
- [ ] **OAuth consent screen → Publish to Production.** In *Testing* only added test
      users can sign in and refresh tokens expire after 7 days.
- [ ] **Verification** for the `calendar.app.created` scope. This is the least-privileged
      calendar scope, so expect *brand verification* (app name, logo, support email,
      privacy-policy URL, authorized domain) rather than the restricted-scope security
      assessment that full `calendar`/`calendar.events` require. Confirm the exact ask.
- [ ] OAuth client is type **iOS**, bundle ID **Fusion-Studios.Helm** (already created).
- [ ] Provide a public **privacy-policy URL** (see §3).

---

## 2. App Store privacy ("nutrition label") — App Store Connect answers

Helm collects **no** data for itself. Roster/shift data lives **on-device + your
private iCloud**; nothing is sent to a Helm server (there is no Helm server). The
only outbound data is shifts you choose to write to your own Apple/Google calendar.

Suggested **App Privacy** answers in App Store Connect:
- **Data used to track you:** None.
- **Data linked to you:** None.
- **Data not linked to you:** None collected. (Calendar writes go to *your* calendar
  at your request; Helm doesn't collect or transmit them to itself.)
- Net result: **"Data Not Collected."** No analytics, no third-party SDKs, no ads.

`Helm/PrivacyInfo.xcprivacy` already declares: no tracking; required-reason APIs for
File-Timestamp + UserDefaults; no collected data types. (Audited adequate in v8.2.)

Other submission items:
- [ ] Demo account + a sample roster spreadsheet for App Review.
- [ ] Calendar usage strings are present + specific (`NSCalendarsFullAccessUsageDescription`).
- [ ] App price set in App Store Connect (paid app; everything free inside — see the
      `ProGate.offersUpgrade = false` decision; the StoreKit foundation stays parked).

---

## 3. Privacy policy (draft — host at a public URL, used by App Store + Google)

> **Helm — Privacy Policy**
>
> Helm helps you turn your work roster into calendar events. We designed it to keep
> your data yours.
>
> **What Helm stores.** Your shift types, rosters, schedules, time-off, availability
> and preferences are stored on your device and synced through your own private
> iCloud account (Apple CloudKit). Helm has no servers and never receives this data.
>
> **Calendars.** When you choose to, Helm writes your shifts to a calendar you pick —
> Apple Calendar on your device, or a dedicated "Helm Shifts" calendar in your Google
> account. With Google, Helm uses the `calendar.app.created` scope, which lets it
> manage only the calendar it creates — never your other calendars or events. Your
> Google sign-in token is stored only in your device's Keychain.
>
> **What we don't do.** No analytics, no advertising, no tracking, no third-party
> data sharing. Your roster never leaves your device except to the calendar you choose.
>
> **Your control.** You can export everything as a JSON file (Settings ▸ Privacy &
> data), remove all Helm events from a calendar, and delete the app at any time.
>
> **Contact.** <support email>.

(Replace `<support email>` and host this at e.g. `https://<your-domain>/helm/privacy`.)

---

## 4. Other queued workstreams (need the owner present)
- **Team sharing (CKShare):** enable the parked iCloud-CloudKit entitlements (signing-
  gated — enabling them makes the Mac build refuse to launch without a provisioning
  profile) + 2 iCloud accounts to test. Persistence already sits behind a seam for this.
- **Live Google + CloudKit sync E2E:** verify the built-but-unrun direct-Google write
  path and cross-device iCloud sync, from signed builds on your accounts.
</content>
