import sys, json
sys.path.insert(0, '~/.local/bin/clickup-axi')
from clickup_axi import events
from clickup_axi.summary import summary_for
lines = [l for l in open(sys.argv[1]) if l.strip()]
parsed = []
for l in lines:
    e = events.parse(l)
    d = json.loads(l)
    print(f"parsed {d['event']:18} progress={'yes' if 'progress' in d else 'no '} -> {type(e).__name__}")
    parsed.append(e)
print('---- briefing rendered after the full A sequence ----')
print(summary_for(None, parsed, 'in progress', '', authoritative=True))
print('---- briefing rendered after pr-opened, blocked, decision-answered, resumed ----')
print(summary_for(None, parsed[:5], 'in progress', '', authoritative=True))
