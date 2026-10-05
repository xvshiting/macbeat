"""Process recovery smoke check. Never starts a power session."""
import subprocess
import json
import time
import pathlib

agent = str(pathlib.Path(__file__).resolve().parents[1] / 'dist/MacBeat.app/Contents/Helpers/MacBeatAgent')
journal = pathlib.Path.home() / 'Library/Application Support/MacBeat/clamshell-recovery.json'
assert not journal.exists(), 'Existing recovery requires attention; skipping process-only check'
for mode in ['eof', 'killed']:
    process = subprocess.Popen([agent], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    ready = json.loads(process.stdout.readline())
    assert ready['kind'] == 'ready', ready
    if mode == 'eof':
        process.stdin.close()
        events = [json.loads(line) for line in process.stdout]
        assert any(event['kind'] == 'stopped' for event in events), events
    else:
        process.kill()
        process.stdin.close()
    process.wait(timeout=5)
    time.sleep(.25)
    probe = subprocess.run([agent, '--recover'], capture_output=True, text=True, timeout=5)
    assert probe.returncode == 0, probe.stdout
    assert not journal.exists()
    print('PASS:', mode, 'before session; monitor released lock; no power mutation')
