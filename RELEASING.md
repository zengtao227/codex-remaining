# Releasing Codex Remaining

Codex Remaining is distributed outside the Mac App Store. Public release assets must be signed with **Developer ID Application**, use the **Hardened Runtime** with a secure timestamp, be accepted by Apple's notarization service, and have the notarization ticket stapled before the final zip is created.

Normal source/CI builds remain ad-hoc signed. Only the release workflow uses Apple credentials.

## Apple account prerequisites

You need an active Apple Developer Program team that can issue a Developer ID Application certificate and use the Apple notary service.

For CI notarization, use an **App Store Connect Team API key**. Do not use an Individual API key; Individual keys aren't supported by `notarytool`.

## 1. Create/export a Developer ID Application identity

Create a **Developer ID Application** certificate through Xcode or Certificates, Identifiers & Profiles. It is the certificate type for Mac apps distributed outside the Mac App Store.

The GitHub runner needs the certificate **and its private key**, exported as a password-protected `.p12` file.

With Xcode:

1. Xcode → Settings → Accounts.
2. Select the Apple Account and team.
3. Manage Certificates.
4. Create/select **Developer ID Application**.
5. Export the signing identity as a password-protected `.p12`.

Protect this file and password as production signing credentials. Anyone who has both can sign software as your Developer ID identity.

## 2. Create an App Store Connect Team API key

In App Store Connect:

1. Users and Access → Integrations → App Store Connect API.
2. Use **Team Keys**.
3. Generate a key with the least role your team permits for notarization.
4. Record the **Key ID** and **Issuer ID**.
5. Download the `.p8` private key. Apple only lets you download the private key once.

Keep the `.p8` private. If it is lost or exposed, revoke it and create another key.

## 3. Configure GitHub repository secrets

The release workflow expects these secrets:

| Secret | Value |
| --- | --- |
| `MACOS_DEVELOPER_ID_P12_BASE64` | Base64 of the password-protected Developer ID `.p12` |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | Password used when exporting the `.p12` |
| `APPSTORE_API_PRIVATE_KEY_BASE64` | Base64 of the App Store Connect Team API `.p8` |
| `APPSTORE_API_KEY_ID` | Team API Key ID |
| `APPSTORE_API_ISSUER_ID` | Team API Issuer ID |

On macOS, copy base64 text without changing the files:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

Set `MACOS_DEVELOPER_ID_P12_BASE64`, then repeat for the `.p8` file:

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

Set `APPSTORE_API_PRIVATE_KEY_BASE64`.

Do **not** copy `.p12` or `.p8` files into this repository. `.gitignore` blocks common private-key filenames as a second line of defense; GitHub Secrets are the intended storage boundary.

## 4. Run a notarized dry-run before tagging

The Release workflow supports `workflow_dispatch`. Run it manually from the candidate branch with the version matching `Info.plist`, for example:

```text
release_tag = v0.2.1
```

A manual run:

1. runs self-tests;
2. imports the `.p12` into a temporary runner keychain;
3. builds a universal `arm64 + x86_64` app;
4. signs it with Developer ID Application, Hardened Runtime, and secure timestamp;
5. submits a temporary zip with `notarytool --wait`;
6. requires Apple's status to be `Accepted`;
7. staples and validates the notarization ticket;
8. runs Gatekeeper assessment;
9. creates the final zip **after** stapling;
10. re-extracts that exact zip and repeats signature, architecture, staple, and Gatekeeper checks;
11. uploads the package as a workflow artifact only — it does **not** create a GitHub Release.

Do not create the version tag until this dry-run is green and the downloaded dry-run artifact passes a real-Mac launch/Gatekeeper check.

## 5. Publish

After the candidate branch is validated and merged to `main`, wait for main CI to pass. Then create the matching tag:

```bash
git tag v0.2.1
git push origin v0.2.1
```

The tag-triggered Release workflow repeats the full signing/notarization pipeline and publishes only:

```text
Codex-Remaining-v0.2.1-universal.zip
Codex-Remaining-v0.2.1-universal.zip.sha256
```

## Failure policy

Release signing/notarization fails closed. Do not:

- fall back to ad-hoc signing for a public release;
- disable Hardened Runtime to make notarization pass;
- disable Gatekeeper checks;
- commit Apple credentials;
- publish an archive before stapling;
- rewrite an already published version tag to hide a failed release.

If Apple rejects a submission, inspect the notary log, fix the concrete signing/notarization issue, create a new commit, and rerun the dry-run before publishing.
