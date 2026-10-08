"""Read-only, bounded lid test; creates NO power assertions or preferences.

Run while MacBeat owns the session, then close the lid for two minutes.
macOS continuous time includes sleep; absolute time excludes sleep. Record
both so a wake cannot hide a sleep behind a resumed heartbeat.
"""
import argparse
import ctypes
import datetime
import json
import pathlib
import plistlib
import subprocess
import time


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=int, default=600)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
if not 1 <= args.seconds <= 1800:
    parser.error('--seconds must be between 1 and 1800')

lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
lib.mach_continuous_time.restype = ctypes.c_uint64
lib.mach_absolute_time.restype = ctypes.c_uint64
base = Timebase()
lib.mach_timebase_info(ctypes.byref(base))
scale = base.numer / base.denom / 1e9

# Inspect session state without requesting lock, display sleep, or power holds.
cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
cf.CFDictionaryGetValue.restype = ctypes.c_void_p
cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
cf.CFGetTypeID.restype = ctypes.c_ulong
cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
cf.CFBooleanGetValue.restype = ctypes.c_bool
cf.CFRelease.argtypes = [ctypes.c_void_p]
lock_key = cf.CFStringCreateWithCString(None, b'CGSSessionScreenIsLocked', 0x08000100)


def locked():
    session = cg.CGSessionCopyCurrentDictionary()
    if not session:
        return None
    try:
        value = cf.CFDictionaryGetValue(session, lock_key)
        if not value:
            return False
        if cf.CFGetTypeID(value) != cf.CFBooleanGetTypeID():
            return None
        return cf.CFBooleanGetValue(value)
    finally:
        cf.CFRelease(session)


def clocks():
    return lib.mach_continuous_time() * scale, lib.mach_absolute_time() * scale


args.output.parent.mkdir(parents=True, exist_ok=True)
start, awake_start = clocks()
previous = start
with args.output.open('x', buffering=1) as log:
    print('Observer ready:', args.output, flush=True)
    while True:
        continuous, awake = clocks()
        record = dict(time=datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
                      screenLocked=locked(),
                      elapsed=round(continuous-start, 3),
                      gap=round(continuous-previous, 3),
                      sleepSeconds=round(max(0, (continuous-start)-(awake-awake_start)), 3))
        try:
            raw = subprocess.check_output(
                ['/usr/sbin/ioreg', '-a', '-r', '-n', 'IOPMrootDomain', '-d', '1'], timeout=3)
            properties = plistlib.loads(raw)[0]
            record['lidClosed'] = properties.get('AppleClamshellState')
        except (subprocess.SubprocessError, ValueError, IndexError) as error:
            record['error'] = str(error)
        log.write(json.dumps(record) + '\n')
        previous = continuous
        if continuous-start >= args.seconds:
            break
        time.sleep(1)
    print('Observer finished. Review lid samples and sleepSeconds before declaring success.', flush=True)
