#!/usr/bin/env python3
"""Stable local NoSleep identity; does not provide Developer ID or notarization.

The non-extractable private key lives in a separate, owned development Keychain.
Only its exact signing key receives the Apple partition required by codesign;
its application ACL stays restricted to /usr/bin/codesign. No existing signing
key, system trust or TCC permission is modified. The new Keychain password is
stored in one owned generic item, restricted to /usr/bin/security. Secret
commands use security's stdin interpreter, never process argv, logs or files.

Apple's primary reference for the interpreter and partition semantics:
https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/security.c
https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/security.1
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import tempfile
import uuid

CONFIG = Path.home() / "Library/Application Support/NoSleep-Development/signing-identity-v2.json"
OWNED_BUNDLE = "local.robert.keepawake"
FIXTURE_PREFIX = "local.robert.nosleep.identity-probe."
PASSWORD_SERVICE = "local.robert.nosleep.development-signing"
KEY_LABEL = "Imported Private Key"


class SigningError(RuntimeError):
    pass


def run(arguments: list[str], *, timeout: float = 15, allowed: tuple[int, ...] = (0,), input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(arguments, stdin=subprocess.DEVNULL if input_text is None else None,
                                input=input_text, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise SigningError("Local development operation timed out; no repeated permission request was made.") from error
    if result.returncode not in allowed:
        # Commands never receive passwords, key bytes, or certificate contents in argv.
        # Their stdout is deliberately not reported: imports may otherwise be verbose.
        message = result.stderr.strip().splitlines()
        detail = message[-1][:240] if message else "operation rejected"
        raise SigningError(f"{Path(arguments[0]).name}: {detail}")
    return result


def security_command(arguments: list[str], *, timeout: float = 15) -> None:
    """Run one secret-bearing command through security's documented stdin mode.

The command interpreter receives a pipe, not a TTY, so it does not echo its
input. There is no shell. Never include the payload or child output in errors.
Each invocation contains exactly one command: a later success cannot hide an
earlier failure. The quotes match Apple's split_line parser, not shell syntax.
"""
    if len(arguments) > 30 or any("\n" in value or "\r" in value or "\0" in value for value in arguments):
        raise SigningError("Invalid development command input.")
    payload = " ".join('"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"' for value in arguments) + "\n"
    if len(payload.encode()) > 4000:
        raise SigningError("Development command input exceeds security's bound.")
    try:
        result = subprocess.run(["/usr/bin/security", "-i", "-q"], input=payload,
                                capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise SigningError("Owned Keychain operation timed out; no permission retry was made.") from error
    if result.returncode != 0:
        raise SigningError("Owned Keychain operation was rejected (status " + str(result.returncode) + ").")


def detach_owned_keychain(path: Path) -> None:
    # Creation can add a Keychain to the user's search list. Remove only this
    # newly owned entry, preserving the current ordering of every other entry.
    listing = run(["/usr/bin/security", "list-keychains", "-d", "user"]).stdout
    values = [line.strip()[1:-1] for line in listing.splitlines()
              if line.strip().startswith('"') and line.strip().endswith('"')]
    kept = [value for value in values if Path(value).resolve() != path.resolve()]
    if len(kept) != len(values):
        run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *kept])


def default_keychain() -> Path:
    output = run(["/usr/bin/security", "default-keychain", "-d", "user"]).stdout.strip()
    if len(output) > 4096 or not output.startswith('"') or not output.endswith('"'):
        raise SigningError("Cannot identify the user's default Keychain.")
    return Path(output[1:-1]).resolve()


def private_directory(path: Path) -> None:
    if path.is_symlink():
        raise SigningError("Signing configuration directory must not be a symlink.")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.stat().st_uid != os.getuid():
        raise SigningError("Signing configuration must belong to the current user.")
    os.chmod(path, 0o700)


def fingerprint(value: str) -> str:
    if not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        raise SigningError("Expected an exact SHA-1 certificate fingerprint.")
    return value.upper()


def read_config(path: Path) -> dict:
    if path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_size > 8192 or path.stat().st_mode & 0o077:
        raise SigningError("Invalid local signing configuration.")
    value = json.loads(path.read_text())
    if value.get("version") != 2 or not str(value.get("certificateName", "")).startswith("NoSleep Local Development "):
        raise SigningError("This configuration is not a NoSleep development identity.")
    value["identity"] = fingerprint(value.get("identity", ""))
    chain = Path(value.get("keychain", ""))
    if chain.is_symlink() or chain.parent.resolve() != path.parent.resolve() or not chain.name.startswith("NoSleep-Development-") or chain.suffix != ".keychain-db":
        raise SigningError("Signing must use the separate owned development Keychain.")
    if not chain.is_file() or chain.stat().st_uid != os.getuid() or chain.stat().st_mode & 0o077:
        raise SigningError("Owned development Keychain has unsafe permissions.")
    if value.get("passwordService") != PASSWORD_SERVICE or not re.fullmatch(r"NoSleep-Development-[a-f0-9]{32}", value.get("passwordAccount", "")):
        raise SigningError("Invalid scoped development password reference.")
    return value


def keychain_password(configuration: dict) -> str:
    # Only our explicit service/account is queried. Output stays in memory and
    # is never included in a receipt, print, environment variable or subprocess
    # argument. The creating Apple security tool is the only trusted reader.
    if not keychain_unlocked(Path(configuration["passwordKeychain"])):
        raise SigningError("The user Keychain is locked; unlock it in Keychain Access before local signing. No password prompt was requested.")
    result = run(["/usr/bin/security", "find-generic-password", "-s", PASSWORD_SERVICE,
                  "-a", configuration["passwordAccount"], "-w", configuration["passwordKeychain"]], timeout=10)
    password = result.stdout.rstrip("\n")
    if not re.fullmatch(r"[a-f0-9]{64}", password):
        raise SigningError("Owned development Keychain password is unavailable.")
    return password


def keychain_unlocked(path: Path) -> bool:
    """Read public status flags only; never unlock or request authentication."""
    security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
    foundation = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    security.SecKeychainOpen.restype = ctypes.c_int32
    security.SecKeychainGetStatus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    security.SecKeychainGetStatus.restype = ctypes.c_int32
    foundation.CFRelease.argtypes = [ctypes.c_void_p]
    reference = ctypes.c_void_p(); status = ctypes.c_uint32()
    if security.SecKeychainOpen(os.fsencode(path), ctypes.byref(reference)) != 0 or not reference.value:
        return False
    try:
        # Public Security/SecKeychain.h: kSecUnlockStateStatus = 1.
        return security.SecKeychainGetStatus(reference, ctypes.byref(status)) == 0 and bool(status.value & 1)
    finally:
        foundation.CFRelease(reference)


def verify_private_key(configuration: dict) -> None:
    # The modern SecItem attribute view omits extractability for legacy file
    # Keychains. security find-key exposes only the metadata, including the
    # public SecKey.h tags kSecKeyExtractable=16 and kSecKeySign=21. No data is
    # exported. Keep this read restricted to the exact separate Keychain.
    result = run(["/usr/bin/security", "find-key", "-s", "-t", "private", configuration["keychain"]])
    text = result.stdout
    if len(text) > 8192 or len(re.findall(r"^class:", text, re.MULTILINE)) != 1:
        raise SigningError("The owned development Keychain must contain exactly one signing key.")
    expected = (r'0x00000001\s+<blob>="Imported Private Key"',
                r"0x00000010\s+<uint32>=0x00000000", r"0x00000015\s+<uint32>=0x00000001")
    if any(re.search(pattern, text) is None for pattern in expected):
        raise SigningError("The owned signing key's non-extractable attributes are not confirmed.")


def lock_owned_keychain(configuration: dict) -> None:
    run(["/usr/bin/security", "lock-keychain", configuration["keychain"]])


def certificate_present(configuration: dict) -> None:
    result = run(["/usr/bin/security", "find-certificate", "-a", "-c", configuration["certificateName"],
                  "-Z", configuration["keychain"]], allowed=(0, 44))
    hashes = re.findall(r"SHA-1 hash:\s*([A-Fa-f0-9]{40})", result.stdout)
    if configuration["identity"] not in {item.upper() for item in hashes}:
        raise SigningError("The saved development certificate is absent; no replacement identity was generated.")


def ensure(configuration_path: Path, keychain: Path | None = None) -> dict:
    configuration_path = configuration_path.expanduser().absolute()
    private_directory(configuration_path.parent)
    if configuration_path.exists():
        configuration = read_config(configuration_path)
        if keychain is not None and Path(configuration["keychain"]).resolve() != keychain.expanduser().resolve():
            raise SigningError("The saved identity belongs to another Keychain.")
        certificate_present(configuration)
        return configuration
    instance = uuid.uuid4().hex
    selected = (keychain.expanduser().absolute() if keychain else configuration_path.parent / ("NoSleep-Development-" + instance + ".keychain-db"))
    if selected.parent.resolve() != configuration_path.parent.resolve() or not selected.name.startswith("NoSleep-Development-") or selected.suffix != ".keychain-db" or selected.exists() or selected.is_symlink():
        raise SigningError("Creation requires a new separate NoSleep development Keychain in the configuration directory.")
    password_chain = default_keychain()
    if not keychain_unlocked(password_chain):
        raise SigningError("The user Keychain is locked; unlock it before creating a local development identity. No password prompt was requested.")
    password = secrets.token_hex(32)
    password_account = "NoSleep-Development-" + instance
    certificate_name = "NoSleep Local Development " + instance[:12]
    created = False; saved_password = False
    old_mask = os.umask(0o077)
    try:
        security_command(["create-keychain", "-p", password, str(selected)]); created = True
        os.chmod(selected, 0o600)
        detach_owned_keychain(selected)
        run(["/usr/bin/security", "set-keychain-settings", "-l", "-u", "-t", "120", str(selected)])
        with tempfile.TemporaryDirectory(prefix="NoSleep-development-identity-") as temporary:
            directory = Path(temporary); os.chmod(directory, 0o700)
            private_key = directory / (certificate_name.replace(" ", "-") + ".key")
            certificate = directory / "certificate.pem"
            run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes", "-batch",
                 "-days", "3650", "-subj", "/CN=" + certificate_name + "/OU=NoSleep Local Development/O=NoSleep",
                 "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                 "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                 "-addext", "extendedKeyUsage=codeSigning",
                 "-keyout", str(private_key), "-out", str(certificate)], timeout=90)
            os.chmod(private_key, 0o600); os.chmod(certificate, 0o600)
            certificate_der = subprocess.run(["/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "DER"],
                                             stdin=subprocess.DEVNULL, capture_output=True, check=True).stdout
            identity = hashlib.sha1(certificate_der).hexdigest().upper()
            # No -A, wrapping password, global trust registration, or exportable private key.
            run(["/usr/bin/security", "import", str(certificate), "-k", str(selected)])
            run(["/usr/bin/security", "import", str(private_key), "-k", str(selected), "-t", "priv",
                 "-x", "-T", "/usr/bin/codesign"])
            configuration = {"version": 2, "identity": identity, "certificateSHA256": hashlib.sha256(certificate_der).hexdigest(),
                             "certificateName": certificate_name, "keychain": str(selected), "kind": "local-self-signed",
                             "privateKey": "non-extractable; /usr/bin/codesign only", "developerID": False, "notarized": False,
                             "passwordService": PASSWORD_SERVICE, "passwordAccount": password_account,
                             "passwordKeychain": str(password_chain)}
            certificate_present(configuration)
            verify_private_key(configuration)
            # This Keychain contains exactly one private signing key, whose
            # immutable label/class/signing attributes were verified above.
            # The Apple partition supplements the exact codesign application
            # ACL; no partition/ACL on another Keychain is touched.
            security_command(["set-key-partition-list", "-S", "apple:", "-s", "-t", "private", "-l", KEY_LABEL,
                              "-k", password, str(selected)])
            security_command(["add-generic-password", "-s", PASSWORD_SERVICE, "-a", password_account,
                              "-w", password, "-T", "/usr/bin/security", str(password_chain)])
            saved_password = True
            if keychain_password(configuration) != password:
                raise SigningError("Owned development password storage verification failed.")
            lock_owned_keychain(configuration)
            fd = os.open(configuration_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "w") as handle:
                json.dump(configuration, handle, indent=2); handle.write("\n")
    except Exception:
        if saved_password:
            run(["/usr/bin/security", "delete-generic-password", "-s", PASSWORD_SERVICE,
                 "-a", password_account, str(password_chain)], allowed=(0, 44))
        if created:
            run(["/usr/bin/security", "delete-keychain", str(selected)], allowed=(0, 44))
        raise
    finally:
        os.umask(old_mask)
    return configuration


def requirement(bundle_identifier: str, identity: str) -> str:
    if not re.fullmatch(r"[a-zA-Z0-9.-]{1,160}", bundle_identifier):
        raise SigningError("Invalid bundle identifier.")
    if bundle_identifier != OWNED_BUNDLE and not bundle_identifier.startswith(FIXTURE_PREFIX):
        raise SigningError("This signer is restricted to NoSleep and its isolated identity probes.")
    certificate = fingerprint(identity)
    return f'designated => identifier "{bundle_identifier}" and anchor H"{certificate}" and certificate leaf = H"{certificate}"'


def signing_preflight(app: Path) -> str:
    app = app.expanduser().resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise SigningError("Expected an existing NoSleep .app bundle.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    bundle = info.get("CFBundleIdentifier", "")
    executable = info.get("CFBundleExecutable", "")
    if not re.fullmatch(r"[a-zA-Z0-9_.+-]{1,100}", executable) or executable in (".", ".."):
        raise SigningError("Invalid bundle executable.")
    binary = app / "Contents/MacOS" / executable
    if not binary.is_file():
        raise SigningError("Bundle executable is missing.")
    active = subprocess.run(["/usr/sbin/lsof", "-t", "--", str(binary)], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=10)
    if active.returncode == 0:
        raise SigningError("This bundle is running; sign a separate candidate.")
    if active.returncode != 1 or active.stdout.strip() or active.stderr.strip():
        raise SigningError("Cannot verify that this bundle is stopped; sign a separate candidate.")
    return bundle


def sign(app: Path, configuration: dict, supplied_identity: str | None = None) -> dict:
    app = app.expanduser().resolve()
    bundle = signing_preflight(app)
    identity = configuration["identity"]
    if supplied_identity and fingerprint(supplied_identity) != identity:
        raise SigningError("Requested identity does not match the saved NoSleep development certificate.")
    certificate_present(configuration)
    designated = requirement(bundle, identity)
    password = keychain_password(configuration)
    security_command(["unlock-keychain", "-p", password, configuration["keychain"]])
    try:
        verify_private_key(configuration)
        run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", configuration["keychain"],
             "--timestamp=none", "--requirements", "=" + designated, str(app)], timeout=30)
        expression = designated.split("=>", 1)[1].strip()
        run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--test-requirement", "=" + expression, str(app)])
    finally:
        lock_owned_keychain(configuration)
    return {"app": str(app), "identity": identity, "designatedRequirement": designated,
            "kind": "local-self-signed", "developerID": False, "notarized": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("ensure", "sign"))
    parser.add_argument("app", nargs="?", type=Path)
    parser.add_argument("--config", type=Path, default=CONFIG)
    parser.add_argument("--keychain", type=Path)
    parser.add_argument("--identity", help="Exact public fingerprint; must match the saved local identity")
    arguments = parser.parse_args()
    try:
        if arguments.operation == "sign":
            if arguments.app is None:
                raise SigningError("sign requires the candidate .app path")
            # Refuse uncertain activity before ensure can query/create a Keychain.
            signing_preflight(arguments.app)
        configuration = ensure(arguments.config, arguments.keychain)
        if arguments.operation == "sign":
            result = sign(arguments.app, configuration, arguments.identity)
        else:
            result = configuration
        print(json.dumps(result, indent=2))
        return 0
    except (SigningError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("Local signing failed: " + str(error), file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
