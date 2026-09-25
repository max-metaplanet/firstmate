# CI lint memory ceiling

A CI lint partition was killed by the runner's OOM killer (exit 143, no findings printed) whenever the byte-weight packing gave it two expensive shards.
This record holds the measurements that identify why, and why `bin/fm-lint.sh` bounds concurrency rather than how roots are grouped.

Measured 2026-09-25 against the tree at commit `65fc15d96c28324d03bdb1d37f8a32da8f6dcdab` with the repository-pinned ShellCheck 0.11.0, full extended analysis, and `--external-sources`.
That build reports GHC 9.8.2 with the vanilla, non-threaded RTS.

## Peak memory is opportunistic, not a fixed per-root cost

ShellCheck sizes its heap to the memory it can see, so the same root has no single peak figure.
Running `bin/fm-watch.sh` on Linux x86_64 under different container memory limits:

| Limit | ShellCheck exit | Wall | Peak RSS |
| --- | --- | ---: | ---: |
| 3 GiB | 137 (OOM-killed) | 118s | 3.00 GiB |
| 5 GiB | 0 | 64s | 5.00 GiB |
| 7 GiB | 0 | 59s | 5.72 GiB |
| 16 GB runner | 0 | - | about 11.6 GiB |

It expands to fill what is available and trades memory for speed, down to a floor between 3 and 5 GiB for this root.

This is why grouping cannot bound the peak.
Splitting a shard's roots into one ShellCheck process per root moved the runner's reported peak by 0.009% (12,128,056 to 12,126,940 KiB on partition 1), because each process still expanded into the same free memory.
Partition count and shard packing have the same non-effect for the same reason.

Two workers sharing a runner both expand toward the whole machine, which is the collision.
One worker expands into that same runner safely, so `bin/fm-lint.sh` runs a single ShellCheck per CI partition and uses partition count to bound wall time.

## A GHC heap cap is not available

Capping the heap per process would bound each worker without changing concurrency, but this binary refuses it.
`GHCRTS` does reach the program, since `GHCRTS=--info shellcheck --norc -- <path>` prints the RTS table.
Both `GHCRTS=-M6g` and `shellcheck --norc +RTS -M6g -RTS` fail with:

```text
shellcheck: Most RTS options are disabled. Link with -rtsopts to enable them.
```

Re-test this after a ShellCheck upgrade.
A build linked with `-rtsopts`, or one shipping a larger permitted option subset, would make a per-process cap the smaller fix.

## Reproduction

Install the pinned binary with `bin/fm-install-shellcheck.sh` and run the limit sweep on Linux x86_64, which is what `ubuntu-latest` provides.

```bash
set -eu
for limit in 3g 5g 7g; do
  docker run --rm --platform linux/amd64 -m "$limit" -v "$PWD":/w -w /w ubuntu:24.04 \
    bash -c 'apt-get update -qq >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl xz-utils time >/dev/null 2>&1
      bin/fm-install-shellcheck.sh /usr/local/bin >/dev/null
      /usr/bin/time -f "%e %M" -o /tmp/t \
        shellcheck --norc --external-sources -- bin/fm-watch.sh >/dev/null 2>&1
      echo "rc=$? $(cat /tmp/t)"'
done
```

`/usr/bin/time -f '%M'` reports kibibytes, and for a process with children it reports the largest single child rather than their sum.
Peak RSS moves with the ShellCheck version, with each root's source graph, and with the memory the host makes available, so re-run the sweep after a version bump rather than quoting these figures forward.
