#!/usr/bin/env python3
"""Write a JFR settings file that records virtual-thread pinning and nothing of the kernel's own.

JFR enables an event that its settings file does not mention, so a recording of a kernel process
captures every kernel event, several per request, and then measures its own cost. The file
generated here names every JFR event class in the kernel build under test and disables it: any
class file that references jdk/jfr/Event contributes its class name and every eu.exeris.* string
it holds (the @Name values). Naming a string that is not an event is harmless.

Usage: make_pinning_jfc.py <classes-dir>... > diag.jfc
"""
import re
import sys
from pathlib import Path

NAME_RE = re.compile(rb"eu\.exeris\.[A-Za-z0-9_.$]+")


def event_names(roots):
    names = set()
    for root in roots:
        root = Path(root)
        for cls in root.rglob("*.class"):
            data = cls.read_bytes()
            if b"jdk/jfr/Event" not in data:
                continue
            names.add(".".join(cls.relative_to(root).with_suffix("").parts))
            names.update(m.decode() for m in NAME_RE.findall(data))
    return sorted(n for n in names if not n.endswith("."))


def main(roots):
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<configuration version="2.0" label="Virtual-thread pinning only">',
           '  <event name="jdk.VirtualThreadPinned"><setting name="enabled">true</setting>'
           '<setting name="stackTrace">true</setting><setting name="threshold">1 ms</setting></event>',
           '  <event name="jdk.VirtualThreadSubmitFailed"><setting name="enabled">true</setting>'
           '<setting name="stackTrace">true</setting></event>']
    out += [f'  <event name="{n}"><setting name="enabled">false</setting></event>' for n in event_names(roots)]
    out.append("</configuration>")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1:])
