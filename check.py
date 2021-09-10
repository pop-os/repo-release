#!/usr/bin/env python3

import apt
import os
import re
import repolib
import sys
import tempfile

POP_ORIGINS = ["pop-os-release"]
SUITE = "impish"

def pop_origins(ver):
    return (o for o in ver.origins if o.origin in POP_ORIGINS)

if len(sys.argv) >= 2:
    SUITE = sys.argv[1]

outdated = {}
with tempfile.TemporaryDirectory() as rootdir:
    print("\x1B[1msetting up repositories\x1B[0m")

    source_dir = f"{rootdir}/etc/apt/sources.list.d"
    os.makedirs(source_dir)

    apt.apt_pkg.config.set("Acquire::AllowInsecureRepositories", "true")

    def add_source(name, source):
        with open(f"{source_dir}/{name}.sources", 'w') as f:
            print(source.dump())
            f.write(source.dump())

    ubuntu = repolib.DebLine("deb http://us.archive.ubuntu.com/ubuntu " + SUITE + " main restricted universe multiverse")
    ubuntu.suites = [SUITE, f"{SUITE}-security", f"{SUITE}-updates", f"{SUITE}-backports"]
    add_source("ubuntu", ubuntu)

    pop_release = repolib.DebLine("deb http://apt.pop-os.org/release " + SUITE + " main")
    add_source("pop-os-release", pop_release)

    print("\x1B[1mupdating cache\x1B[0m")
    cache = apt.Cache(rootdir=rootdir, memonly=True)
    cache.update()
    cache.open()

    print("\x1B[1mchecking binary packages\x1B[0m")
    for pkg in cache:
        max_ver = max(pkg.versions)
        pop_ver = max((v for v in pkg.versions if any(pop_origins(v))), default=None)
        if pop_ver is not None and max_ver > pop_ver:
            pop_origin = next(pop_origins(pop_ver))
            max_origin = max_ver.origins[0]
            print(pkg)
            print(f"   {pop_origin.origin}:\t{pop_ver.source_name}\t{pop_ver.source_version}")
            print(f"   {max_origin.origin}:\t{max_ver.source_name}\t{max_ver.source_version}")
            if pop_ver.source_name == max_ver.source_name:
                outdated[pop_ver.source_name] = True

print(f"\x1B[1m{len(outdated)} source package(s) out of date\x1B[0m")
for source_name in outdated:
    print(f"  - {source_name}")
if len(outdated) > 0:
    sys.exit(1)
