#!/usr/bin/env python3
"""Leader-only quota normalization and selection, called by fm-seat.sh.

`evidence PROVIDER MODEL HORIZON MINIMUM` reads one default TOON (or its one
permitted JSON fallback) from stdin and emits normalized evidence. `select`
reads candidate JSON lines, prints every candidate's evidence on stderr, then
prints PROVIDER SEAT for the unique highest known spendPriority. Exit 1 means
uncertainty, no feasible destination, or a tie. No worker policy lives here.
"""
import csv
import json
import math
import re
import sys


def number(value):
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def applicable(scope, model):
    return scope in ("all_models", "all_products", "model:" + model, "product:" + model)


def toon_blocks(text):
    blocks = {}
    lines = text.splitlines()
    for i, line in enumerate(lines):
        match = re.fullmatch(r"(quota|exhaustion|attention)\[(\d+)\](?:\{([^}]+)\})?:", line)
        if not match:
            continue
        name, count, fields = match.groups()
        if name in blocks:
            raise ValueError("duplicate TOON block")
        count = int(count)
        rows = []
        if count and not fields:
            raise ValueError("missing TOON fields")
        for data in lines[i + 1:i + 1 + count]:
            if not data.startswith("  "):
                raise ValueError("invalid TOON row")
            values = next(csv.reader([data.strip()]))
            if len(values) != len(fields.split(",")):
                raise ValueError("invalid TOON columns")
            rows.append(dict(zip(fields.split(","), values)))
        if len(rows) != count:
            raise ValueError("truncated TOON block")
        blocks[name] = rows
    if "quota" not in blocks:
        raise ValueError("missing TOON quota")
    return blocks


def account_rows(rows, provider):
    rows = [r for r in rows if r.get("provider") == provider]
    if any("accountKey" in r for r in rows):
        lane = "codex-home" if provider == "codex" else "default"
        preferred = [r for r in rows if r.get("accountKey") == lane]
        rows = preferred or [r for r in rows if r.get("accountKey") == "default"]
    return rows


def evidence(text, provider, model, horizon, minimum):
    auth = "unknown (no selected credential evidence)"
    if text.lstrip().startswith("{"):
        snapshot = json.loads(text)
        if snapshot.get("schemaVersion") not in (5, 6):
            raise ValueError("unsupported quota JSON schema")
        if snapshot["schemaVersion"] == 6 and any(
                not isinstance(r.get("accountKey"), str) or not r["accountKey"]
                for r in snapshot.get("providers", [])):
            raise ValueError("schema 6 account key missing")
        providers = account_rows(snapshot.get("providers", []), provider)
        if len(providers) > 1:
            raise ValueError("duplicate account rows")
        row = providers[0] if providers else {}
        auth = row.get("state", {}).get("authStatus") or row.get("source", "unknown")
        rows = []
        for item in row.get("quotaSemantics", {}).get("effectiveAvailability", []):
            runway = item.get("runway", {})
            rows.append(dict(item, spendPriority=item.get("selection", {}).get("spendPriority"),
                             runway=runway.get("status", "unknown"),
                             usableRunwaySeconds=runway.get("usableRunwaySeconds")))
        state = row.get("state", {})
        attention = (state.get("stale") is True or
                     state.get("status", row.get("status")) in ("auth_required", "stale", "unavailable", "rate_limited") or
                     auth in ("credentials_invalid", "credentials_missing", "unavailable"))
    else:
        blocks = toon_blocks(text)
        rows = account_rows(blocks["quota"], provider)
        exhaustion = account_rows(blocks.get("exhaustion", []), provider)
        attention = [r for r in account_rows(blocks.get("attention", []), provider)
                     if not r.get("scope") or applicable(r.get("scope"), model)]
        for row in rows:
            matches = [e for e in exhaustion if e.get("scope") == row.get("scope")]
            row["usableRunwaySeconds"] = matches[0].get("usableRunwaySeconds") if len(matches) == 1 else None
        if rows and not attention:
            auth = "quota read on selected profile; no auth attention"
    rows = [r for r in rows if applicable(r.get("scope"), model)]
    if not rows:
        return dict(spendPriority=None, runway="unknown", auth=auth, feasible=False,
                    fallback=True, reason="no applicable account/model quota")
    remaining = [number(r.get("effectivePercentRemaining")) for r in rows]
    # Every applicable scope is a bound. Compare the producer's scalar directly;
    # a percentage must never choose which economic ranker gets to constrain us.
    priorities = [number(r.get("spendPriority")) for r in rows]
    priority = min(priorities) if all(p is not None for p in priorities) else None
    failures = []
    uncertain = bool(attention)
    for row, left in zip(rows, remaining):
        runway = row.get("runway", "unknown")
        seconds = number(row.get("usableRunwaySeconds"))
        if runway == "exhausted_now" or (left is not None and left <= 0):
            failures.append("exhausted quota")
        elif runway == "projected_exhaustion" and seconds is not None:
            if seconds < horizon:
                failures.append(f"runway {seconds:g}s below {horizon}s successor-start horizon")
        elif runway != "through_reset":
            uncertain = True
        if minimum is not None and left is not None and left <= minimum:
            failures.append(f"remaining {left:g}% at/below configured destination minimum {minimum:g}%")
        if left is None or not 0 <= left <= 100 or row.get("status", "known") != "known":
            uncertain = True
    if priority is None:
        uncertain = True
    if uncertain:
        failures.append("quota, authentication, spendPriority, or runway remains uncertain")
    return dict(spendPriority=priority, runway=", ".join(
        f"{r.get('scope')}:{r.get('runway')}:{r.get('usableRunwaySeconds', 'unknown')}" for r in rows),
        auth=auth, feasible=not failures, fallback=uncertain,
        reason="; ".join(failures) or f"feasible for {horizon}s successor-start horizon")


def select(candidates):
    eligible = []
    for candidate in candidates:
        evidence = candidate.get("evidence", {})
        priority = evidence.get("spendPriority")
        print(f"leader candidate {candidate['provider']}:{candidate['seat']} "
              f"model={candidate['model']} class=strongest-native "
              f"catalog={candidate['catalog']} surface={candidate['profile']} "
              f"auth={evidence.get('auth', 'unknown')} spendPriority={priority if priority is not None else 'unknown'} "
              f"runway={evidence.get('runway', 'unknown')} "
              f"{candidate.get('reason') or evidence.get('reason', 'no quota read')}", file=sys.stderr)
        if not candidate.get("reason") and evidence.get("feasible") and priority is not None:
            eligible.append(candidate)
    if any(c.get("reason", "").startswith("configuration error:") for c in candidates):
        print("leader selection held: duplicate credential profiles in configuration", file=sys.stderr)
        return 1
    if any(c.get("reason") == "selection read deadline exhausted" for c in candidates):
        print("leader selection held: read deadline exhausted before every candidate was considered", file=sys.stderr)
        return 1
    if not eligible:
        print("leader selection held: no candidate with provable runway and known spendPriority", file=sys.stderr)
        return 1
    best = max(c["evidence"]["spendPriority"] for c in eligible)
    winners = [c for c in eligible if c["evidence"]["spendPriority"] == best]
    if len(winners) != 1:
        print("leader selection held: tied spendPriority; " + ", ".join(
            c["provider"] + ":" + c["seat"] for c in winners), file=sys.stderr)
        return 1
    print(winners[0]["provider"], winners[0]["seat"])
    return 0


if __name__ == "__main__":
    try:
        if sys.argv[1] == "evidence":
            print(json.dumps(evidence(sys.stdin.read(), sys.argv[2], sys.argv[3],
                                      int(sys.argv[4]), number(sys.argv[5]))))
        elif sys.argv[1] == "select":
            sys.exit(select([json.loads(line) for line in sys.stdin if line.strip()]))
        else:
            raise ValueError("unknown command")
    except (ValueError, KeyError, IndexError, TypeError) as error:
        print("leader quota evidence unavailable: " + str(error), file=sys.stderr)
        sys.exit(1)
