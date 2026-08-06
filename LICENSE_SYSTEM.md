# Poker Ledger — License / Activation System

A protection layer that stops a copied APK from being usable on another
phone without a license key issued by you.

It is strictly additive. It does not touch sessions, players,
transactions, the settlement engine, the database schema, or any existing
screen.

---

## 1. How it works in one paragraph

You hold an RSA-2048 **private key**. The app ships only the matching
**public key**. When you issue a license you sign a small JSON payload
(license id, customer, type, expiry, device limit). The app verifies that
signature offline on every launch. Because verifying needs only the public
key but *creating* a signature needs the private key, a customer holding
the APK can read the verification code, but still cannot mint a license —
that would mean breaking RSA-2048.

---

## 2. Two license types

| | **Owner License** | **Customer License** |
|---|---|---|
| Who | You, the software owner | Each paying customer |
| Devices | 3 by default, configurable | 1 by default, configurable |
| Expiry | Never (enforced by policy) | Optional (`--days N`) |
| Types | `owner` | `standard`, `full`, `trial`, `club` |
| Issued with | `--owner` | `--customer ... --id ...` |

The Owner License is your permanent master key. The same key activates
your phone, tablet and spare — and **activating one never deactivates
another**, because each installation stores its own activation record and
never reads another device's.

Guard rails in the tool:

- `--owner --days 30` is refused (the master key must not expire).
- `--customer ... --type owner` is refused, so you cannot hand an owner
  key to a customer by accident.
- `--devices` is capped at 25.

## 3. Issuing a license

Requires Python 3 and `openssl`. No pip installs.

```bash
# YOUR owner master license — 3 devices, never expires
python3 tool/issue_license.py --owner

# ...or with your name and a chosen device count
python3 tool/issue_license.py --owner --customer "Arash" \
    --id PL-OWNER-0001 --owner-devices 3

# Customer: perpetual, single device
python3 tool/issue_license.py --customer "Reza" --id PL-2026-0001

# 30-day trial
python3 tool/issue_license.py --customer "Ali" --id PL-2026-0002 \
    --type trial --days 30

# Customer: full license
python3 tool/issue_license.py --customer "Nima" --id PL-2026-0005 --type full

# Customer: club / venue, 5 seats
python3 tool/issue_license.py --customer "The Club" --id PL-2026-0003 \
    --type club --devices 5

# Lock to one specific handset (customer sends you their Device ID)
python3 tool/issue_license.py --customer "Sam" --id PL-2026-0004 \
    --bind <64-char-device-id>
```

The script prints a key like:

```
PLK1.eyJjdXN0b21lcl9pZCI6...  .knI6d9Hd41-_-VsNv9ehSufVtK8A0f2Q...
```

Send that string to the customer. They paste it into the activation
screen. It is safe to send over WhatsApp or email — the app strips line
breaks and spaces automatically.

---

## 4. The production signing key

Licenses are signed with the **production** RSA-2048 key pair for Poker
Ledger. Its private half lives **outside this repository**:

```
~/.pokerledger/signing/pokerledger_production_private_key.pem   (chmod 600)
~/.pokerledger/signing/pokerledger_production_public_key.pem
```

Keeping it outside the project tree is the point: it cannot be committed
to git, cannot be swept into a ZIP of the project, and cannot leak by
publishing the source. The app needs only the public modulus, which is
embedded in `lib/license/license_keys.dart` and is safe to ship.

If you keep keys on a USB stick or an encrypted volume:

```bash
export POKERLEDGER_KEY_DIR=/Volumes/SecureKey/pokerledger
```

### ⚠️ Back this key up

Losing the private key means you can never issue another license for this
build — you would have to generate a new pair, update
`license_keys.dart`, ship an app update, and re-issue every customer
license. Back it up somewhere safe and offline.

### Rotating

Only rotate if the key leaks, or you deliberately intend to invalidate
every license already in the field:

```bash
KEYDIR=~/.pokerledger/signing
mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR"
openssl genrsa -out "$KEYDIR/pokerledger_production_private_key.pem" 2048
chmod 600 "$KEYDIR/pokerledger_production_private_key.pem"
openssl rsa -in "$KEYDIR/pokerledger_production_private_key.pem" \
    -pubout -out "$KEYDIR/pokerledger_production_public_key.pem"
python3 tool/issue_license.py --print-modulus
```

Paste the printed `modulusHex` block into `lib/license/license_keys.dart`
and rebuild. Every previously issued license stops validating — by
design — and `test/license_fixtures.dart` must be regenerated.


## 5. Architecture

```
lib/license/
  license_keys.dart        Embedded PUBLIC key + format constants
  license_model.dart       LicensePayload, ActivationRecord, errors
  license_verifier.dart    Offline RSA PKCS#1 v1.5 / SHA-256 verify
  device_identity.dart     Stable per-installation device id
  license_storage.dart     Encrypted + HMAC-authenticated persistence
  license_service.dart     Flow: verify, bind, activate/deactivate
  license_policy.dart      Owner vs customer rules (no crypto, no storage)

lib/providers/license_provider.dart   ChangeNotifier for the UI
lib/screens/license/
  license_gate.dart            Renders app OR activation screen
  activation_screen.dart       Key entry + Device ID
  license_info_section.dart    The License block in Settings

tool/issue_license.py          OWNER ONLY — signs licenses
~/.pokerledger/signing/        Production key pair (OUTSIDE the repo)
```

**No new pub dependencies.** RSA verification uses Dart's built-in
`BigInt.modPow`; hashing uses `package:crypto`, already a dependency.
This matters for an offline-first app that must keep building.

### Where it plugs in

`main.dart` only changed in three places: one import, one provider, and
wrapping the existing home widget:

```dart
home: const SplashScreen(
  child: LicenseGate(
    child: PinLockScreen(child: SessionListScreen()),   // unchanged
  ),
),
```

While unlicensed, `PinLockScreen`/`SessionListScreen` are never built, so
no ledger screen is reachable around the gate.

---

## 6. Device binding

Each installation generates a random 256-bit device id on first launch
and stores it locally. Activation records which device id it was bound
to, and on every launch the app re-checks that the stored id still
matches.

- Copy the APK to another phone → fresh install → new device id → the
  copied activation does not apply → activation screen.
- Original phone → id unchanged → keeps working forever, fully offline.

**Deliberately not a hardware id.** Android has blocked IMEI/serial for
normal apps since API 29, and a home-game ledger has no business
collecting hardware identifiers. The trade-off, stated plainly: clearing
app data or reinstalling on the *same* phone also yields a new id, so
that phone must be re-activated. That is what `--devices N` and
re-issuing are for.

---

## 7. Storage security

The activation record is stored encrypted and authenticated, not as
plaintext:

- 16-byte random nonce per write
- SHA-256 based keystream XORed over the plaintext
- HMAC-SHA256 tag verified **before** decryption is trusted
- Key derived from the device id, so a record copied to another install
  fails its HMAC and is discarded

Critically, the app **never persists an "is activated" boolean**. It
re-runs the full signature check from the stored blob on every launch, so
flipping a flag in local storage achieves nothing.

**Honest limitation:** nothing running purely on-device can stop a
determined attacker who patches the APK to skip the check. No offline
scheme can, and claiming otherwise would be dishonest. What this defeats
is the realistic threat: someone sharing the APK file, or copying the app
data directory. Forging a *license* remains cryptographically infeasible.

---

## 8. Future server verification

`LicenseService.remoteRevalidate()` is the seam. It returns `null`
("no opinion") today and every caller already treats the offline result
as authoritative, so adding a network path later changes no call sites.
A server build would check revocation and true cross-device counts, then
cache the answer with a grace period so the app still works at the table
with no signal.

True device-limit enforcement needs that server: an offline app cannot
know what other handsets did with the same key. What is enforced offline
is one key → one device per installation, which is what stops a copied
APK from just working.

---

## 9. Customer-facing flow

1. Install → activation screen.
2. Customer taps **Copy** and sends you their Device ID.
3. You run `issue_license.py` and send back the key.
4. Customer pastes it, taps **Activate** → app opens.
5. Every later launch opens straight into the app, offline.
6. **Settings → License** shows status, license id, customer, type,
   activation date, expiry, device limit and device info.
7. Moving to a new phone: **Settings → License → Deactivate this device**
   releases it. No ledger data is deleted.
