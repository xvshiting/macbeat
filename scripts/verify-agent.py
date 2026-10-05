"""Bounded integration checks. The clamshell request is opt-in via --clamshell.
Runs no pmset mutations and does not claim a physical lid-close test.
"""
import argparse
import json
import pathlib
import selectors
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--clamshell', action='store_true')
args = parser.parse_args()
agent = pathlib.Path(__file__).resolve().parents[1] / 'dist/MacBeat.app/Contents/Helpers/MacBeatAgent'
snapshot = json.loads(subprocess.check_output([str(agent), '--inspect']))
print('snapshot:', json.dumps(snapshot, ensure_ascii=False))
if snapshot.get('power', {}).get('lidClosed') is not False:
    raise SystemExit('Open the laptop lid before running power mutation checks.')

def run_case(name, close_input=False, clamshell=False):
    process = subprocess.Popen([str(agent)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    plan = dict(mode='duration', duration=3, deadline=time.time()-978307200+3600,
                powerOnly=False, batteryThreshold=20, requestClamshell=clamshell)
    events = []
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        process.stdin.write(json.dumps(dict(action='start', plan=plan))+'\n')
        process.stdin.flush()
        start = time.monotonic()
        closed = False
        while time.monotonic()-start < 8:
            if selector.select(.25):
                line = process.stdout.readline()
                if not line:
                    break
                event = json.loads(line)
                events.append(event)
                if close_input and event['kind']=='running' and not closed:
                    process.stdin.close()
                    closed = True
            if process.poll() is not None:
                events.extend(json.loads(line) for line in process.stdout if line.strip())
                break
        process.wait(timeout=3)
        errors = [e for e in events if e['kind'] in ('error','recoveryError')]
        running = any(e['kind']=='running' for e in events)
        stopped = any(e['kind']=='stopped' for e in events)
        print(name, json.dumps(dict(running=running, stopped=stopped, errors=errors,
              last=events[-1] if events else None), ensure_ascii=False))
        if errors:
            raise RuntimeError(f'{name}: agent rejected the request')
        assert running and stopped and process.returncode == 0
    finally:
        selector.close()
        if process.poll() is None:
            if not process.stdin.closed:
                process.stdin.write('{"action":"stop"}\n'); process.stdin.flush()
            process.wait(timeout=5)

run_case('deadline')
run_case('client-pipe-closed', close_input=True)
if args.clamshell:
    run_case('native-clamshell-request-and-restore', clamshell=True)
journal = pathlib.Path.home() / 'Library/Application Support/MacBeat/clamshell-recovery.json'
assert not journal.exists(), 'Recovery journal remains: recovery required'
assert 'MacBeat active session' not in subprocess.check_output(['/usr/bin/pmset','-g','assertions'],text=True)
print('PASS: no MacBeat assertion or recovery journal remains')
