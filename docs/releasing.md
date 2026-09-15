# Releasing

How an Armada release is cut. Armada ships Developer ID signed and notarized, as a GitHub
release with a Sparkle appcast beside it, and is sold with an offline licence key. It is not an
App Store app and has no store listing.

There is no bump or release script, in this repo or in either sibling. A release is **one
commit, one signed `app-v<version>` tag, and the `release-app` job in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)**, which builds, signs, notarizes,
verifies, writes the appcast and publishes. `make build-release` on a laptop is a rehearsal,
never how a release ships.

Several of the steps below are invisible to CI, so a release that skips them can still go out
green.

## Once, before the first release

### The repository secrets

`gh secret list -R mgcrea/armada` must show all seven that `release-app` reads:

| Secret                      | What it is                                                               |
| --------------------------- | ------------------------------------------------------------------------ |
| `DEVELOPER_ID_P12_BASE64`   | the Developer ID Application certificate and its private key, as a `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the password that `.p12` was exported with                               |
| `KEYCHAIN_PASSWORD`         | any password, for the throwaway keychain the job creates and deletes     |
| `AC_KEY_ID`                 | the App Store Connect API key notarytool submits with                    |
| `AC_ISSUER_ID`              | that key's issuer                                                        |
| `AC_KEY_P8_BASE64`          | that key's `.p8`                                                         |
| `SPARKLE_ED_PRIVATE_KEY`    | the EdDSA key the appcast is signed with                                 |

The two `DEVELOPER_ID_*` secrets and `SPARKLE_ED_PRIVATE_KEY` come out of the login keychain by
hand: the App Store Connect API lists no Developer ID certificate, so nothing can fetch the
`.p12` for you.

For the Sparkle key, run `make sparkle-keys`. It asserts that the key in the keychain is the one
whose public half is `SUPublicEDKey` in `apps/apple/Armada-Info.plist`, and only then prints the
export and `gh secret set` commands. Run `make sparkle-key-shred` afterwards. The key is shared
with bastion and cupertino, so it belongs in this one repository secret, never an org-wide one.
`make appcast` checks the same thing again on every release, over the zip it signs.

Two other secrets are not needed to release. `CLOUDFLARE_API_TOKEN`, in the `production`
environment, is what the deploy jobs use; without it they warn and deploy nothing.
`LICENSE_SIGNING_KEY` turns on the licence round trip in the `app` job; without it that step
warns and skips.

### The version is 1.0.0

The licence key's `major` is 1 and the payment link says "covers every 1.x release", so a first
release numbered 0.x would lock out every key already sold.

### The claims flip in the release commit

- `SHIPPED = true` in `apps/website/src/config.ts`. `SELLING` is already true; `SHIPPED` is what
  turns on the Download and Buy buttons, the version pill and the JSON-LD offer.
  `/download`, `/checksum` and `/appcast.xml` start resolving the moment the release exists,
  because they are 302s to `releases/latest/download`.
- The README's "On sale, not yet released" block, `SECURITY.md`'s "Supported versions" line and
  the "Nothing has been released yet" paragraph at the top of `CHANGELOG.md` are rewritten.

## Every release

### 1. Read what changed

```bash
last=$(git describe --tags --match 'app-v*' --abbrev=0 2>/dev/null)
git log --oneline ${last:+$last..}HEAD
```

Read the diffs, not the subjects, and decide minor or patch. Before the first tag the range is
the whole history.

### 2. Write the version into its copies

CI's `Resolve version from tag` step refuses the tag unless **all four** agree, and each is a
separate hand edit:

| Where                                         | What                                                                                          |
| --------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `apps/apple/Armada.xcodeproj/project.pbxproj` | `MARKETING_VERSION = X.Y.Z;` in **both** build configurations, Debug and Release. CI counts exactly 2 |
| `apps/website/src/config.ts`                  | `export const APP_VERSION = "X.Y.Z";`                                                         |
| `CHANGELOG.md`                                | the top section retitled `## [X.Y.Z] - YYYY-MM-DD`, dated the day the tag is pushed           |
| `CHANGELOG.md` intro                          | a sentence containing `` `app-vX.Y.Z` being the newest ``                                     |

CI reads the first `## [` heading of any kind, so an `## [Unreleased]` left above the new
section fails the tag. The intro check is a plain grep for that exact phrase, backticks
included; a sentence such as "Releases are tagged `app-v<version>`, with `app-v1.0.0` being the
newest." passes it.

The release job passes `MARKETING_VERSION` from the tag on the xcodebuild command line, and
`make build` passes the newest `app-v*` tag, so once a tag exists neither reads the pbxproj
copies. They are checked anyway: Xcode reads them when it builds on its own, and before the
first tag so does `make build`.

Then regenerate what is derived from them:

```bash
make changelog      # Changelog.swift, the What's New pane's data
make revocations    # Revocations.swift from the Worker's D1: refunded keys stop at this build
```

**`make revocations` is not optional.** The app is not allowed to ask anything at runtime, so a
refund or a lost chargeback since the last release is honoured only by a build that re-ran it.
It needs wrangler to be logged in, and fails loudly rather than skipping.

### 3. Rehearse CI's gate locally

```bash
v=X.Y.Z
grep -c "MARKETING_VERSION = $v;" apps/apple/Armada.xcodeproj/project.pbxproj   # 2
sed -n 's/^export const APP_VERSION = "\(.*\)";$/\1/p' apps/website/src/config.ts
sed -n 's/^## \[\([^]]*\)\].*/\1/p' CHANGELOG.md | head -1                        # X.Y.Z
grep -q "\`app-v$v\` being the newest" CHANGELOG.md && echo intro-ok
make changelog-check && make format-swift-check && pnpm test:scripts && make test
node scripts/changelog-notes.mjs "$v" CHANGELOG.md >/dev/null && echo appcast-notes-ok
node scripts/changelog-notes.mjs --markdown "$v" CHANGELOG.md                     # the release body
```

`changelog-notes.mjs` is what `make appcast` and the release body both run in CI. It exits
non-zero on a missing section, and on a section with nothing in it once `### Internal` is left
out, which would otherwise stop the release after notarization rather than before it.

Use `/usr/bin/make` for any dry run. It is GNU make 3.81, the version CI runs, and it refuses
things Homebrew's make 4.x forgives.

### 4. Commit, tag, push: the tag first

```bash
git commit -m "chore(release): Armada X.Y.Z" -- <the files above>
git tag -m "Armada X.Y.Z" app-vX.Y.Z      # annotated; tag.gpgSign is on, so a bare `git tag` fails
git push origin app-vX.Y.Z
# once release-app has published the release:
git push origin main
```

**The site deploys from `main` and the release from the tag.** The release commit flips
`SHIPPED`, so pushing `main` first deploys a site with Download buttons and a version number for
a release that does not exist yet, for the whole length of the release build, and for good if
that build fails. Pushing the tag first means the release exists before anything points at it.
Nothing is lost while `main` waits: the tag's run builds the tagged commit on its own.

### 5. Watch the run

`release-app` needs `app`, so a red `app` job shows `release-app` as **skipped**, not failed.
Read which job failed rather than the run summary, and confirm the green run is for the commit
you tagged.

| Failed step                | What it means                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------------- |
| Resolve version from tag   | a version copy disagrees; fix, commit, delete and re-push the tag                                 |
| Import signing certificate | a `DEVELOPER_ID_*` or `KEYCHAIN_PASSWORD` secret is missing or wrong                              |
| Build, sign and notarize   | notarytool's log names the problem; nothing was uploaded                                          |
| Verify the artifact        | `make audit-release` or Gatekeeper refused the signed bundle; nothing was uploaded                |
| Sign the update            | `SPARKLE_ED_PRIVATE_KEY` is missing or is not `SUPublicEDKey`'s other half, or the section is empty |

### 6. Verify from outside

```bash
gh release view app-vX.Y.Z -R mgcrea/armada --json assets -q '.assets[].name'
# exactly: Armada.zip, Armada.zip.sha256, appcast.xml
curl -sI https://armada.mgcrea.io/appcast.xml | grep -i location
tmp=$(mktemp -d) && curl -sL -o "$tmp/Armada.zip" https://armada.mgcrea.io/download
[ "$(shasum -a 256 "$tmp/Armada.zip" | cut -d' ' -f1)" = "$(curl -sL https://armada.mgcrea.io/checksum)" ] && echo checksum-ok
ditto -x -k "$tmp/Armada.zip" "$tmp" && spctl -a -vvv -t install "$tmp/Armada.app"
codesign -d --entitlements - --xml "$tmp/Armada.app" | plutil -convert json -o - - | jq -r 'keys[]'
# exactly: com.apple.security.device.audio-input (the microphone, for voice)
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$tmp/Armada.app/Contents/Info.plist"
apps/apple/Vendor/bin/generate_keys -p     # must print the same key
```

The update path itself, Sparkle installing X.Y.Z over an older copy, can only be exercised from
the second release onward.

## Traps

- **The Stripe account is shared with bastion and cupertino**, so every app's Worker receives
  every sale. Armada's refuses anything but its own price, and fails closed when
  `EXPECTED_PRICE_ID` is empty: with that var blank it refuses every sale, Armada's included.
  Never deploy `apps/api` with it unset.
- **Late prose lands in the wrong section.** A bullet added after the retitle goes under the new
  version, not under a fresh `[Unreleased]`; add `## [Unreleased]` back after tagging if work
  continues, never before.
- **Never re-sign a stapled bundle.** `make install-release` deliberately does not depend on
  `bundle`: signing again invalidates the stapled ticket.
- **GNU coreutils come first on PATH on the author's Mac.** Sort tags with `sort -V`, not a
  string sort, and anything committed must still work with the BSD tools on the runner.
