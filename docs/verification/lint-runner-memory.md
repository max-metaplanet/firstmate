# CI lint memory ceiling

`bin/fm-lint.sh` analyzes every root in its own ShellCheck process, so a worker's peak memory is one root's analysis rather than the heaviest root in its shard.
This record holds the measurement that makes that ceiling checkable.

Measured 2026-09-24 against the tree at commit `8c1679adddc07f32b83c801d5f216cb290930c99` with the repository-pinned ShellCheck 0.11.0, full extended analysis, and `--external-sources`.

Per-root peak resident set across all 432 canonical roots, on Darwin aarch64:

| Statistic | Peak RSS |
| --- | ---: |
| median | 0.11 GiB |
| p90 | 1.06 GiB |
| p99 | 3.25 GiB |
| maximum (`bin/fm-watch.sh`) | 4.07 GiB |

Two sampled roots were re-measured on the other supported platforms to check that the ceiling is a property of the analysis rather than of the runner:

| Root | Darwin aarch64 | Linux x86_64 | Linux aarch64 |
| --- | ---: | ---: | ---: |
| `bin/fm-wake-grant.sh` | 0.55 GiB | 0.54 GiB | 0.56 GiB |
| `bin/fm-remote-inherit.sh` | 0.73 GiB | 0.73 GiB | 0.89 GiB |

Linux x86_64, which is what `ubuntu-latest` runs, matched Darwin aarch64 on both roots; Linux aarch64 ran up to 0.16 GiB higher.

Peak memory tracks the sourced-library fan-out, not file size: `bin/fm-backlog-handoff.sh` is 42 KB and peaks at 3.27 GiB, while `bin/fm-procevent.sh` is 110 KB and peaks at 1.50 GiB.
Byte weight is therefore a scheduling proxy only, and packing roots by it cannot bound memory.

Two bounded workers run concurrently per partition, so the worst case a partition can present to a runner is the sum of the two heaviest roots its shards hold.
That worst case does not move when a new file reshuffles the byte-weight packing, because no process ever holds more than one root.

## Reproduction

Install the pinned binary with `bin/fm-install-shellcheck.sh`, put it first on `PATH`, and run the sweep from the repository root.

```bash
set -eu
[ "$(bin/fm-lint.sh --required-version)" = "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" ]
for root in $(CI=true bin/fm-lint.sh --list-files); do
  /usr/bin/time -l -o /tmp/fm-lint-root.time \
    shellcheck --norc --external-sources -- "$root" >/dev/null 2>&1 || true
  awk -v root="$root" '/maximum resident set size/ {printf "%s\t%.0f\n", root, $1}' \
    /tmp/fm-lint-root.time
done
```

That form reads BSD `/usr/bin/time -l`, which reports bytes.
On GNU coreutils use `/usr/bin/time -f '%M'`, which reports kibibytes instead.
Peak RSS moves with the ShellCheck version and with each root's source graph, so re-run the sweep after a version bump or a large change to the shared libraries rather than quoting these figures forward.
