# shellcheck shell=bash disable=SC2034
# fm-persist-request-lib.sh - the ONE owner of the open-record persist contract
# firstmate asks for before it replaces a running agent. Source only.
#
# Replacing an agent - a second mate being restarted onto current instructions,
# or the lead itself moving to another Claude seat - drops its conversation and
# keeps every durable record. So the same gate comes first in both cases: write
# down the open work that exists ONLY in that conversation, and nothing else.
# The narrowing matters as much as the ask. It is the /stow skill's
# "Open-record persistence" section alone; pulling in that skill's memory,
# learnings, and captain-preference sweeps would make every replacement cost far
# more than the reload it is paying for.
#
# The /stow skill remains the authority on HOW to persist; this is the request
# that names it, kept in one place so the second mate's restart and the lead's
# own restart can never drift into two different contracts.
FM_PERSIST_OPEN_RECORDS_CONTRACT='persist the open work you are holding only in this conversation, following the /stow skill'"'"'s "Open-record persistence" section and nothing else from that skill: file a task for each open record that exists only in this conversation, including any captain call you had formed but never registered, and correct any task whose status no longer reflects what you now know. Do NOT run the memory, learnings, or captain-preference sweeps.'
