#!/usr/bin/env bash
# Isolate the cost of fm-host-mirror.sh's TAG/ID/TEXT split (base: 3x sed; head: parameter expansion)
for n in 8000 100000 1048576 4194304; do
  PARSED=$(printf 'captain\np1\n'; head -c $n /dev/zero | tr '\0' 'x')
  s=$(perl -MTime::HiRes=time -e 'printf "%.6f",time')
  TAG=$(printf '%s\n' "$PARSED" | sed -n '1p'); ID=$(printf '%s\n' "$PARSED" | sed -n '2p'); TEXT=$(printf '%s\n' "$PARSED" | sed '1,2d')
  m=$(perl -MTime::HiRes=time -e 'printf "%.6f",time')
  TAG2=${PARSED%%$'\n'*}; _REST=${PARSED#*$'\n'}; ID2=${_REST%%$'\n'*}; TEXT2=${_REST#*$'\n'}
  e=$(perl -MTime::HiRes=time -e 'printf "%.6f",time')
  same=no; [ "$TAG|$ID|$TEXT" = "$TAG2|$ID2|$TEXT2" ] && same=yes
  printf 'text=%-8s sed-split=%.3fs  expansion-split=%.3fs  identical=%s\n' $n $(echo "$m-$s"|bc) $(echo "$e-$m"|bc) $same
done
