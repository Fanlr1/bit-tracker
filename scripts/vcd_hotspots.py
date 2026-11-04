"""Find the signal that toggles without bound in a VCD.

WHY THIS EXISTS
    tb_mux_video wedges partway through: simulated time all but stops while the
    simulator keeps burning CPU. That is the signature of a zero-delay loop --
    some block keeps re-executing at the same instant. A 12 MB waveform covering
    only 40 us of simulated time says the same thing from the other direction:
    something is changing far more often than a design should.

    Reading 12 MB of VCD by eye is not practical, so this counts how many times
    each signal changes and prints the worst offenders. The one that dominates
    is where the loop lives.

HOW IT WORKS
    A VCD is a header (one declaration line per signal, giving an id code and a
    name), then timestamped value-change lines. This parses both and counts
    changes per id. It does not build a full waveform, so memory stays low even
    on a large file.

WHAT IT CANNOT SAY
    It reports WHICH signal toggles, not WHY. That still needs a look at the
    logic driving it. But it turns "somewhere in the mux and video path" into a
    specific net, which is the hard half.

Run:  python vcd_hotspots.py <file.vcd> [-n 20]
"""

import sys
import re
from collections import Counter

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    topn = 20
    if len(sys.argv) >= 4 and sys.argv[2] == '-n':
        topn = int(sys.argv[3])

    # ---------------------------------------------------------------- header
    names = {}          # id code -> signal name
    widths = {}         # id code -> declared width
    id_re = re.compile(r'\$var\s+(\w+)\s+(\d+)\s+(\S+)\s+([^\s$]+)')

    changes = Counter()
    last = {}           # id code -> last value seen (to ignore repeats)
    total_changes = 0
    timestamps = 0
    t_min = None
    t_max = None

    in_header = True
    with open(path, 'r', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if in_header:
                if line.startswith('$enddefinitions'):
                    in_header = False
                    continue
                m = id_re.match(line)
                if m:
                    _kind, width, code, name = m.groups()
                    names[code] = name
                    widths[code] = int(width)
                continue

            # ---- body ----
            if not line:
                continue
            c = line[0]
            if c == '#':
                timestamps += 1
                try:
                    t = int(line[1:])
                    if t_min is None:
                        t_min = t
                    t_max = t
                except ValueError:
                    pass
            elif c in '01xzXZ':
                # scalar: first char is the value, rest is the id
                code = line[1:]
                v = c
                if last.get(code) != v:
                    last[code] = v
                    changes[code] += 1
                    total_changes += 1
            elif c in 'bB':
                # vector: b<value> <id>
                parts = line[1:].split()
                if len(parts) == 2:
                    v, code = parts
                    if last.get(code) != v:
                        last[code] = v
                        changes[code] += 1
                        total_changes += 1
            elif c in 'rR':
                parts = line[1:].split()
                if len(parts) == 2:
                    v, code = parts
                    if last.get(code) != v:
                        last[code] = v
                        changes[code] += 1
                        total_changes += 1

    span = (t_max - t_min) if (t_min is not None and t_max is not None) else 0

    print('file        : %s' % path)
    print('signals     : %d' % len(names))
    print('timestamps  : %d' % timestamps)
    print('time span   : %d .. %d  (%d units)' % (t_min or 0, t_max or 0, span))
    print('value changes: %d' % total_changes)
    print('')

    if span > 0:
        print('changes per time unit: %.2f' % (total_changes / span))
        print('')

    print('top %d signals by number of changes:' % topn)
    print('  %-12s %-9s %s' % ('changes', 'width', 'name'))
    for code, n in changes.most_common(topn):
        print('  %-12d %-9d %s' % (n, widths.get(code, 0), names.get(code, '?' + code)))

    print('')
    print('Reading this: the top signal is where the activity is concentrated.')
    print('If one clocked net changes on essentially every timestamp, a block is')
    print('re-executing every delta cycle rather than once per clock.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
