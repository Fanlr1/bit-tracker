#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vcd_view.py -- print a VCD waveform as a readable timing table.

WHY THIS EXISTS
    The testbenches all call $dumpfile/$dumpvars, so running one produces a .vcd.
    But no waveform viewer is installed on this machine, and a .vcd is not meant
    to be read by eye:

        $var wire 1 ! pulse $end
        $var reg  1 " clk $end
        ...
        #5
        1"
        #10
        0"
        1!

    Signals are referred to by one-character codes, so you have to keep the header
    in your head while reading the body. This turns that into a table with real
    names, and can limit the window so a long dump stays readable.

USAGE
    python vcd_view.py <file.vcd> [--signals a,b,c] [--from NS] [--to NS]
                                     [--max-rows N] [--edges-only]

    --edges-only   print a row only where something changes (default is every
                   time step in the window, which is what you want for a short
                   dump and not for a long one)
"""

import argparse
import io
import re
import sys
from collections import OrderedDict


def parse(path):
    """Return (timescale, ordered {code: (width, name)}, list of (time, code, value))."""
    text = io.open(path, encoding='utf-8', errors='replace').read()

    ts = re.search(r'\$timescale\s+([^\s$]+)', text)
    timescale = ts.group(1) if ts else '?'
    # normalise: 1ns -> ns, 10ps -> 10ps
    unit = re.sub(r'^1', '', timescale) if timescale.startswith('1') else timescale

    sigs = OrderedDict()
    for m in re.finditer(r'\$var\s+(\w+)\s+(\d+)\s+(\S+)\s+([^\s$]+)', text):
        sigs[m.group(3)] = (int(m.group(2)), m.group(4))

    # body: everything after the last $end of the header
    body_start = text.rfind('$end')
    body = text[body_start + 4:]

    changes = []
    now = 0
    for tok in body.split():
        if tok.startswith('#'):
            try:
                now = int(tok[1:])
            except ValueError:
                pass
        elif tok and tok[0] in '01xzXZ' and len(tok) > 1:
            changes.append((now, tok[1:], tok[0]))          # scalar: value then code
        elif tok and tok[0] in 'bB':
            m = re.match(r'[bB]([01xzXZ]+)\s*(\S+)', tok)
            if m:
                changes.append((now, m.group(2), m.group(1)))
        elif tok and len(tok) > 1:
            changes.append((now, tok[1:], tok[0]))          # vector: first char is value
    return unit, sigs, changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('vcd')
    ap.add_argument('--signals', default='')
    ap.add_argument('--from', dest='t0', type=int, default=None)
    ap.add_argument('--to', dest='t1', type=int, default=None)
    ap.add_argument('--max-rows', type=int, default=200)
    ap.add_argument('--edges-only', action='store_true')
    a = ap.parse_args()

    unit, sigs, changes = parse(a.vcd)
    if not sigs:
        print('  no signals found -- is this a VCD?')
        return 1

    want = [s.strip() for s in a.signals.split(',') if s.strip()]
    # Order columns the way the caller asked for them, not the way the VCD happens
    # to declare them -- a waveform read left-to-right should follow the logic:
    # clock, then input, then output.
    by_name = {nm: code for code, (w, nm) in sigs.items()}
    names = OrderedDict()
    if want:
        for nm in want:
            if nm in by_name:
                names[by_name[nm]] = nm
            else:
                print('  no such signal: %s' % nm)
    else:
        for code, (w, nm) in sigs.items():
            names[code] = nm
    if not names:
        print('  none of those signal names are in the file. Available:')
        print('   ', ', '.join(sorted(n for _, n in sigs.values())))
        return 1

    cur = {c: 'x' * sigs[c][0] for c in names}
    rows, last = [], None
    for t, code, val in changes:
        if code in cur:
            cur[code] = val
        if a.t0 is not None and t < a.t0:
            continue
        if a.t1 is not None and t > a.t1:
            break
        snap = tuple(cur[c] for c in names)
        if a.edges_only and snap == last:
            continue
        rows.append((t, snap))
        last = snap
        if len(rows) > a.max_rows:
            break

    w = max(len(n) for n in names.values())
    print('  timescale: 1%s     signals: %d     rows: %d' %
          (unit, len(names), len(rows)))
    print()
    head = '  %-10s' % ('time/' + unit)
    for c in names:
        head += '  %-*s' % (max(w, sigs[c][0]), names[c])
    print(head)
    print('  ' + '-' * (len(head) - 2))
    prev = None
    for t, snap in rows:
        line = '  %-10d' % t
        for i, c in enumerate(names):
            v = snap[i]
            mark = ' ' if (prev is None or prev[i] == v) else '*'
            line += '  %-*s' % (max(w, sigs[c][0]), v + mark)
        print(line)
        prev = snap
    if len(rows) > a.max_rows:
        print('  ... truncated at %d rows (use --max-rows or --to)' % a.max_rows)
    return 0


if __name__ == '__main__':
    sys.exit(main())
