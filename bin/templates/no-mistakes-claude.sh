#!/usr/bin/env bash
# Installed by fm-seat.sh pipeline-install; the installer supplies these three
# absolute paths and the default-seat profile. Every invocation re-enters the seat guard, never a saved seat.
exec "$FM_PIPELINE_TOOL" launch --default-profile "$FM_PIPELINE_DEFAULT_PROFILE" "$FM_PIPELINE_HOME" "$FM_PIPELINE_CLAUDE" "$@"
