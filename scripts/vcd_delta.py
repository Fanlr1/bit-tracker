"""Find signals that change MORE THAN ONCE within a single timestamp.

WHY THIS IS THE RIGHT QUESTION
    An earlier version of this script counted total changes per signal and found
    nothing unusual -- clk_int topped the list, which is exactly what a clock
    should do. That measured the wrong thing.

    A zero-delay loop is not "a signal changes a lot". It is "the simulator
    executes a block repeatedly WITHOUT ADVANCING TIME". The fingerprint is
    therefore a signal changing several times while the timestamp stays the
    same. Across a long run, ordinary signals change once per timestamp and the
    total count says nothing; inside a delta loop, a handful of signals churn
    many times per timestamp.

    So this counts, per signal, the number of timestamps at which it changed
    more than once, and reports the worst offenders. Those are the nets in the
    loop.

HOW TO READ IT
    A signal with a high "multi-change timestamps" count is being recomputed
    over and over at the same instant. Follow it back to the always block that
    drives it; that block is the loop.

Run:  python vcd_delta.py <file.vcd> [-n 20]
"""

import sys
import re
from collections import Counter, defaultdict


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    topn = 20
    if len(sys.argv) >= 4 and sys.argv[2] == '-n':
        topn = int(sys.argv[3])

    names = {}
    widths = {}
    id_re = re.compile(r'\$var\s+(\w+)\s+(\d+)\s+(\S+)\s+([^\s$]+)')

    per_ts = defaultdict(int)      # id -> changes within the current timestamp
    multi_ts = Counter()           # id -> number of timestamps with >1 change
    max_in_ts = Counter()          # id -> most changes seen in one timestamp
    total = Counter()
    timestamps = 0
    bad_ts = 0                     # timestamps where anything changed >1 time

    in_header = True
    last = {}

    def flush_ts():
        nonlocal bad_ts
        if not per_ts:
            return
        hot = False
        for code, n in per_ts.items():
            if n > 1:
                multi_ts[code] += 1
                if n > max_in_ts[code]:
                    max_in_ts[code] = n
                hot = True
        if hot:
            bad_ts += 1
        per_ts.clear()

    with open(path, 'r', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if in_header:
                if line.startswith('$enddefinitions'):
                    in_header = False
                    continue
                m = id_re.match(line)
                if m:
                    _k, w, code, name = m.groups()
                    names[code] = name
                    widths[code] = int(w)
                continue

            if not line:
                continue
            c = line[0]
            if c == '#':
                flush_ts()
                timestamps += 1
            elif c in '01xzXZ':
                code = line[1:]
                if last.get(code) != c:
                    last[code] = c
                    per_ts[code] += 1
                    total[code] += 1
            elif c in 'bB':
                parts = line[1:].split()
                if len(parts) == 2:
                    v, code = parts
                    if last.get(code) != v:
                        last[code] = v
                        per_ts[code] += 1
                        total[code] += 1
            elif c in 'rR':
                parts = line[1:].split()
                if len(parts) == 2:
                    v, code = parts
                    if last.get(code) != v:
                        last[code] = v
                        per_ts[code] += 1
                        total[code] += 1
    flush_ts()

    print('file                  : %s' % path)
    print('signals               : %d' % len(names))
    print('timestamps            : %d' % timestamps)
    print('timestamps with any signal changing >1 time: %d (%.2f%%)'
          % (bad_ts, (100.0 * bad_ts / timestamps) if timestamps else 0))
    print('')
    print('Signals that change more than once at the same instant:')
    print('  %-10s %-10s %-9s %s' % ('timestamps', 'worst-in-1', 'width', 'name'))
    if not multi_ts:
        print('  (none -- no delta-cycle churn detected)')
    for code, n in multi_ts.most_common(topn):
        print('  %-10d %-10d %-9d %s'
              % (n, max_in_ts[code], widths.get(code, 0), names.get(code, '?' + code)))

    print('')
    print('A signal high on this list is being recomputed repeatedly without time')
    print('advancing. The always block driving it is where the loop lives.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
