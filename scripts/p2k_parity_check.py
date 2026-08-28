#!/usr/bin/env python3
"""Compare two Phase 2K ACL captures and classify every difference.

    p2k_parity_check.py SOURCE.csv AFTER.csv

Prints MISSING / EXTRA / RESIDUAL counts and exits non-zero if any difference
falls outside the approved provenance residual.

Comparison rules, matching the recovery's own contract:

  * Sections G and H are excluded. G is an aggregate of the sections A-D edges
    the recovery replays individually, so it carries nothing those edges do not.
    H is role state, which the recovery verifies in preflight and never changes.
  * Every other row is compared on all fields EXCEPT acl_source, so a difference
    in provenance alone is not a difference in privilege.
  * The one approved residual: an object whose captured ACL is NULL may afterwards
    read as explicit, because PostgreSQL cannot restore a NULL ACL once the ACL
    has been materialised. That shows up as section E's annotation changing and
    as section I emitting the object's built-in default edges. Both are permitted
    for NULL-captured objects and for nothing else.
"""

from __future__ import annotations

import collections
import csv
import sys


def load(path: str) -> list[dict]:
    rows = list(csv.reader(open(path, newline="")))
    return [dict(zip(rows[0], r)) for r in rows[1:] if r]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, aft = load(sys.argv[1]), load(sys.argv[2])

    null_objs = {
        (r["object_kind"], r["object_identity"])
        for r in src
        if r["section"].startswith("E.") and "acl null" in r["acl_source"]
    }

    def key(r):
        return (r["section"], r["object_kind"], r["object_identity"], r["owner"],
                r["grantee"], r["grantor"], r["privilege_type"], r["is_grantable"])

    def keep(r):
        return not r["section"].startswith(("G.", "H."))

    S = collections.Counter(key(r) for r in src if keep(r))
    A = collections.Counter(key(r) for r in aft if keep(r))
    missing = list((S - A).elements())
    extra = list((A - S).elements())

    def approved(k):
        return (k[1], k[2]) in null_objs and k[0].startswith(("I.", "E."))

    bad_missing = [k for k in missing if not approved(k)]
    bad_extra = [k for k in extra if not approved(k)]
    residual = [k for k in missing + extra if approved(k)]

    print(f"MISSING {len(bad_missing)}")
    print(f"EXTRA {len(bad_extra)}")
    print(f"RESIDUAL {len(residual)}")
    for k in (bad_missing + bad_extra)[:12]:
        print(f"  DIFF {k[0]} | {k[1]} | {k[2]} | grantee={k[4]} | {k[6]}")
    return 0 if not (bad_missing or bad_extra) else 1


if __name__ == "__main__":
    sys.exit(main())
