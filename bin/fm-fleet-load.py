#!/usr/bin/env python3
"""Fleet-library policy evaluator. Called under its lock for refresh only.

No lifecycle operations. Config/command/state contract: fm-fleet-capacity-lib.sh.
Native read commands each have a two-second deadline. Fixture-only telemetry
and clock files are selected by FM_FLEET_LOAD_TELEMETRY / FM_FLEET_LOAD_CLOCK.
"""
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time

VERSION = 1


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def run(*args):
    return subprocess.check_output(args, timeout=2, stderr=subprocess.DEVNULL, text=True).strip()


def number(value, minimum=0):
    if type(value) not in (int, float) or not math.isfinite(value) or value < minimum:
        raise ValueError("invalid numeric telemetry")
    return value


def clock():
    if os.environ.get("FM_FLEET_LOAD_CLOCK"):
        value = read_json(os.environ["FM_FLEET_LOAD_CLOCK"])
        return number(value["epoch"]), number(value["monotonic"]), str(value["boot"])
    boot = run("sysctl", "-n", "kern.boottime") if platform.system() == "Darwin" else "unsupported"
    return time.time(), time.monotonic(), boot


def telemetry():
    if os.environ.get("FM_FLEET_LOAD_TELEMETRY"):
        value = read_json(os.environ["FM_FLEET_LOAD_TELEMETRY"])
    else:
        if platform.system() != "Darwin":
            raise ValueError("unsupported platform: policy requires macOS")
        wake_lib = str(Path(__file__).with_name("fm-wake-lib.sh"))
        loads = run("bash", "-c", '. "$1"; fm_machine_load_sample', "fleet-load", wake_lib).split()
        pressure = run("sysctl", "-n", "kern.memorystatus_vm_pressure_level")
        # XNU's sysctl converts its internal enum to dispatch flags: 1/2/4.
        # bsd/kern/kern_memorystatus_notify.c, sysctl_memorystatus_vm_pressure_level.
        pressure = {"1": "normal", "2": "warning", "4": "critical"}.get(pressure)
        vm = run("vm_stat")
        page_size = int(re.search(r"page size of (\d+) bytes", vm)[1])
        def pages(name):
            return int(re.search(r"^" + name + r":\s+(\d+)\.", vm, re.M)[1])
        swap = run("sysctl", "-n", "vm.swapusage")
        used = re.search(r"used\s*=\s*([0-9.]+)([KMG])", swap)
        value = dict(load1=float(loads[0]), load5=float(loads[1]), cpus=int(loads[2]),
                     load1_centi=int(loads[3]), load5_centi=int(loads[4]), pressure=pressure,
                     page_size=page_size, swapouts=pages("Swapouts"), swapins=pages("Swapins"),
                     swap_used_bytes=float(used[1]) * {"K": 1024, "M": 1024**2, "G": 1024**3}[used[2]])
    for key in ("load1", "load5", "load1_centi", "load5_centi", "swapouts", "swapins", "swap_used_bytes"):
        number(value[key])
    for key in ("cpus", "page_size"):
        number(value[key], 1)
    if value["pressure"] not in ("normal", "warning", "urgent", "critical"):
        raise ValueError("unrecognized memory pressure")
    return value


def policy(config, static):
    path = config / "fleet-load-policy"
    if not path.exists() and not path.is_symlink():
        return {"mode": "off"}
    raw = path.read_text().strip()
    if raw == "off":
        return {"mode": "off"}
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get("mode") not in ("off", "observe", "enforce"):
        raise ValueError("policy mode must be off, observe or enforce")
    if value["mode"] == "off":
        return {"mode": "off"}
    if set(value) != {"mode", "floor", "ceiling", "start"}:
        raise ValueError("policy requires only mode, floor, ceiling and start")
    for key in ("floor", "ceiling", "start"):
        if type(value[key]) is not int or not 1 <= value[key] <= 999999:
            raise ValueError("policy limits must be positive integers of at most six digits")
    if not value["floor"] <= value["start"] <= value["ceiling"]:
        raise ValueError("policy requires floor <= start <= ceiling")
    if static is None:
        raise ValueError("enabled policy requires config/fleet-capacity")
    return value


def atomic_write(path, value):
    fd, stage = tempfile.mkstemp(prefix=".fleet-load-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True, allow_nan=False)
            stream.write("\n")
        os.replace(stage, path)
    finally:
        if os.path.exists(stage):
            os.unlink(stage)


def reduce_sample(old, sample, now, mono, boot, identity, floor, ceiling, start):
    same = bool(old and old.get("sample_valid") and old["identity"] == identity and old["boot"] == boot
                and now >= old["sample_epoch"] and mono >= old["sample_monotonic"])
    elapsed = mono - old["sample_monotonic"] if same else 0
    consecutive = same and 60 <= elapsed <= 90
    state = dict(version=VERSION, identity=identity, boot=boot, sample_epoch=now,
                 sample_monotonic=mono, signals=sample, target=min(old["target"] if same else start, ceiling),
                 healthy=0, cpu_streak=0, memory_streak=0, swap_streak=0, normal_streak=0,
                 critical_hold=bool(same and old["critical_hold"]), reason="sample baseline",
                 last_adjustment=old["last_adjustment"] if same else now, sensor_error="", sample_valid=True)
    rate = None
    in_rate = None
    if same and elapsed > 0 and sample["page_size"] == old["signals"]["page_size"]:
        previous = old["signals"]
        if sample["swapouts"] >= previous["swapouts"] and sample["swapins"] >= previous["swapins"]:
            rate = (sample["swapouts"] - previous["swapouts"]) * sample["page_size"] / elapsed
            in_rate = (sample["swapins"] - previous["swapins"]) * sample["page_size"] / elapsed
    state.update(swap_out_bytes_per_second=rate, swap_in_bytes_per_second=in_rate,
                 swap_used_delta_bytes=sample["swap_used_bytes"] - old["signals"]["swap_used_bytes"] if same else None)
    def streak(key, condition):
        return (old[key] if consecutive else 0) + 1 if condition else 0
    state["cpu_streak"] = streak("cpu_streak", sample["load1_centi"] >= 120 and sample["load5_centi"] >= 110)
    state["memory_streak"] = streak("memory_streak", sample["pressure"] in ("warning", "urgent"))
    state["swap_streak"] = streak("swap_streak", consecutive and rate is not None and rate > 16 * 1024**2)
    state["normal_streak"] = streak("normal_streak", sample["pressure"] == "normal")
    if sample["pressure"] == "critical":
        state.update(target=min(state["target"], floor), critical_hold=True, reason="critical memory pressure")
    elif state["critical_hold"]:
        state["reason"] = "critical hold: requires two consecutive normal-pressure samples"
        if state["normal_streak"] >= 2:
            state.update(critical_hold=False, reason="critical pressure cleared")
    else:
        reasons = []
        # First CPU decline needs three minutes; subsequent steps need two more.
        cpu_threshold = 2 if same and old.get("cpu_reduced", False) else 3
        if state["cpu_streak"] >= cpu_threshold:
            reasons.append("sustained CPU load")
        if state["memory_streak"] >= 2:
            reasons.append("memory pressure")
        if state["swap_streak"] >= 2:
            reasons.append("swap-out churn")
        healthy = (consecutive and rate is not None and rate < 1024**2
                   and sample["load1_centi"] < 80 and sample["load5_centi"] < 90
                   and sample["pressure"] == "normal" and not old["critical_hold"])
        state["healthy"] = streak("healthy", healthy)
        state["cpu_reduced"] = bool(same and consecutive and old.get("cpu_reduced") and state["cpu_streak"])
        if reasons:
            state.update(target=min(state["target"], max(floor, state["target"] - 1)), reason=", ".join(reasons),
                         cpu_reduced=state["cpu_streak"] >= cpu_threshold,
                         cpu_streak=0, memory_streak=0, swap_streak=0, healthy=0)
        elif state["healthy"] >= 10:
            state.update(target=min(ceiling, state["target"] + 1), healthy=0, reason="ten healthy minutes")
        elif state["target"] < ceiling:
            state["reason"] = "waiting for ten healthy minutes"
        else:
            state["reason"] = "at policy ceiling"
    state["target"] = min(ceiling, state["target"])
    if not same or state["target"] != old["target"]:
        state["last_adjustment"] = now
    return state


def evaluate(root, config, static, refresh):
    result = dict(mode="off", configured=static, effective=static, desired=static, hold="",
                  reason="static capacity; adaptation off", sample_age_seconds=None)
    try:
        p = policy(config, static)
    except (OSError, ValueError, TypeError) as error:
        result.update(mode="invalid", hold="invalid policy", reason=str(error))
        return result
    result["mode"] = p["mode"]
    if p["mode"] == "off":
        return result
    result.update(floor=min(p["floor"], static), ceiling=min(p["ceiling"], static),
                  start=min(p["start"], static))
    path = root / "state" / "fleet-load.json"
    identity = json.dumps(p, sort_keys=True)
    state = None
    try:
        now, mono, boot = clock()
        if path.exists():
            state = read_json(path)
            if type(state["version"]) is not int or state["version"] != VERSION:
                raise ValueError("incompatible fleet-load state; remove it to restart observation")
            # Validate persisted state before either projection or reduction.
            if type(state["target"]) is not int or not 1 <= state["target"] <= 999999:
                raise ValueError("invalid fleet-load target")
            number(state["sample_epoch"])
            number(state["sample_monotonic"])
        same = bool(state and state.get("sample_valid") and state["identity"] == identity and state["boot"] == boot
                    and now >= state["sample_epoch"] and mono >= state["sample_monotonic"])
        if refresh and same and state["target"] > result["ceiling"]:
            # Persist manual reductions even within an already sampled minute.
            # Raising the manual cap later must earn every slot back normally.
            state.update(target=result["ceiling"], last_adjustment=now, reason="manual fleet-capacity clamp")
            atomic_write(path, state)
        attempted_recently = bool(state and state.get("attempt_boot") == boot
                                  and state.get("identity") == identity
                                  and 0 <= mono - state.get("attempt_monotonic", -60) < 60)
        if refresh and not attempted_recently:
            try:
                sample = telemetry()
                state = reduce_sample(state, sample, now, mono, boot, identity,
                                      result["floor"], result["ceiling"], result["start"])
                same = True
            except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError) as error:
                current = state and state.get("identity") == identity and state.get("boot") == boot
                state = dict(state if current else dict(version=VERSION, identity=identity, boot=boot,
                                                        sample_epoch=0, sample_monotonic=0, target=result["start"],
                                                        sample_valid=False), sensor_error="required telemetry unreadable: " + str(error),
                             healthy=0, cpu_streak=0, memory_streak=0, swap_streak=0, normal_streak=0,
                             attempt_monotonic=mono, attempt_boot=boot)
            state.update(attempt_monotonic=mono, attempt_boot=boot)
            atomic_write(path, state)
        age = now - state["sample_epoch"] if same else None
        desired = min(state["target"], result["ceiling"]) if state and "target" in state else result["start"]
        hold = ""
        if not same:
            hold = (state.get("sensor_error") if state else "") or "sensor has no valid sample for current policy/boot"
        elif age > 180 or mono - state["sample_monotonic"] > 180:
            hold = "stale sensor (older than 180 seconds)"
        if state and state.get("sensor_error"):
            hold = hold or state["sensor_error"]
        if state and state.get("critical_hold"):
            hold = hold or "critical memory pressure hold"
        result.update(desired=desired, effective=desired if p["mode"] == "enforce" else static,
                      hold=hold, reason=state.get("reason", hold) if state else hold,
                      sample_age_seconds=age, state=state,
                      next_condition="two normal samples clear critical hold; ten healthy minutes add one slot")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result.update(hold="sensor/state unreadable", reason=str(error))
    return result


if __name__ == "__main__":
    root, config, static, action = sys.argv[1:]
    result = evaluate(Path(root), Path(config), int(static) if static else None, action == "refresh")
    # Bash owns durable wake publication. The fingerprint also suppresses
    # repeated stale/critical wakes after the previous queue entry was drained.
    if action == "refresh" and result["mode"] != "off":
        fingerprint = json.dumps([result["mode"], result["effective"], result["desired"], result["hold"]], separators=(",", ":"))
        notice = Path(root) / "state" / ".fleet-load-notice"
        try:
            previous = notice.read_text() if notice.exists() else ""
        except OSError:
            previous = ""
        result["transition"] = fingerprint != previous
        result["notice_fingerprint"] = fingerprint
    print(json.dumps(result, allow_nan=False))
