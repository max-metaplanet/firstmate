#!/usr/bin/env bash
# Coverage-preservation check: compares every function in the pre-split
# scripts (at BASE) with the split pieces + helper libraries (at HEAD).
set -u
BASE=${1:-1622b149}
fams=("supervision-host:tests/fm-supervision-host.test.sh:tests/fm-supervision-host.test.sh tests/fm-supervision-host-engine.test.sh tests/fm-supervision-host-park.test.sh tests/fm-supervision-host-stop-hook.test.sh tests/supervision-host-helpers.sh"
      "watch-triage:tests/fm-watch-triage.test.sh:tests/fm-watch-triage*.test.sh tests/watch-triage-helpers.sh")
T=$(mktemp -d)
# emit "name<TAB>sha" for each top-level function (name() { ... ^})
funcs() { awk -v F="$2" '
  /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { name=$0; sub(/\(\).*/,"",name); body=$0"\n"; if ($0 ~ /\{.*\} *(#.*)?$/) { printf "%s\t%s\t", name, F; cmd="shasum | cut -c1-12"; printf "%s", body | cmd; close(cmd); next } infn=1; next }
  infn { body=body $0 "\n"; if ($0=="}") { printf "%s\t%s\t", name, F; cmd="shasum | cut -c1-12"; printf "%s", body | cmd; close(cmd); infn=0 } }' "$1"; }
rc=0
for f in "${fams[@]}"; do
  IFS=: read -r fam old newglob <<<"$f"
  git show "$BASE:$old" > "$T/old.sh"
  funcs "$T/old.sh" OLD > "$T/old.tsv"
  : > "$T/new.tsv"; for n in $newglob; do funcs "$n" "$n" >> "$T/new.tsv"; done
  oldcases=$(awk -F'\t' '$1 ~ /^test_/' "$T/old.tsv" | wc -l | tr -d ' ')
  newcases=$(awk -F'\t' '$1 ~ /^test_/' "$T/new.tsv" | wc -l | tr -d ' ')
  echo "== $fam: base cases=$oldcases  split cases=$newcases  base funcs=$(wc -l <"$T/old.tsv"|tr -d ' ') split funcs=$(wc -l <"$T/new.tsv"|tr -d ' ')"
  for n in $newglob; do case $n in *.test.sh) echo "   $n: $(grep -c '^test_[A-Za-z0-9_]*() *{' "$n") cases";; esac; done
  while IFS=$'\t' read -r name _ sha; do
    hits=$(awk -F'\t' -v n="$name" '$1==n' "$T/new.tsv")
    cnt=$(printf '%s' "$hits" | grep -c . )
    if [ "$cnt" -ne 1 ]; then echo "   MISSING/DUP $name count=$cnt"; rc=1; continue; fi
    nsha=$(printf '%s' "$hits" | cut -f3); file=$(printf '%s' "$hits" | cut -f2)
    if [ "$nsha" != "$sha" ]; then echo "   BODY-CHANGED $name ($file)"; fi
    case $name in test_*)
      # case must be invoked from its own file's top-level case list
      grep -qx "$name" "$file" || { echo "   NOT-CALLED $name in $file"; rc=1; } ;;
    esac
  done < "$T/old.tsv"
  awk -F'\t' 'NR==FNR{o[$1]=1;next} !($1 in o){print "   NEW-FUNC "$1" ("$2")"}' "$T/old.tsv" "$T/new.tsv"
done
rm -rf "$T"; echo "rc=$rc"; exit $rc
