import json, glob, os, sys, collections

BASE = sys.argv[1]
WHICH = sys.argv[2] if len(sys.argv) > 2 else 'light'
root = os.path.join(BASE, WHICH)

rows = collections.defaultdict(list)
for f in glob.glob(os.path.join(root, 'rung-*', '*', 'run*', '*', 'target-*', 'result.json')):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    m = d.get('metrics', {})
    p99 = m.get('latency_p99_us')
    p999 = m.get('latency_p999_us')
    if p99 is None:
        continue
    repo = (d.get('target') or {}).get('repo', '?')
    parts = f.replace('\\', '/').split('/')
    rung = int([p for p in parts if p.startswith('rung-')][0].replace('rung-', '').replace('rps', ''))
    pair = [p for p in parts if p[:2] in ('1-', '2-', '3-')][0][0]
    rows[(repo, pair, rung)].append((p99 / 1000.0, (p999 / 1000.0) if p999 else None))

print(f"{'target':<20}{'pair':>5}{'rung':>7}{'n':>4}{'p99_mean':>10}{'p99.9_mean':>12}{'p99.9_max':>11}")
for key in sorted(rows):
    repo, pair, rung = key
    v = rows[key]
    p99s = [a for a, b in v]
    p999s = [b for a, b in v if b is not None]
    line = f"{repo[:19]:<20}{pair:>5}{rung:>7}{len(v):>4}{sum(p99s)/len(p99s):>10.2f}"
    if p999s:
        line += f"{sum(p999s)/len(p999s):>12.2f}{max(p999s):>11.2f}"
    else:
        line += f"{'-':>12}{'-':>11}"
    print(line)
