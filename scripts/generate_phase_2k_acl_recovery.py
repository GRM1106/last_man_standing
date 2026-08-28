#!/usr/bin/env python3
"""Deterministic generator for the Phase 2K ACL recovery artifact.

Reads a Phase 2K ACL capture CSV (the source of truth) and emits a single
executable SQL artifact that drives a RESTORED COPY's privilege state to match
that capture, using the full reset/replay algorithm validated in
PHASE_2K_ACL_RECOVERY_DESIGN.md.

Design notes that matter for review:

  * The emitted SQL is ALGORITHM + DATA. The algorithm is a fixed template that
    does not vary with the input; the only generated part is the staged source
    snapshot. Diffing two artifacts therefore shows only data changes.
  * Identifiers are decomposed here, in Python, into (schema, name, args,
    column) and staged as separate columns. The SQL never parses a dotted
    identity string, so an object name containing a dot cannot be mis-split at
    run time. Identities that cannot be decomposed unambiguously are refused.
  * Output is byte-identical for identical input: every emitted row set is
    sorted by an explicit total key, and no timestamp, hostname, path or
    environment value is written into the artifact.
  * Nothing is printed except counts, hashes and structural facts. Raw ACL rows
    are never echoed, and the capture carries no secrets by construction.

This generator does not connect to any database and does not execute anything.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Capture contract
# --------------------------------------------------------------------------

COLUMNS = [
    "section", "object_kind", "object_identity", "owner",
    "grantee", "grantor", "privilege_type", "is_grantable", "acl_source",
]

SECTIONS = {
    "A. SCHEMA PRIVILEGES", "B. RELATION PRIVILEGES", "C. COLUMN PRIVILEGES",
    "D. ROUTINE PRIVILEGES", "E. OWNERSHIP", "F. DEFAULT PRIVILEGES",
    "G. GRANTEES OBSERVED", "H. ROLE SECURITY CONTEXT", "I. TYPE PRIVILEGES",
    "J. SCHEMA SCOPE",
}

# object_kind -> class, for the sections that name real objects
RELATION_KINDS = {
    "table": "relation", "partitioned table": "relation", "view": "relation",
    "materialized view": "relation", "foreign table": "relation",
    "sequence": "sequence",
}
ROUTINE_KINDS = {"function", "procedure", "aggregate", "window"}
TYPE_KINDS = {
    "enum type", "domain", "composite type", "range type", "base type",
    "row type (table)", "row type (partitioned table)", "row type (view)",
    "row type (materialized view)", "row type (foreign table)",
}

# F. DEFAULT PRIVILEGES object_kind -> pg_default_acl.defaclobjtype
DEFACL_OBJTYPE = {
    "future table": "r", "future sequence": "S", "future routine": "f",
    "future type": "T", "future schema": "n",
}

IN_SCOPE_SCHEMA = "public"
UNCLASSIFIED = "UNCLASSIFIED"

# privilege_type and a routine's argument list are the only capture fields the
# artifact interpolates UNQUOTED (format('%s')), because neither is an
# identifier: a privilege is a keyword and an argument list is already valid SQL
# from pg_get_function_identity_arguments(). That makes them an injection
# channel, and PL/pgSQL EXECUTE runs multiple statements from one string. The
# default-privilege replay runs under SET ROLE <default-rule owner>, which for a
# Supabase capture includes a superuser, and a non-transactional payload such as
# COPY ... TO PROGRAM survives the rollback that verification would otherwise
# force. Both fields are therefore constrained here, at generation time.
PRIVILEGES = {
    "SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER",
    "MAINTAIN", "EXECUTE", "USAGE", "CREATE", "CONNECT", "TEMPORARY", "TEMP",
    "SET", "ALTER SYSTEM",
}
# statement terminators, comment introducers, dollar-quoting and newlines
RARGS_FORBIDDEN = (";", "--", "/*", "*/", "$", "\n", "\r", "\x00")


def check_privilege(value: str) -> str:
    if value not in PRIVILEGES:
        raise Refused(
            "privilege_type is not a recognised PostgreSQL privilege keyword; "
            "refusing (this field is interpolated unquoted into executed SQL)"
        )
    return value


def check_rargs(value: str) -> str:
    for bad in RARGS_FORBIDDEN:
        if bad in value:
            raise Refused(
                "a routine argument list contains a statement terminator, "
                "comment introducer, dollar-quote or newline; refusing (this "
                "field is interpolated unquoted into executed SQL)"
            )
    return value


class Refused(Exception):
    """A fail-closed refusal. The artifact is not written."""


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sql_str(value: str) -> str:
    """A SQL string literal. Doubles embedded single quotes."""
    return "'" + value.replace("'", "''") + "'"


def sql_bool(value: str) -> str:
    if value == "true":
        return "true"
    if value == "false":
        return "false"
    raise Refused(f"is_grantable must be 'true' or 'false', found {value!r}")


def split_qualified(identity: str, expect_parts: int, what: str) -> list[str]:
    """Split a capture identity that must contain exactly N dot-separated parts.

    The capture emits identities as unquoted concatenations, so an identifier
    containing a dot would be ambiguous. Refuse rather than guess.
    """
    parts = identity.split(".")
    if len(parts) != expect_parts or any(p == "" for p in parts):
        raise Refused(
            f"{what} identity is not unambiguously decomposable into "
            f"{expect_parts} parts; refusing (an identifier containing a dot "
            f"cannot be split safely)"
        )
    return parts


def split_routine(identity: str) -> tuple[str, str, str]:
    """'public.name(a integer, b text)' -> ('public', 'name', 'a integer, b text')."""
    open_paren = identity.find("(")
    if open_paren < 0 or not identity.endswith(")"):
        raise Refused("routine identity is missing its argument list; refusing")
    head, args = identity[:open_paren], identity[open_paren + 1:-1]
    sch, nm = split_qualified(head, 2, "routine")
    return sch, nm, check_rargs(args)


# --------------------------------------------------------------------------
# Parse and validate
# --------------------------------------------------------------------------

def load_capture(path: Path, required_sha: str) -> list[dict]:
    actual = sha256_file(path)
    if actual != required_sha.lower():
        raise Refused(
            "source capture SHA-256 mismatch — refusing to generate\n"
            f"        expected {required_sha.lower()}\n"
            f"        actual   {actual}"
        )

    raw_bytes = path.read_bytes()
    if b"\x00" in raw_bytes:
        raise Refused("source capture contains a NUL byte; refusing")
    try:
        raw_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Refused(f"source capture is not valid UTF-8 ({exc.reason}); refusing")

    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.reader(fh)
        try:
            header = next(reader)
        except StopIteration:
            raise Refused("source capture is empty")
        except csv.Error as exc:
            raise Refused(f"source capture is not parseable CSV ({exc}); refusing")
        if header != COLUMNS:
            raise Refused(
                f"unexpected header: expected {len(COLUMNS)} columns "
                f"{COLUMNS}, found {len(header)}"
            )
        rows = []
        try:
            enumerated = list(enumerate(reader, start=2))
        except csv.Error as exc:
            raise Refused(f"source capture is not parseable CSV ({exc}); refusing")
        for lineno, raw in enumerated:
            if not raw:
                raise Refused(f"source capture has an empty record at CSV record {lineno}")
            if len(raw) != len(COLUMNS):
                raise Refused(
                    f"row at CSV record {lineno} has {len(raw)} columns, "
                    f"expected {len(COLUMNS)}"
                )
            rows.append(dict(zip(COLUMNS, raw)))

    unknown = sorted({r["section"] for r in rows} - SECTIONS)
    if unknown:
        raise Refused(f"unknown section(s) in capture: {unknown}")

    # Duplicate identity: the capture is a set, so an exact repeat of a whole
    # row means the capture is malformed or was concatenated.
    seen: set[tuple] = set()
    for i, r in enumerate(rows, start=1):
        key = tuple(r[c] for c in COLUMNS)
        if key in seen:
            raise Refused(
                f"duplicate identity: section {r['section']!r} contains a "
                f"repeated row (record {i}); the capture must be a set"
            )
        seen.add(key)

    # Ownership must name each object exactly once.
    own_seen: set[tuple] = set()
    for r in rows:
        if r["section"] != "E. OWNERSHIP":
            continue
        key = (r["object_kind"], r["object_identity"])
        if key in own_seen:
            raise Refused(
                f"duplicate identity in E. OWNERSHIP for object_kind "
                f"{r['object_kind']!r}"
            )
        own_seen.add(key)

    bad_scope = [
        r["object_identity"] for r in rows
        if r["section"] == "J. SCHEMA SCOPE" and UNCLASSIFIED in r["acl_source"]
    ]
    if bad_scope:
        raise Refused(
            "source capture contains UNCLASSIFIED schema(s) "
            f"{sorted(bad_scope)} — recovery must fail closed"
        )

    return rows


# --------------------------------------------------------------------------
# Shape the staged snapshot
# --------------------------------------------------------------------------

def build_edges(rows: list[dict], owner_index: dict) -> list[tuple]:
    """(cls, ident, sch, nm, rargs, col, own_cls, own_ident, owner,
        grantee, grantor, priv, grantable).

    own_cls/own_ident name the object that OWNS the ACL this edge belongs to.
    For a column edge that is the parent relation, which is what carries the
    ownership row; for everything else it is the object itself. Resolving it
    here means the SQL never has to infer a parent from a dotted string.
    """
    out = []
    for r in rows:
        sec, kind, ident = r["section"], r["object_kind"], r["object_identity"]
        if sec == "A. SCHEMA PRIVILEGES":
            cls, sch, nm, rargs, col = "schema", ident, ident, None, None
            own_ident = ident
        elif sec == "B. RELATION PRIVILEGES":
            if kind not in RELATION_KINDS:
                raise Refused(f"unsupported relation object_kind {kind!r}")
            cls = RELATION_KINDS[kind]
            sch, nm = split_qualified(ident, 2, "relation")
            rargs, col, own_ident = None, None, ident
        elif sec == "C. COLUMN PRIVILEGES":
            sch, nm, col = split_qualified(ident, 3, "column")
            cls, rargs = "column", None
            own_ident = f"{sch}.{nm}"
        elif sec == "D. ROUTINE PRIVILEGES":
            if kind not in ROUTINE_KINDS:
                raise Refused(f"unsupported routine object_kind {kind!r}")
            sch, nm, rargs = split_routine(ident)
            cls, col, own_ident = "routine", None, ident
        elif sec == "I. TYPE PRIVILEGES":
            if kind not in TYPE_KINDS:
                raise Refused(f"unsupported type object_kind {kind!r}")
            sch, nm = split_qualified(ident, 2, "type")
            cls, rargs, col, own_ident = "type", None, None, ident
        else:
            continue
        if cls == "column":
            # a column's ACL belongs to its parent, which E. OWNERSHIP records
            # as either a relation or a sequence
            own_cls = next(
                (c for c in ("relation", "sequence")
                 if (c, own_ident) in owner_index), None)
            if own_cls is None:
                raise Refused(
                    "a column privilege names a parent object that has no "
                    "E. OWNERSHIP row; the capture is incomplete"
                )
        else:
            own_cls = cls
            if (own_cls, own_ident) not in owner_index:
                raise Refused(
                    f"section {sec!r} names an object that has no E. OWNERSHIP "
                    "row; the capture is incomplete and recovery would be unsafe"
                )
        out.append((
            cls, ident, sch, nm, rargs, col, own_cls, own_ident, r["owner"],
            r["grantee"], r["grantor"], check_privilege(r["privilege_type"]),
            r["is_grantable"],
        ))
    return sorted(out, key=lambda t: tuple("" if x is None else x for x in t))


def build_owners(rows: list[dict]) -> list[tuple]:
    """(cls, ident, sch, nm, rargs, owner, state)."""
    out = []
    for r in rows:
        if r["section"] != "E. OWNERSHIP":
            continue
        kind, ident, src = r["object_kind"], r["object_identity"], r["acl_source"]
        if kind in RELATION_KINDS:
            cls = RELATION_KINDS[kind]
            sch, nm = split_qualified(ident, 2, "relation")
            rargs = None
        elif kind in ROUTINE_KINDS:
            cls = "routine"
            sch, nm, rargs = split_routine(ident)
        elif kind in TYPE_KINDS:
            cls = "type"
            sch, nm = split_qualified(ident, 2, "type")
            rargs = None
        elif kind == "schema":
            cls, sch, nm, rargs = "schema", ident, ident, None
        else:
            raise Refused(f"unsupported E. OWNERSHIP object_kind {kind!r}")
        if "acl null" in src:
            state = "null"
        elif "acl empty" in src:
            state = "empty"
        else:
            state = "explicit"
        out.append((cls, ident, sch, nm, rargs, r["owner"], state))
    return sorted(out, key=lambda t: tuple("" if x is None else x for x in t))


def build_defaults(rows: list[dict]) -> tuple[list[tuple], list[tuple]]:
    """Returns (groups, edges) for F. DEFAULT PRIVILEGES.

    groups: (defowner, objtype, sch)     -- sch '' means the unscoped rule
    edges:  (defowner, objtype, sch, grantee, priv, grantable)
    """
    groups: set[tuple] = set()
    edges: list[tuple] = []
    for r in rows:
        if r["section"] != "F. DEFAULT PRIVILEGES":
            continue
        kind = r["object_kind"]
        if kind not in DEFACL_OBJTYPE:
            raise Refused(f"unsupported F. DEFAULT PRIVILEGES object_kind {kind!r}")
        objtype = DEFACL_OBJTYPE[kind]
        sch = "" if r["object_identity"] == "(all schemas)" else r["object_identity"]
        groups.add((r["owner"], objtype, sch))
        if r["grantee"] == "-":
            continue  # marker row: records that the rule exists
        edges.append((r["owner"], objtype, sch, r["grantee"],
                      check_privilege(r["privilege_type"]), r["is_grantable"]))
    return sorted(groups), sorted(edges)


def build_role_context(rows: list[dict]) -> tuple[list[tuple], list[tuple]]:
    """Section H -> (role attributes, membership edges).

    Role membership decides the real reach of every grant: a privilege held by a
    group confers nothing on a principal that is no longer a member. The artifact
    never MUTATES roles, but it must refuse to run against a role graph that
    differs from the captured one, or "ACL parity" would not imply the access
    parity the design claims.

    Section G is deliberately not consumed. Its rows are counts of grantees
    observed in sections A-D, i.e. an aggregate OF the ACL edges this artifact
    already replays edge-for-edge. Replaying G separately would be replaying the
    same facts twice, and a G row can never carry information that is not
    derivable from the edges themselves.
    """
    attrs: list[tuple] = []
    members: list[tuple] = []
    for r in rows:
        if r["section"] != "H. ROLE SECURITY CONTEXT":
            continue
        if r["object_kind"] == "role" and r["privilege_type"] == "attributes":
            attrs.append((r["object_identity"], r["acl_source"]))
        elif r["object_kind"] == "membership":
            parts = r["object_identity"].split(" -> ")
            if len(parts) != 2 or not all(parts):
                raise Refused(
                    "a membership identity is not decomposable into "
                    "'member -> group'; refusing"
                )
            member, grp = parts
            opts = dict(
                kv.split("=", 1) for kv in r["acl_source"].split() if "=" in kv
            )
            if set(opts) != {"inherit_option", "set_option"}:
                raise Refused(
                    "a membership row does not carry exactly inherit_option and "
                    "set_option; refusing"
                )
            members.append((member, grp, r["grantor"], r["is_grantable"],
                            opts["inherit_option"], opts["set_option"]))
        # 'existence' rows are advisory and carry no state to verify
    for _, opt in [(m[0], m[3]) for m in members]:
        sql_bool(opt)
    for m in members:
        sql_bool(m[4]); sql_bool(m[5])
    return sorted(attrs), sorted(members)


def project_role_context(attrs: list[tuple], members: list[tuple],
                         roots: list[str]) -> tuple[list[tuple], list[tuple], list[str]]:
    """Project the forensic role graph to the access-relevant upward closure.

    The capture follows memberships in both directions. Recovery starts at every
    role named by an in-scope ACL, owner or default rule and follows membership
    member -> granted role, because those groups can change a root's access.
    Membership grantors are retained for revocability provenance.

    Downward-only members (for example Supabase's temporary CLI login member of
    postgres) are hosted-platform access state and must not be recreated on a
    disposable restore. This is fact-driven, not a name allowlist: naming such a
    role in any in-scope fact makes it a root and therefore non-excludable.
    """
    attr_by_name: dict[str, tuple] = {}
    for row in attrs:
        if row[0] in attr_by_name:
            raise Refused(f"duplicate section H attributes for role {row[0]!r}")
        attr_by_name[row[0]] = row

    closure = set(roots)
    while True:
        expanded = set(closure)
        retained = [m for m in members if m[0] in closure]
        expanded.update(m[1] for m in retained)
        expanded.update(m[2] for m in retained)
        if expanded == closure:
            break
        closure = expanded

    missing = sorted(closure - set(attr_by_name))
    if missing:
        raise Refused(
            f"{len(missing)} access-relevant role(s) are absent from section H; "
            "the capture is internally inconsistent"
        )

    projected_attrs = sorted(attr_by_name[name] for name in closure)
    projected_members = sorted(
        m for m in members if m[0] in closure and m[1] in closure
    )
    excluded = sorted(set(attr_by_name) - closure)
    return projected_attrs, projected_members, excluded


def build_scope(rows: list[dict]) -> list[tuple]:
    return sorted(
        (r["object_identity"], r["acl_source"])
        for r in rows if r["section"] == "J. SCHEMA SCOPE"
    )


def collect_roles(edges, owners, def_edges, def_groups) -> list[str]:
    roles: set[str] = set()
    for e in edges:
        roles.update({e[8], e[10]})           # owner, grantor
        if e[9] != "PUBLIC":
            roles.add(e[9])                   # grantee
    roles.update(o[5] for o in owners)
    roles.update(g[0] for g in def_groups)
    for d in def_edges:
        roles.add(d[0])
        if d[3] != "PUBLIC":
            roles.add(d[3])
    roles.discard("")
    return sorted(roles)


# --------------------------------------------------------------------------
# Emit
# --------------------------------------------------------------------------

def insert_block(table: str, cols: list[str], rows: list[tuple], caster) -> str:
    """A complete INSERT statement, or a comment when the section is empty.

    An empty VALUES list is not valid SQL, so a section with no rows emits a
    comment instead. The staging table still exists and is simply empty.
    """
    if not rows:
        return f"-- {table}: the capture contains no rows for this section.\n"
    body = ",\n".join("  (" + ", ".join(caster(r)) + ")" for r in rows)
    return f"insert into {table}\n  ({', '.join(cols)})\nvalues\n{body};\n"


def nullable(v):
    return "null" if v is None else sql_str(v)


def emit(rows, source_path: Path, source_sha: str, template: str):
    owners = build_owners(rows)
    owner_index = {(o[0], o[1]): o[6] for o in owners}
    if len(owner_index) != len(owners):
        raise Refused(
            "E. OWNERSHIP contains two objects with the same class and identity")
    edges = build_edges(rows, owner_index)
    def_groups, def_edges = build_defaults(rows)
    scope = build_scope(rows)
    roles = collect_roles(edges, owners, def_edges, def_groups)
    all_role_attrs, all_role_members = build_role_context(rows)
    role_attrs, role_members, excluded_roles = project_role_context(
        all_role_attrs, all_role_members, roles)
    closure = {a[0] for a in role_attrs}
    missing = sorted(set(roles) - closure)
    if missing:
        raise Refused(
            f"{len(missing)} role(s) are named by the ACL but absent from the "
            "section H role closure; the capture is internally inconsistent"
        )

    section_counts = {}
    for r in rows:
        section_counts[r["section"]] = section_counts.get(r["section"], 0) + 1

    # Only an object whose captured ACL is NULL may end the run holding an
    # explicit ACL byte-equal to its built-in default.
    residual = sorted({(o[0], o[1]) for o in owners if o[6] == "null"})
    workload = {
        "source_rows": len(rows),
        "source_edges": len(edges),
        "source_owned_objects": len(owners),
        "source_default_groups": len(def_groups),
        "source_default_edges": len(def_edges),
        "source_roles": len(roles),
        "source_role_closure": len(role_attrs),
        "source_role_memberships": len(role_members),
        "source_role_context_excluded": len(excluded_roles),
        "replay_grants": len(edges),
        "approved_null_acl_objects": len(residual),
    }

    hdr_counts = "\n".join(
        f"--     {k:<26} {v}" for k, v in sorted(section_counts.items()))
    hdr_workload = "\n".join(
        f"--     {k:<26} {v}" for k, v in workload.items())

    def edge_row(r):
        (cls, ident, sch, nm, rargs, col, own_cls, own_ident, owner,
         grantee, grantor, priv, grantable) = r
        return [sql_str(cls), sql_str(ident), sql_str(sch), sql_str(nm),
                nullable(rargs), nullable(col), sql_str(own_cls), sql_str(own_ident),
                sql_str(owner), sql_str(grantee), sql_str(grantor), sql_str(priv),
                sql_bool(grantable)]

    def own_row(r):
        cls, ident, sch, nm, rargs, owner, state = r
        return [sql_str(cls), sql_str(ident), sql_str(sch), sql_str(nm),
                nullable(rargs), sql_str(owner), sql_str(state)]

    blocks = {
        "@@EDGE_VALUES@@": insert_block(
            "_p2k_src_edge",
            ["cls", "ident", "sch", "nm", "rargs", "col", "own_cls", "own_ident",
             "owner", "grantee", "grantor", "priv", "grantable"],
            edges, edge_row),
        "@@OWN_VALUES@@": insert_block(
            "_p2k_src_own",
            ["cls", "ident", "sch", "nm", "rargs", "owner", "state"],
            owners, own_row),
        "@@DEFGROUP_VALUES@@": insert_block(
            "_p2k_src_defgroup", ["defowner", "objtype", "sch"], def_groups,
            lambda r: [sql_str(r[0]), sql_str(r[1]), sql_str(r[2])]),
        "@@DEFEDGE_VALUES@@": insert_block(
            "_p2k_src_defedge",
            ["defowner", "objtype", "sch", "grantee", "priv", "grantable"],
            def_edges,
            lambda r: [sql_str(r[0]), sql_str(r[1]), sql_str(r[2]), sql_str(r[3]),
                       sql_str(r[4]), sql_bool(r[5])]),
        "@@SCOPE_VALUES@@": insert_block(
            "_p2k_src_scope", ["nspname", "classification"], scope,
            lambda r: [sql_str(r[0]), sql_str(r[1])]),
        "@@ROLEATTR_VALUES@@": insert_block(
            "_p2k_src_roleattr", ["rolname", "attributes"], role_attrs,
            lambda r: [sql_str(r[0]), sql_str(r[1])]),
        "@@ROLEMEMBER_VALUES@@": insert_block(
            "_p2k_src_rolemember",
            ["member", "grp", "grantor", "admin_option", "inherit_option", "set_option"],
            role_members,
            lambda r: [sql_str(r[0]), sql_str(r[1]), sql_str(r[2]),
                       sql_bool(r[3]), sql_bool(r[4]), sql_bool(r[5])]),
        "@@ROLE_VALUES@@": insert_block(
            "_p2k_src_role", ["rolname"], [(r,) for r in roles],
            lambda r: [sql_str(r[0])]),
    }

    out = template
    out = out.replace("@@SOURCE_BASENAME@@", source_path.name)
    out = out.replace("@@SOURCE_SHA@@", source_sha)
    out = out.replace("@@SECTION_COUNTS@@", hdr_counts)
    out = out.replace("@@WORKLOAD_COUNTS@@", hdr_workload)
    out = out.replace("@@EXPECT_EDGES@@", str(len(edges)))
    out = out.replace("@@EXPECT_OWNERS@@", str(len(owners)))
    out = out.replace("@@EXPECT_DEFGROUPS@@", str(len(def_groups)))
    out = out.replace("@@EXPECT_DEFEDGES@@", str(len(def_edges)))
    out = out.replace("@@EXPECT_ROLES@@", str(len(roles)))
    out = out.replace("@@EXPECT_ROLEATTRS@@", str(len(role_attrs)))
    out = out.replace("@@EXPECT_ROLEMEMBERS@@", str(len(role_members)))
    out = out.replace("@@EXPECT_RESIDUAL@@", str(len(residual)))
    for token, block in blocks.items():
        out = out.replace(token, block)
    return out, workload, section_counts, residual, excluded_roles


TEMPLATE_PATH = Path(__file__).with_name("phase_2k_acl_recovery_template.sql")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Generate the Phase 2K ACL recovery artifact (does not execute it)."
    )
    ap.add_argument("--source", required=True, type=Path,
                    help="Phase 2K ACL capture CSV to generate from")
    ap.add_argument("--source-sha256", required=True,
                    help="required SHA-256 of the source capture")
    ap.add_argument("--out", required=True, type=Path,
                    help="path of the SQL artifact to write")
    ap.add_argument("--manifest", required=True, type=Path,
                    help="path of the verification manifest to write")
    ap.add_argument("--label", default="",
                    help="short free-text label recorded in the artifact header")
    ap.add_argument("--capture-query", type=Path,
                    default=Path(__file__).resolve().parents[1]
                    / "supabase" / "discovery" / "phase_2k_acl_capture.sql",
                    help="capture query whose SHA-256 is pinned into the artifact")
    ap.add_argument("--superseded", default="",
                    help="mark the artifact SUPERSEDED with this reason; it is "
                         "then not presented as applicable")
    args = ap.parse_args()

    if any(c in args.label for c in ("\n", "\r", "\x00")):
        print("REFUSED: --label must not contain a newline or NUL; it is "
              "substituted into a SQL comment header and a newline would emit "
              "executable lines", file=sys.stderr)
        return 2

    try:
        template = TEMPLATE_PATH.read_text(encoding="utf-8")
        rows = load_capture(args.source, args.source_sha256)
        sql, workload, sections, residual, excluded_roles = emit(
            rows, args.source, args.source_sha256.lower(), template)
    except Refused as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2

    capture_sha = sha256_file(args.capture_query) if args.capture_query.exists() else "(capture query not found)"
    sql = sql.replace("@@LABEL@@", args.label or "(none)")
    sql = sql.replace("@@CAPTURE_QUERY_SHA@@", capture_sha)
    if args.superseded:
        banner = (
            "-- ###########################################################################\n"
            "-- ###                                                                     ###\n"
            "-- ###   S U P E R S E D E D   -   D O   N O T   A P P L Y                 ###\n"
            "-- ###                                                                     ###\n"
            "-- ###   " + args.superseded[:63].ljust(63) + "   ###\n"
            "-- ###                                                                     ###\n"
            "-- ###   Regenerate from a freshly approved capture before any use. This   ###\n"
            "-- ###   file is retained for review only.                                 ###\n"
            "-- ###                                                                     ###\n"
            "-- ###########################################################################\n"
            "--\n")
    else:
        banner = ""
    sql = sql.replace("@@SUPERSEDED_BANNER@@", banner)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(sql, encoding="utf-8")

    generator_sha = sha256_file(Path(__file__))
    template_sha = sha256_file(TEMPLATE_PATH)
    artifact_sha = sha256_file(args.out)

    lines = [
        "Phase 2K ACL recovery — verification manifest",
        "",
        "This manifest is the review anchor. Re-running the generator on the same",
        "source capture must reproduce the artifact SHA-256 exactly.",
        "",
        f"source_capture              {args.source.name}",
        f"source_capture_sha256       {args.source_sha256.lower()}",
        f"generator                   scripts/{Path(__file__).name}",
        f"generator_sha256            {generator_sha}",
        f"generator_template          scripts/{TEMPLATE_PATH.name}",
        f"generator_template_sha256   {template_sha}",
        f"artifact                    {args.out.name}",
        f"artifact_label              {args.label or '(none)'}",
        f"capture_query               {args.capture_query.name}",
        f"capture_query_sha256        {capture_sha}",
        f"status                      {'SUPERSEDED - ' + args.superseded if args.superseded else 'generated, review pending, NOT applied'}",
        f"artifact_sha256             {artifact_sha}",
        "",
        "Source capture structure",
    ]
    lines += [f"  {k:<26} {v}" for k, v in sorted(sections.items())]
    lines += ["", "Expected workload"]
    lines += [f"  {k:<26} {v}" for k, v in workload.items()]
    lines += [
        "",
        "Expected approved provenance residual",
        "  An object whose captured ACL is NULL may end the run holding an explicit",
        "  ACL byte-equal to its built-in default. Effective privileges are",
        "  identical; only provenance differs. PostgreSQL cannot restore a NULL",
        "  ACL, so this residual is unavoidable and is the ONLY difference the",
        "  artifact's in-transaction verification will accept WITHIN ITS SCOPE.",
        "",
        "  That scope is: ACL edges in schema public, the in-scope default-privilege",
        "  rules, object ownership, and the access-relevant upward role closure",
        "  rooted at every role those facts name. Verification does NOT cover",
        "  downward-only hosted-platform members, RLS state or policies, or",
        "  platform-schema ACLs; those remain separate scope decisions.",
        "",
        "Role-context projection",
        "  The source capture retains the full bidirectional role closure. The",
        "  artifact verifies roots named by in-scope ACL/ownership/default facts,",
        "  their granted roles (member -> group), membership grantors, and edges",
        "  wholly inside that projected set. Downward-only roles are not recreated",
        "  on a restored copy. If an excluded role is named by any in-scope fact in",
        "  a future capture, it becomes a root and exclusion is impossible.",
        f"  excluded_downward_only_roles {len(excluded_roles)}",
    ]
    lines += [f"    {role}" for role in excluded_roles]
    lines += [
        "",
        "  This is the PERMITTED set, derived from the source capture alone. How many",
        "  of them actually drift depends on the target: an object that is NULL on",
        "  both sides is left untouched and does not drift at all. The artifact",
        "  verifies that nothing outside this set differs, and that no object that",
        "  was NULL before the run became explicit during it.",
        "",
        "  A relation and its row type share an identity and are distinguished only",
        "  by class, so both are listed below.",
        f"  permitted_null_acl_objects  {len(residual)}",
    ]
    lines += [f"    {cls:<9} {ident}" for cls, ident in residual]
    lines += [
        "",
        "The artifact is NOT authorized for execution by this manifest. It targets",
        "restored copies only and must never be run against staging or production.",
        "",
    ]
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text("\n".join(lines), encoding="utf-8")

    # Counts and hashes only. No ACL row content is ever printed.
    print(f"  source capture   {args.source.name}")
    print(f"  source sha256    {args.source_sha256.lower()}  (verified)")
    print(f"  generator sha256 {generator_sha}")
    print(f"  template sha256  {template_sha}")
    print(f"  artifact         {args.out}")
    print(f"  artifact sha256  {artifact_sha}")
    print(f"  manifest         {args.manifest}")
    for k, v in workload.items():
        print(f"  {k:<26} {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
