#!/usr/bin/env python3
"""Prepare/use one pinned stock-ocserv session termination; no default action.

This is a lab stimulus, not a NoSleep disconnect API or an expiry/reconnect
acceptance result. Any uncertain mutation can only be inspected, never retried.
Raw server rows, selected numeric ID and CLI output stay in private memory.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import tarfile
import time

ROOT = Path(__file__).resolve().parents[2]
RUN = "f0b5145836a1"
ARCHIVE_SHA = "e35d748a5244b10be3a92ad4df95a534c8280c43680eecaf3cb1b20d2a22b1a5"
GUARDIAN_SHA = "554d39adbaaccfab1a1d48c155f2556a3915303eb3577f4b531f795f5da99635"
# Historical receipt attestations do not change the runtime import freeze.
HISTORY_RUNNER_SHAS = frozenset({
    "fccef9b1f35354e75d33753c46bb3f36319d8026793c120430b8f82ea2e7f89f",
    GUARDIAN_SHA,
})
HEALTHY_CONTROLLER_SHA = "4ba478e85f07c8438166676173bb5cf46ae9e9e366fce24d3702ed513ebb4a6d"
SHA = re.compile(r"[0-9a-f]{64}\Z")
SESSION = re.compile(r"[0-9a-f]{32}\Z")


class Refused(Exception):
    pass


def require(value, reason):
    if not value:
        raise Refused(reason)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-server-field")
        result[key] = value
    return result


def select_unique_id(data, expected):
    require(type(data) is bytes and len(data) <= 65536 and type(expected) is str and SHA.fullmatch(expected), "server-selection-refused")
    try:
        rows = json.loads(data, object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        raise Refused("server-selection-refused") from None
    require(type(rows) is list and len(rows) == 1 and type(rows[0]) is dict, "unique-client-required")
    identifier = rows[0].get("ID")
    state = rows[0].get("State", rows[0].get("Status"))
    require(type(identifier) is int and 0 < identifier < 2**31 and type(state) is str and state.lower() in {"connected", "authenticated"}, "server-selection-refused")
    fingerprint = hashlib.sha256(json.dumps([str(identifier)]).encode()).hexdigest()
    require(fingerprint == expected, "server-fingerprint-changed")
    return identifier


def fixed_command(docker, container, identifier):
    require(type(container) is str and SHA.fullmatch(container) and type(identifier) is int and 0 < identifier < 2**31, "target-refused")
    return [docker, "exec", container, "occtl", "terminate", "id", str(identifier)]


def stock_api_proof():
    archive = ROOT / "build/vpn-lab/ocserv-1.4.2.tar.xz"
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == ARCHIVE_SHA, "stock-source-refused")
    with tarfile.open(archive) as source:
        def read(name):
            member = source.getmember("ocserv-1.4.2/" + name)
            require(member.isfile() and member.size < 262144, "stock-source-refused")
            return source.extractfile(member).read().decode()
        dispatch = read("src/occtl/occtl.c")
        method = read("src/main-ctl-unix.c").split("static void method_terminate_id(method_ctx *ctx, int cfd, uint8_t *msg,", 2)[-1].split("static void method_terminate_session", 1)[0]
        require('ENTRY("terminate id", "[ID]", handle_terminate_id_cmd' in dispatch and
                "ctmp->pid == req->id" in method and "calc_safe_id(ctmp->sid" in method and
                "terminate_session_in_secmod(ctx, safe_id" in method, "stock-source-refused")
    return {"release": "1.4.2", "archiveSHA256": ARCHIVE_SHA, "numericConnectionOnly": True,
            "cookieInvalidationRequested": True, "exitDoesNotProveCookieInvalidation": True}


def guardian_module():
    path = ROOT / "tests/cli_lab_session_acceptance.py"
    require(hashlib.sha256(path.read_bytes()).hexdigest() == GUARDIAN_SHA, "guardian-freeze-refused")
    spec = importlib.util.spec_from_file_location("frozen_stimulus_guardian", path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def read_users(docker, container):
    # Only this read-only Docker CLI child is cancelled on a read fault.
    process = subprocess.Popen([docker, "exec", container, "occtl", "--json", "show", "users"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    data = bytearray(); deadline = time.monotonic() + 5
    try:
        while selector.get_map():
            require(time.monotonic() < deadline, "server-read-unavailable")
            for key, _ in selector.select(.1):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk: selector.unregister(key.fileobj); continue
                require(len(data) + len(chunk) <= 65536, "server-read-budget")
                data.extend(chunk)
        require(process.wait(timeout=max(.1, deadline-time.monotonic())) == 0, "server-read-unavailable")
        return bytes(data)
    finally:
        selector.close(); process.stdout.close()
        data[:] = b"\0" * len(data); data.clear()
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=2)


def historical_receipt(guardian, directory, path, expected, build):
    require(type(build) is dict and set(build) == {"binarySHA256", "infoSHA256", "sourceReceiptSHA256", "sourceHashes", "version"} and
            all(type(build[k]) is str and SHA.fullmatch(build[k]) for k in ("binarySHA256", "infoSHA256", "sourceReceiptSHA256")) and
            type(build["version"]) is str and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", build["version"]) and
            type(build["sourceHashes"]) is dict and 1 <= len(build["sourceHashes"]) <= 64 and
            all(type(k) is str and re.fullmatch(r"Sources/[A-Za-z0-9_]+\.swift", k) and type(v) is str and SHA.fullmatch(v) for k,v in build["sourceHashes"].items()) and
            build["sourceHashes"].get("Sources/CiscoGUIRecovery.swift") == HEALTHY_CONTROLLER_SHA, "history-build-refused")
    require(type(path) is str and type(expected) is str and SHA.fullmatch(expected), "history-binding-refused")
    file = Path(path)
    require(file.is_absolute() and file == file.resolve() and file.parent == directory and
            re.fullmatch(r"receipt-[0-9a-f]{32}\.json", file.name), "history-path-refused")
    guardian.owned_file(directory, directory=True); guardian.owned_file(file)
    require(file.stat().st_size <= 131072, "history-budget-refused")
    data = file.read_bytes(); require(hashlib.sha256(data).hexdigest() == expected, "history-hash-refused")
    value = guardian.bounded_json(data, 131072)
    keys = {"schema", "result", "scope", "build", "runnerSHA256", "mainActions", "rawOutputPersisted", "schedulingInjection", "before", "serverBefore", "originalNativeState", "originalServer", "observation", "server", "commandCompleted", "nonce"}
    require(type(value) is dict and set(value) in (keys, keys | {"existingExecutionReused"}) and
            type(value["schema"]) is int and value["schema"] == 1 and value["result"] == "passed" and
            value["scope"] == "persistent actual guest session; independent server and fresh nonce" and
            value["build"] == build and type(value["runnerSHA256"]) is str and value["runnerSHA256"] in HISTORY_RUNNER_SHAS and
            type(value["mainActions"]) is int and value["mainActions"] == 0 and
            value["rawOutputPersisted"] is False and value["schedulingInjection"] is False and
            value["commandCompleted"] is True, "history-schema-refused")
    if "existingExecutionReused" in value: require(value["existingExecutionReused"] is False, "history-replay-refused")
    for key in ("before", "observation"): guardian.typed_observation(value[key])
    for key in ("serverBefore", "originalServer", "server"): guardian.typed_server(value[key])
    require(value["originalNativeState"] == value["before"]["nativeState"] and value["originalServer"] == value["serverBefore"], "history-baseline-refused")
    guardian.typed_nonce(value["nonce"])
    return value


def healthy_history(guardian, directory, args, state):
    auth_path, auth_sha = args.auth_receipt, args.auth_receipt_sha256
    resume_path, resume_sha = args.resume_receipt, args.resume_receipt_sha256
    if all(value is None for value in (auth_path, auth_sha, resume_path, resume_sha)): return None
    auth = historical_receipt(guardian, directory, auth_path, auth_sha, state["build"])
    old, authenticated = auth["before"]["checkpoint"], auth["observation"]["checkpoint"]
    require(old is not None and authenticated is not None and old["processGeneration"] == authenticated["processGeneration"] == 1 and
            authenticated["sameInitialRevision"] and old["sameInitialRevision"] and authenticated["persistedEnabled"] and
            authenticated["commandSequence"] == authenticated["completedCommandSequence"] == old["commandSequence"] + 1 and
            old["commandSequence"] == old["completedCommandSequence"] == 0 and authenticated["operation"] == "enable" and
            authenticated["phase"] == "ready" and auth["before"]["nativeState"] == "disconnected" and auth["serverBefore"]["clientCount"] == 0 and
            old["counters"]["saves"] == 1 and old["counters"]["metadataReads"] == authenticated["counters"]["metadataReads"] == 1 and
            all(old["counters"][k] == 0 for k in guardian.COUNTERS - {"saves", "metadataReads"}) and
            authenticated["counters"]["saves"] == 1 and authenticated["counters"]["deletes"] == authenticated["counters"]["authorizations"] == 0 and
            guardian.matches("new-connected", auth["observation"], old, auth["server"]), "history-auth-refused")
    resume = None
    if resume_path is not None or resume_sha is not None:
        resume = historical_receipt(guardian, directory, resume_path, resume_sha, state["build"])
        before, after = resume["before"]["checkpoint"], resume["observation"]["checkpoint"]
        require(before is not None and after is not None and before["processGeneration"] == 1 and after["processGeneration"] == 2 and
                before["phase"] == "stopped" and before["operation"] == "stop" and not resume["before"]["processLive"] and
                before["persistedEnabled"] and after["enabled"] and after["persistedEnabled"] and after["phase"] == "ready" and
                resume["before"]["nativeState"] == "connected" and resume["observation"]["guiState"] == "absent" and not after["guiPresent"] and
                before["sameInitialRevision"] and after["sameInitialRevision"] and before["revisionMatchesDescriptor"] and after["revisionMatchesDescriptor"] and
                before["commandSequence"] == before["completedCommandSequence"] == authenticated["commandSequence"] + 1 and
                all(after[k] == before[k] for k in ("commandSequence", "completedCommandSequence", "operation", "challenge")) and
                all(before["counters"][k] == authenticated["counters"][k] for k in guardian.COUNTERS) and
                after["counters"]["metadataReads"] == before["counters"]["metadataReads"] + 1 and
                resume["originalServer"] == auth["server"] == resume["server"] and
                guardian.matches("preserved-connected", resume["observation"], before, resume["server"]), "history-resume-refused")
        guardian.typed_nonce(resume["nonce"], auth["nonce"]["challengeFingerprint"])
    return dict(auth=auth, resume=resume, authSHA256=auth_sha, resumeSHA256=resume_sha)


def historical_healthy_ready(guardian, current, history):
    require(history is not None, "healthy-history-required")
    auth = history["auth"]["observation"]["checkpoint"]
    resume = history["resume"]
    baseline = resume["observation"]["checkpoint"] if resume is not None else auth
    require(current["processGeneration"] == baseline["processGeneration"] and current["sameInitialRevision"] and
            current["phase"] == "ready" and current["stage"] == "connected" and current["issue"] is None and current["failure"] is None and
            not any(current[k] for k in ("submitted", "confirmed", "rejected", "budgetPresent", "guiPresent")) and
            current["budgetAttempts"] == current["budgetLogins"] == 0 and
            all(current[k] == baseline[k] for k in ("commandSequence", "completedCommandSequence", "operation", "challenge", "newProcessPID")) and
            current["counters"] == baseline["counters"] and current["checkpointSequence"] >= baseline["checkpointSequence"], "healthy-history-current-refused")
    guardian.monotonic_checkpoint(baseline, current)


def before_ready(guardian, facts, checkpoint, history=None):
    facts = guardian.typed_observation(facts); checkpoint = guardian.typed_checkpoint(checkpoint)
    current = facts["checkpoint"]
    require(current is not None and facts["processLive"] and not facts["ownedChildLive"] and facts["noConnectChild"] and
            facts["guiState"] == "absent" and facts["nativeState"] == "connected" and current["nativeFresh"] and
            current["nativeState"] == "connected" and current["enabled"] and current["persistedEnabled"] and
            current["configured"] and current["revisionMatchesDescriptor"] and
            current["driverReady"] and not current["connectionBusy"] and not current["credentialsBusy"] and not current["inFlight"] and
            current["processGeneration"] == checkpoint["processGeneration"] and current["counters"] == checkpoint["counters"], "baseline-not-ready")
    if not current["confirmed"]:
        require(history is not None, "baseline-not-ready")
        historical_healthy_ready(guardian, current, history)
    return current


def dispatch_once(journal, persist, command, invoke):
    require(journal["phase"] == "prepared", "existing-intent-inspect-only")
    journal["phase"] = "intent"; journal["mutationRequests"] = 1; persist(journal)
    try:
        code = invoke(command)
        journal["phase"] = "acknowledged" if type(code) is int and code == 0 else "uncertain"
    except Exception:
        journal["phase"] = "uncertain"
    persist(journal)


def typed_journal(guardian, value):
    keys = {"schema", "run", "phase", "operation", "originalServerFingerprint", "candidateBinarySHA256", "baseline", "beforeNonce", "mutationRequests", "stockAPI", "mainActions", "rawOutputPersisted", "cookieInvalidationProven", "actualReconnectProven"}
    require(type(value) is dict and set(value) in (keys, keys | {"inspection"}, keys | {"healthyHistory"}, keys | {"inspection", "healthyHistory"}), "journal-schema-refused")
    require(type(value["schema"]) is int and value["schema"] == 1 and value["run"] == RUN and type(value["phase"]) is str and value["phase"] in {"prepared", "intent", "acknowledged", "uncertain"} and
            value["operation"] == "terminateUniqueConnectionAndRequestCookieInvalidation" and
            all(type(value[key]) is str and SHA.fullmatch(value[key]) for key in ("originalServerFingerprint", "candidateBinarySHA256")) and
            type(value["mutationRequests"]) is int and value["mutationRequests"] in (0, 1) and
            type(value["mainActions"]) is int and value["mainActions"] == 0 and
            all(value[key] is False for key in ("rawOutputPersisted", "cookieInvalidationProven", "actualReconnectProven")), "journal-type-refused")
    require((value["phase"] == "prepared") == (value["mutationRequests"] == 0), "journal-phase-refused")
    guardian.typed_checkpoint(value["baseline"]); guardian.typed_nonce(value["beforeNonce"])
    if "healthyHistory" in value:
        history = value["healthyHistory"]
        require(type(history) is dict and set(history) == {"authReceiptSHA256", "resumeReceiptSHA256"} and
                type(history["authReceiptSHA256"]) is str and SHA.fullmatch(history["authReceiptSHA256"]) and
                (history["resumeReceiptSHA256"] is None or type(history["resumeReceiptSHA256"]) is str and SHA.fullmatch(history["resumeReceiptSHA256"])), "journal-history-refused")
    require(value["stockAPI"] == {"release": "1.4.2", "archiveSHA256": ARCHIVE_SHA, "numericConnectionOnly": True,
        "cookieInvalidationRequested": True, "exitDoesNotProveCookieInvalidation": True}, "stock-api-proof-refused")
    require(all(type(value["stockAPI"][key]) is bool for key in ("numericConnectionOnly", "cookieInvalidationRequested", "exitDoesNotProveCookieInvalidation")), "stock-api-proof-refused")
    if "inspection" in value:
        inspection = value["inspection"]
        require(type(inspection) is dict and set(inspection) == {"server", "observation", "serverZeroObserved", "nativeDisconnectedObserved"}, "inspection-schema-refused")
        guardian.typed_server(inspection["server"]); guardian.typed_observation(inspection["observation"])
        require(type(inspection["serverZeroObserved"]) is bool and type(inspection["nativeDisconnectedObserved"]) is bool and
            inspection["serverZeroObserved"] == (inspection["server"]["clientCount"] == 0) and inspection["nativeDisconnectedObserved"] == (inspection["observation"]["nativeState"] == "disconnected"), "inspection-type-refused")
    return value


def inspect_after(guardian, lab, inspect):
    server = guardian.typed_server(lab.native_clients())
    facts = guardian.typed_observation(inspect())
    return {"server": server, "observation": facts,
            "serverZeroObserved": server["clientCount"] == 0,
            "nativeDisconnectedObserved": facts["nativeState"] == "disconnected"}


def run_owned(args):
    require(args.run_owned_lab and SESSION.fullmatch(args.session or "") and SHA.fullmatch(args.expected_server_fingerprint or ""), "explicit-owned-target-required")
    require(args.expire_current_session != args.inspect_existing_stimulus, "explicit-single-mode-required")
    proof = stock_api_proof(); guardian = guardian_module(); base = guardian.base_module()
    directory = ROOT / "build/vpn-lab/persistent-acceptance" / args.session
    guardian.owned_file(directory, directory=True); guardian.owned_file(directory / "state.json")
    lease = os.open(directory / "guardian.lock", os.O_RDWR | os.O_NOFOLLOW)
    try:
        guardian.owned_file(directory / "guardian.lock")
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = guardian.bounded_json((directory / "state.json").read_bytes(), 131072)
        require(state.get("session") == args.session and state.get("pending") is None and state.get("launchNativeBaseline") is None and
                state.get("lastCheckpoint") is not None and state.get("lastConnectedServer") == args.expected_server_fingerprint and
                type(state.get("lastNonce")) is str and SHA.fullmatch(state["lastNonce"]), "session-baseline-refused")
        history = healthy_history(guardian, directory, args, state)
        lab, guest = guardian.runtime(base)
        require(lab.manifest["run"] == RUN and lab.manifest.get("ocservRelease") == "1.4.2" and
                lab.manifest.get("ocservArchiveSHA256") == ARCHIVE_SHA, "stock-server-refused")
        server = lab.own(lab.manifest["server"])
        container = server.get("Id")
        require(type(container) is str and SHA.fullmatch(container) and server.get("Image") == lab.manifest["imageId"] and
                server.get("State", {}).get("Running") is True, "stock-server-refused")
        def inspect():
            code = guardian.remote_code(base, args.session, state["release"], state["build"], "\ndef action():return inspect()\nexecute(action)\n")
            return guardian.rpc(guest, code)
        journals = directory / "expiry-stimuli"
        journals.mkdir(mode=0o700, exist_ok=True); guardian.owned_file(journals, directory=True)
        path = journals / (args.expected_server_fingerprint + ".json")
        if path.exists() or path.is_symlink():
            guardian.owned_file(path)
            journal = typed_journal(guardian, guardian.bounded_json(path.read_bytes()))
            require(journal.get("originalServerFingerprint") == args.expected_server_fingerprint and
                    journal.get("candidateBinarySHA256") == state["build"]["binarySHA256"] and journal.get("run") == RUN,
                    "existing-intent-binding-refused")
            # Even repeating the --expire flag only inspects a durable intent.
            require(journal.get("phase") != "prepared", "prepared-intent-refused")
            journal["inspection"] = inspect_after(guardian, lab, inspect)
        else:
            require(args.expire_current_session, "existing-intent-required")
            baseline_server = guardian.typed_server(lab.native_clients())
            require(baseline_server["clientCount"] == 1 and baseline_server["sessionFingerprint"] == args.expected_server_fingerprint,
                    "server-fingerprint-changed")
            baseline = before_ready(guardian, inspect(), state["lastCheckpoint"], history)
            nonce_code = guardian.remote_code(base, args.session, state["release"], state["build"], base.nonce_action(RUN))
            nonce = guardian.typed_nonce(guardian.rpc(guest, nonce_code), state["lastNonce"])
            # Use the already loaded stock Lab module's Docker executable. No
            # host Cisco/network command, new runtime or server restart exists.
            docker = type(lab).native_clients.__globals__["DOCKER"]
            require(type(docker) is str and Path(docker).is_absolute(), "docker-runtime-refused")
            identifier = select_unique_id(read_users(docker, container), args.expected_server_fingerprint)
            final_server = guardian.typed_server(lab.native_clients())
            require(final_server == baseline_server and lab.own(lab.manifest["server"])["Id"] == container, "server-fingerprint-changed")
            before_ready(guardian, inspect(), baseline, history)
            journal = {"schema": 1, "run": RUN, "phase": "prepared", "operation": "terminateUniqueConnectionAndRequestCookieInvalidation",
                "originalServerFingerprint": args.expected_server_fingerprint, "candidateBinarySHA256": state["build"]["binarySHA256"],
                "baseline": baseline, "beforeNonce": nonce, "mutationRequests": 0, "stockAPI": proof,
                "mainActions": 0, "rawOutputPersisted": False, "cookieInvalidationProven": False, "actualReconnectProven": False}
            if not baseline["confirmed"]:
                require(baseline_server == history["auth"]["server"], "healthy-history-server-refused")
                guardian.typed_nonce(nonce, history["auth"]["nonce"]["challengeFingerprint"])
                if history["resume"] is not None: guardian.typed_nonce(nonce, history["resume"]["nonce"]["challengeFingerprint"])
                journal["healthyHistory"] = dict(authReceiptSHA256=history["authSHA256"], resumeReceiptSHA256=history["resumeSHA256"])
            guardian.atomic(path, journal)
            dispatch_once(journal, lambda value: guardian.atomic(path, value), fixed_command(docker, container, identifier),
                lambda command: subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode)
            deadline = time.monotonic() + 5
            while True:
                observation = inspect_after(guardian, lab, inspect)
                journal["inspection"] = observation; guardian.atomic(path, journal)
                if observation["serverZeroObserved"] and observation["nativeDisconnectedObserved"]:
                    break
                if time.monotonic() >= deadline:
                    break
                time.sleep(.1)
        typed_journal(guardian, journal); guardian.atomic(path, journal)
        observed = journal.get("inspection", {})
        result = "stimulus-observed" if observed.get("serverZeroObserved") is True and observed.get("nativeDisconnectedObserved") is True else "observation-incomplete"
        print(json.dumps({"result": result, "receipt": str(path), "receiptSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "actualReconnectProven": False}))
        return 0 if result == "stimulus-observed" else 1
    finally:
        fcntl.flock(lease, fcntl.LOCK_UN); os.close(lease)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-owned-lab", action="store_true")
    parser.add_argument("--expire-current-session", action="store_true")
    parser.add_argument("--inspect-existing-stimulus", action="store_true")
    parser.add_argument("--session")
    parser.add_argument("--expected-server-fingerprint")
    parser.add_argument("--auth-receipt")
    parser.add_argument("--auth-receipt-sha256")
    parser.add_argument("--resume-receipt")
    parser.add_argument("--resume-receipt-sha256")
    args = parser.parse_args()
    if not args.run_owned_lab:
        print(json.dumps({"result": "prepared-only", "stockAPI": stock_api_proof(), "guestCommands": 0, "serverCommands": 0}))
        return 0
    try:
        return run_owned(args)
    except Refused as error:
        print(json.dumps({"result": "refused-or-unresolved", "reason": str(error), "repeatMutationAllowed": False}))
        return 1
    except Exception:
        print(json.dumps({"result": "refused-or-unresolved", "reason": "bounded-stimulus-refusal", "repeatMutationAllowed": False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
