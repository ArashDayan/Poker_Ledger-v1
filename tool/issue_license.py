#!/usr/bin/env python3
"""Issue signed Poker Ledger license keys.

THIS SCRIPT IS FOR THE OWNER ONLY. It uses the PRIVATE key and must never
be shipped to a customer or bundled into the APK.

The app verifies licenses offline with the matching PUBLIC key embedded in
lib/license/license_keys.dart. Because signing needs the private key,
which lives only here, a customer cannot mint their own licenses even with
full access to the APK.

Requires only Python 3 + the `openssl` command line tool (no pip installs).

USAGE
  # ---- OWNER LICENSE (your own master key) ----------------------------
  # 3 personal devices, never expires. Use --owner-devices to change.
  python3 tool/issue_license.py --owner

  # ---- CUSTOMER LICENSES ----------------------------------------------
  # Perpetual single-device license
  python3 tool/issue_license.py --customer "Reza" --id PL-2026-0001

  # 30-day trial
  python3 tool/issue_license.py --customer "Ali" --id PL-2026-0002 \
      --type trial --days 30

  # Club: multi-seat venue license
  python3 tool/issue_license.py --customer "Club" --id PL-2026-0003 \
      --type club --devices 5

  # Full license, explicit type
  python3 tool/issue_license.py --customer "Nima" --id PL-2026-0005 \
      --type full

  # Lock to one specific device (customer sends you their Device ID)
  python3 tool/issue_license.py --customer "Sam" --id PL-2026-0004 \
      --bind <64-char-device-id>

  # Print the modulus to paste into lib/license/license_keys.dart
  python3 tool/issue_license.py --print-modulus

FIRST-TIME SETUP (already done — the production key exists)
  KEYDIR=~/.pokerledger/signing
  mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR"
  openssl genrsa -out "$KEYDIR/pokerledger_production_private_key.pem" 2048
  chmod 600 "$KEYDIR/pokerledger_production_private_key.pem"

  Then run --print-modulus and paste the result into license_keys.dart.

KEY LOCATION
  The production private key is stored OUTSIDE this project, by default:
      ~/.pokerledger/signing/pokerledger_production_private_key.pem
  Override with the POKERLEDGER_KEY_DIR environment variable.

  It is deliberately not in the repo so it cannot be committed to git or
  swept into a distributable ZIP of the project.

SECURITY
  Never distribute the private key, never commit it, never put it in a
  build. Back it up somewhere safe: losing it means you can no longer
  issue licenses, and every future license would need a new key plus an
  app update. If it leaks, generate a new pair, update license_keys.dart,
  rebuild, and re-issue every license.
"""

import argparse
import base64
import datetime
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# PRODUCTION SIGNING KEY — DELIBERATELY OUTSIDE THE PROJECT TREE.
#
# The private key lives in the owner's home directory, NOT in the repo, so
# it cannot be committed to git, cannot be swept into a ZIP of the
# project, and cannot leak by publishing the source. Only this tool reads
# it. The app needs only the PUBLIC modulus, which is embedded in
# lib/license/license_keys.dart.
#
# Override with POKERLEDGER_KEY_DIR if you keep keys on a USB stick or in
# a mounted secure folder:
#   export POKERLEDGER_KEY_DIR=/Volumes/SecureKey/pokerledger
DEFAULT_KEY_DIR = os.path.join(
    os.path.expanduser("~"), ".pokerledger", "signing"
)
KEY_DIR = os.environ.get("POKERLEDGER_KEY_DIR", DEFAULT_KEY_DIR)
PRIVATE_KEY = os.path.join(KEY_DIR, "pokerledger_production_private_key.pem")
PUBLIC_KEY = os.path.join(KEY_DIR, "pokerledger_production_public_key.pem")

PREFIX = "PLK1"
FORMAT_VERSION = 1

# Kept in sync with lib/license/license_policy.dart. The app applies the
# same floor, so an owner license always covers at least this many of the
# owner's own devices even if issued before the owner policy existed.
DEFAULT_OWNER_DEVICES = 3
DEFAULT_CUSTOMER_DEVICES = 1
MAX_DEVICES = 25

CUSTOMER_TYPES = ("standard", "full", "trial", "club")
ALL_TYPES = CUSTOMER_TYPES + ("owner",)


def b64url(data: bytes) -> str:
    """Base64url without padding — the app pads it back on decode."""
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def read_public_modulus() -> int:
    """Parse the SubjectPublicKeyInfo DER to recover (n, e)."""
    with open(PUBLIC_KEY) as fh:
        pem = fh.read()
    der = base64.b64decode(
        "".join(line for line in pem.splitlines() if "KEY" not in line)
    )

    def read_tlv(buf, i):
        tag = buf[i]
        i += 1
        length = buf[i]
        i += 1
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(buf[i:i + count], "big")
            i += count
        return tag, length, i

    _, _, i = read_tlv(der, 0)          # outer SEQUENCE
    _, alg_len, j = read_tlv(der, i)    # AlgorithmIdentifier
    i = j + alg_len
    _, _, i = read_tlv(der, i)          # BIT STRING
    i += 1                              # unused-bits byte
    _, _, i = read_tlv(der, i)          # RSAPublicKey SEQUENCE
    _, mod_len, i = read_tlv(der, i)    # modulus INTEGER
    modulus = int.from_bytes(der[i:i + mod_len], "big")
    return modulus


def print_modulus() -> None:
    n = read_public_modulus()
    hex_n = "%x" % n
    print(f"// {n.bit_length()}-bit modulus — paste into "
          f"lib/license/license_keys.dart\n")
    print("  static const String modulusHex =")
    chunks = [hex_n[k:k + 64] for k in range(0, len(hex_n), 64)]
    for idx, chunk in enumerate(chunks):
        tail = ";" if idx == len(chunks) - 1 else ""
        print(f"      '{chunk}'{tail}")


def sign(payload_bytes: bytes) -> bytes:
    """RSASSA-PKCS1-v1_5 over SHA-256, via openssl."""
    if not os.path.exists(PRIVATE_KEY):
        sys.exit(
            f"Production signing key not found at:\n  {PRIVATE_KEY}\n\n"
            "This key is stored outside the project on purpose. If this "
            "is a fresh machine, restore it from your backup, or point "
            "the tool at it:\n"
            "  export POKERLEDGER_KEY_DIR=/path/to/your/keys\n\n"
            "To create a NEW pair (invalidates every existing license):\n"
            f"  mkdir -p {KEY_DIR} && chmod 700 {KEY_DIR}\n"
            f"  openssl genrsa -out {PRIVATE_KEY} 2048\n"
            f"  chmod 600 {PRIVATE_KEY}\n"
            f"  openssl rsa -in {PRIVATE_KEY} -pubout -out {PUBLIC_KEY}\n"
            "  python3 tool/issue_license.py --print-modulus"
        )
    with tempfile.NamedTemporaryFile(delete=False) as payload_file:
        payload_file.write(payload_bytes)
        payload_path = payload_file.name
    sig_path = payload_path + ".sig"
    try:
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", PRIVATE_KEY,
             "-out", sig_path, payload_path],
            check=True,
        )
        with open(sig_path, "rb") as fh:
            return fh.read()
    finally:
        for path in (payload_path, sig_path):
            if os.path.exists(path):
                os.unlink(path)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Issue a signed Poker Ledger license key."
    )
    parser.add_argument("--customer", help="Customer display name")
    parser.add_argument("--customer-id", default="",
                        help="Your internal customer reference")
    parser.add_argument("--id", dest="license_id",
                        help="License ID, e.g. PL-2026-0001")
    parser.add_argument("--type", default=None, choices=list(ALL_TYPES),
                        help="Customer license type (default: standard)")
    parser.add_argument("--owner", action="store_true",
                        help="Issue YOUR owner master license: multi-device, "
                             "never expires.")
    parser.add_argument("--owner-devices", type=int,
                        default=DEFAULT_OWNER_DEVICES,
                        help=f"Devices the owner license covers "
                             f"(default {DEFAULT_OWNER_DEVICES})")
    parser.add_argument("--days", type=int, default=None,
                        help="Valid for N days. Omit for perpetual.")
    parser.add_argument("--devices", type=int, default=None,
                        help=f"Device limit (default "
                             f"{DEFAULT_CUSTOMER_DEVICES} for customers)")
    parser.add_argument("--bind", action="append", default=[],
                        help="Pre-bind to a specific Device ID. Repeatable.")
    parser.add_argument("--print-modulus", action="store_true",
                        help="Print the public modulus for license_keys.dart")
    args = parser.parse_args()

    if args.print_modulus:
        print_modulus()
        return

    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    if args.owner:
        # --- OWNER LICENSE -------------------------------------------
        # Deliberately opinionated so the master key cannot be issued
        # wrong by accident: never expires, always multi-device.
        if args.type not in (None, "owner"):
            parser.error("--owner already implies --type owner")
        if args.days is not None:
            parser.error(
                "The owner license never expires; --days is not allowed. "
                "Issue a customer license if you want an expiry."
            )
        license_type = "owner"
        devices = args.devices or args.owner_devices
        customer_name = args.customer or "Software Owner"
        license_id = args.license_id or f"PL-OWNER-{now.strftime('%Y%m%d')}"
        customer_id = args.customer_id or "OWNER"
        expires = None
    else:
        # --- CUSTOMER LICENSE ----------------------------------------
        # Unchanged from before: same defaults, same behaviour.
        if not args.customer or not args.license_id:
            parser.error(
                "--customer and --id are required for a customer license "
                "(or pass --owner to issue your master license)"
            )
        license_type = args.type or "standard"
        if license_type == "owner":
            parser.error(
                "Refusing to issue an owner license to a customer. "
                "Use --owner for your own master license."
            )
        devices = args.devices or DEFAULT_CUSTOMER_DEVICES
        customer_name = args.customer
        license_id = args.license_id
        customer_id = args.customer_id or args.license_id
        expires = args.days

    if devices < 1 or devices > MAX_DEVICES:
        parser.error(f"--devices must be between 1 and {MAX_DEVICES}")

    payload = {
        "v": FORMAT_VERSION,
        "license_id": license_id,
        "customer_id": customer_id,
        "customer_name": customer_name,
        "type": license_type,
        "issued_at": now.isoformat().replace("+00:00", "Z"),
        "device_limit": devices,
    }
    if expires is not None:
        expiry = now + datetime.timedelta(days=expires)
        payload["expires_at"] = expiry.isoformat().replace("+00:00", "Z")
    if args.bind:
        payload["bound_devices"] = args.bind

    # Compact, key-sorted JSON so the exact bytes are reproducible.
    payload_bytes = json.dumps(
        payload, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")

    signature = sign(payload_bytes)
    blob = f"{PREFIX}.{b64url(payload_bytes)}.{b64url(signature)}"

    banner = ("OWNER MASTER LICENSE" if license_type == "owner"
              else "CUSTOMER LICENSE")
    print("=" * 62)
    print(f"{banner} ISSUED")
    print("=" * 62)
    for key, value in payload.items():
        print(f"  {key:<14} {value}")
    print("=" * 62)
    if license_type == "owner":
        print("This is YOUR master key. Keep it private — do not send it")
        print(f"to customers. Activates up to {devices} of your own devices:\n")
    else:
        print("Send this key to the customer:\n")
    print(blob)
    print()


if __name__ == "__main__":
    main()
