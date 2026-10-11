"""Exercise the real 200-MB budget in a disposable directory and measure app RSS.

Runs self-tests only; never changes the installed app, power settings or Cisco session.
"""
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
app = Path(os.environ.get("NOSLEEP_APP", repo / "build/NoSleep.app")).resolve()
exe = app / "Contents/MacOS/NoSleep"
evidence = repo / ".taskflow/log-budget"
evidence.mkdir(parents=True, exist_ok=True)
log = evidence / "large-budget.log"
samples = []
started = time.monotonic()
with log.open("w") as output:
    process = subprocess.Popen([str(exe), "--self-test"],
                               env={**os.environ, "NOSLEEP_TEST_LARGE_LOGS": "1"},
                               stdout=output, stderr=subprocess.STDOUT)
    try:
        while process.poll() is None:
            rss = subprocess.run(["/bin/ps", "-p", str(process.pid), "-o", "rss="],
                                 text=True, capture_output=True, check=False).stdout.strip()
            if rss:
                samples.append(int(rss))
            if time.monotonic() - started > 180:
                raise AssertionError("Large-log exercise exceeded its time budget")
            time.sleep(.1)
        assert process.returncode == 0, log.read_text()[-5000:]
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
text = log.read_text()
assert "PASS: seeded exact 200,000,000 bytes" in text
assert "PASS: 200-MB contract, chunk/record bounds" in text
assert samples and max(samples) < 128 * 1024, "Process RSS grew toward the complete log size"
receipt = {"result": "passed", "scenario": "real 200-MB journal rotation and streaming export",
           "environment": "local", "appHash": hashlib.sha256(exe.read_bytes()).hexdigest(),
           "logBudgetBytes": 200_000_000, "segmentBudgetBytes": 50_000_000,
           "rssKiBRange": [min(samples), max(samples)], "rssCeilingKiB": 128 * 1024,
           "seconds": round(time.monotonic() - started, 2), "log": str(log)}
(evidence / "large-budget.json").write_text(json.dumps(receipt, indent=2))
print(f"PASS: exact 200-MB fixture, oldest rotation, streamed export, cleanup; peak RSS {max(samples)/1024:.1f} MiB")
