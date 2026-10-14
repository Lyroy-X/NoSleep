# External keyboard roundtrip in the owned macOS guest

This optional receiver tests actual external VNC keyboard input, independently of
the AppKit Cmd-V/private-pasteboard scenarios. It accepts **only** a synthetic
42-character ASCII value; it does not read Cisco fields, real credentials or any
clipboard. Building does not launch a window.

```sh
python3 tests/ui_harness/vnc_input/build.py --guest-mac <exact-owned-guest-MAC>
```

The new ignored output contains a `package/` directory and a host-private
`dummy.txt` with mode 0600. Transfer only `package/` into the explicitly owned
guest; never place the dummy file in the shared package or print its contents.
The package requires an Apple Silicon macOS 13+ VirtualMac, UID 501, console user
`admin` and the exact specified en0 MAC. The receiver checks these before creating
AppKit and again before reporting an active, key, focused test window.

Coordinate exclusive guest focus with its owner. Run the application through
LaunchServices with two arguments: a new writable guest output directory and the
transferred `public-config.json`. `ready.json` supplies a nonce, PID, application,
window/focus state, guest identity and expected hash/length. The owned VNC driver
must validate that marker before typing the generated dummy into this test window.
Typing uses the existing explicitly owned guest transport; this directory never
opens a VNC socket or controls another application itself. Touch `input-finished`
after the driver completes to obtain a finite mismatch result.

The receiver waits at most five seconds for actual focus and 30 seconds for input.
It writes only length, SHA256 and match result, clears its secure field and closes
its window. It fails on lost focus, identity mismatch, timeout or changed input;
no repeated activation, fallback to Cisco fields or clipboard paste is allowed.

A match proves this synthetic external keyboard path preserves all 42 characters.
It does not prove Cisco accepted a password, authentication, a tunnel, Keychain
permissions or physical keyboard input on the main Mac. Keep its distinct receipt
alongside the other ignored test outputs.
