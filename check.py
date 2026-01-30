#!/usr/bin/env python3

import apt
import os
import re
import repolib
import sys
import tempfile

UBUNTU_ORIGIN = "Ubuntu"
POP_ORIGIN_RELEASE = "pop-os-release"
POP_ORIGIN_STAGING = "pop-os-staging-master"
LP_ORIGIN_STABLE = "LP-PPA-system76-dev-stable"
LP_ORIGIN_PRE_STABLE = "LP-PPA-system76-dev-pre-stable"

SUITE = "noble"

if len(sys.argv) >= 2:
    SUITE = sys.argv[1]

dev = False
if len(sys.argv) >= 3:
    if sys.argv[2] == '--dev':
        dev = True

errors = {}
with tempfile.TemporaryDirectory() as rootdir:
    print("\x1B[1msetting up repositories\x1B[0m")

    source_dir = f"{rootdir}/etc/apt/sources.list.d"
    os.makedirs(source_dir)

    apt.apt_pkg.config.set("Acquire::AllowInsecureRepositories", "true")

    def add_source(name, line, suites = None):
        source = repolib.Source()
        source.load_from_data([line])
        source.generate_default_ident()
        if suites is not None:
            source.suites = suites
        with open(f"{source_dir}/{name}.sources", 'w') as f:
            print(source.dump())
            f.write(source.dump())

    add_source(
        "ubuntu",
        "deb http://us.archive.ubuntu.com/ubuntu " + SUITE + " main restricted universe multiverse",
        [SUITE, f"{SUITE}-security", f"{SUITE}-updates", f"{SUITE}-backports"]
    )
    if dev:
        add_source("pop-os-release", "deb http://apt.pop-os.org/release-ubuntu " + SUITE + " main")
        add_source("pop-os-staging-master", "deb http://apt.pop-os.org/staging-ubuntu/master " + SUITE + " main")
        add_source("launchpad-system76-dev-stable", "deb https://ppa.launchpadcontent.net/system76-dev/stable/ubuntu " + SUITE + " main")
        add_source("launchpad-system76-dev-pre-stable", "deb https://ppa.launchpadcontent.net/system76-dev/pre-stable/ubuntu " + SUITE + " main")
    else:
        add_source("pop-os-release", "deb http://apt.pop-os.org/release " + SUITE + " main")
        add_source("pop-os-staging-master", "deb http://apt.pop-os.org/staging/master " + SUITE + " main")

    print("\x1B[1mupdating cache\x1B[0m")
    cache = apt.Cache(rootdir=rootdir, memonly=True, progress=None)
    cache.update(fetch_progress=None)
    cache.open(progress=None)

    print("\x1B[1mchecking binary packages\x1B[0m")
    for pkg in cache:
        def match_origin(ver, origin):
            return (o for o in ver.origins if o.origin == origin)


        def error(kind, ver):
            if not kind in errors:
                errors[kind] = {}
            errors[kind][ver.source_name] = ver.source_version

        ubuntu_ver = max((v for v in pkg.versions if any(match_origin(v, UBUNTU_ORIGIN))), default=None)
        if dev:
            staging_ver = max((v for v in pkg.versions if any(match_origin(v, POP_ORIGIN_STAGING))), default=None)
            pre_stable_ver = max((v for v in pkg.versions if any(match_origin(v, LP_ORIGIN_PRE_STABLE))), default=None)
            stable_ver = max((v for v in pkg.versions if any(match_origin(v, LP_ORIGIN_STABLE))), default=None)

            # Check packages that are in pre-stable but not in staging (launchpad deletions are manual)
            if pre_stable_ver is not None and staging_ver is None:
                error("in pre-stable but not staging", pre_stable_ver)

            # Check packages that are in stable but not in pre-stable (launchpad deletions are manual)
            if stable_ver is not None and pre_stable_ver is None:
                error("in stable but not pre-stable", stable_ver)
            
            # Check packages that are older than Ubuntu's version
            if stable_ver is not None and ubuntu_ver is not None and ubuntu_ver > stable_ver and stable_ver.source_name == ubuntu_ver.source_name:
                error("in stable older than ubuntu", ubuntu_ver)
        else:
            release_ver = max((v for v in pkg.versions if any(match_origin(v, POP_ORIGIN_RELEASE))), default=None)

            # Check packages that are older than Ubuntu's version
            if release_ver is not None and ubuntu_ver is not None and ubuntu_ver > release_ver and release_ver.source_name == ubuntu_ver.source_name:
                error("in release older than ubuntu", ubuntu_ver)

for kind in errors:
    packages = errors[kind]
    print(f"\x1B[1m{len(packages)} source package(s) {kind}\x1B[0m")
    for source_name in sorted(packages):
        print(f"  - {source_name}: {packages[source_name]}")

if len(errors) > 0:
    sys.exit(1)
