#!/usr/bin/env python3
"""
al.py — instant queries over BC / LS Central symbol packages (.alpackages).

Why it exists: "what buttons does page X have", "which fields are on table 27", "who runs
this page", "what integration events can I subscribe to" are questions the symbol packages
answer completely — offline, without a tenant, without reading source code. This tool parses
every .app in app/.alpackages once, caches the result in SQLite, and answers in milliseconds.

    python tools/al.py index                    # (re)build the cache from .alpackages
    python tools/al.py page 99001452            # page header + full action tree (+ extensions)
    python tools/al.py page "Retail Item List"
    python tools/al.py table 27                 # fields with types and captions
    python tools/al.py object codeunit 5704     # object header + method signatures
    python tools/al.py find "Transfer Order"    # objects whose name matches, across all apps
    python tools/al.py whoruns "Item Card"      # which page actions open this object
    python tools/al.py events "Transfer"        # IntegrationEvent/BusinessEvent publishers
    python tools/al.py stats

Cache: .claude/al-symbols.sqlite — derived data; delete it or run `index` to rebuild.
"""
from __future__ import annotations

import argparse
import io
import json
import re
import sqlite3
import sys
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / ".claude" / "al-symbols.sqlite"
# Both AL workspace layouts: symbols next to the AL project (app/.alpackages, the layout the
# AL extension creates) and symbols at the repo root (used when the repo holds more than the
# AL project). Missing directories are skipped, so listing all of them is harmless.
PACKAGE_DIRS = [
    ROOT / "app" / ".alpackages",
    ROOT / "test" / ".alpackages",
    ROOT / ".alpackages",
]

OBJECT_BUCKETS = {
    "Tables": "table", "Pages": "page", "Codeunits": "codeunit", "Reports": "report",
    "Queries": "query", "XmlPorts": "xmlport", "EnumTypes": "enum", "Interfaces": "interface",
    "PermissionSets": "permissionset", "ControlAddIns": "controladdin",
    "PageExtensions": "pageextension", "TableExtensions": "tableextension",
    "ReportExtensions": "reportextension", "EnumExtensionTypes": "enumextension",
    "PermissionSetExtensions": "permissionsetextension", "Profiles": "profile",
}
ACTION_KIND = {0: "area", 1: "group", 2: "action", 3: "separator", 4: "actionref"}


def _out(s: str) -> None:
    try:
        print(s)
    except UnicodeEncodeError:
        print(s.encode("utf-8", "replace").decode("utf-8", "replace"))


def props(node: dict) -> dict:
    return {p.get("Name"): p.get("Value") for p in node.get("Properties") or []}


def type_str(td) -> str:
    if not isinstance(td, dict):
        return ""
    s = td.get("Name", "?")
    if td.get("Length"):
        s += f"[{td['Length']}]"
    sub = td.get("Subtype")
    if isinstance(sub, dict) and sub.get("Name"):
        s += f' "{sub["Name"]}"'
    if td.get("ArrayDimensions"):
        s = f"array {s}"
    return s


def method_sig(m: dict) -> str:
    ps = ", ".join(f"{p.get('Name')}: {type_str(p.get('TypeDefinition'))}"
                   + (" var" if p.get("IsVar") else "")
                   for p in m.get("Parameters") or [])
    ret = m.get("ReturnTypeDefinition")
    rs = f" -> {type_str(ret)}" if isinstance(ret, dict) and ret.get("Name") else ""
    return f"{m.get('Name')}({ps}){rs}"


def iter_actions(node, path=""):
    """Generic walker: yields (path, action_dict) for every dict found under an 'Actions' key,
    at any depth — covers pages, nested groups and page-extension ActionChanges."""
    if isinstance(node, dict):
        for key, val in node.items():
            if key == "Actions" and isinstance(val, list):
                for a in val:
                    if isinstance(a, dict) and a.get("Name"):
                        yield path, a
                        yield from iter_actions(
                            {k: v for k, v in a.items() if k == "Actions"},
                            f"{path}/{a.get('Name')}" if path else a.get("Name", ""))
            elif isinstance(val, (dict, list)):
                yield from iter_actions(val, path)
    elif isinstance(node, list):
        for item in node:
            yield from iter_actions(item, path)


def collect_buckets(sr: dict) -> dict:
    """Handles both flat layouts and BC24+ Namespaces nesting."""
    coll = {b: [] for b in OBJECT_BUCKETS}

    def walk(node):
        for b in OBJECT_BUCKETS:
            if isinstance(node.get(b), list):
                coll[b].extend(node[b])
        for ns in node.get("Namespaces") or []:
            walk(ns)

    walk(sr)
    return coll


def read_symbol_json(app_path: Path) -> dict | None:
    raw = app_path.read_bytes()
    pk = raw.find(b"PK\x03\x04")
    if pk < 0:
        return None
    try:
        z = zipfile.ZipFile(io.BytesIO(raw[pk:]))
        # The entry is not always at the archive root, and some publishers ship it with a
        # different case (e.g. 'symbolreference.json'), so resolve it by name.
        name = next((n for n in z.namelist()
                     if n.rsplit("/", 1)[-1].lower() == "symbolreference.json"), None)
        if name is None:
            return None
        text = z.read(name).decode("utf-8-sig")
        # Several publishers (all Intelligent Systems packages, for one) pad the entry after
        # the closing brace. json.loads() then dies with "Extra data" and the package looks
        # like it has no symbols at all — raw_decode stops at the end of the first value.
        return json.JSONDecoder().raw_decode(text)[0]
    except (KeyError, zipfile.BadZipFile, json.JSONDecodeError, UnicodeDecodeError):
        return None


def current_packages() -> list[Path]:
    """Every .app across the known package dirs, with byte-identical duplicates dropped.

    A workspace that has both app/.alpackages and test/.alpackages (or a copy at the repo
    root) holds the SAME dependency package more than once. Indexing it twice makes every
    lookup ambiguous — `al.py table 99001473` answers "2 tables match, be more specific"
    with no way to be more specific, because the two rows are the same object. Dedupe on
    (file name, size): same package, indexed once.
    """
    out, seen = [], set()
    for d in PACKAGE_DIRS:
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.app")):
            key = (p.name.lower(), p.stat().st_size)
            if key in seen:
                continue
            seen.add(key)
            out.append(p)
    return out


def build_index() -> None:
    t0 = time.time()
    DB_PATH.parent.mkdir(exist_ok=True)
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.executescript("""
        DROP TABLE IF EXISTS apps; DROP TABLE IF EXISTS objects; DROP TABLE IF EXISTS actions;
        DROP TABLE IF EXISTS fields; DROP TABLE IF EXISTS methods;
        CREATE TABLE apps(app TEXT, publisher TEXT, version TEXT, file TEXT, mtime REAL);
        CREATE TABLE objects(app TEXT, otype TEXT, oid INTEGER, name TEXT, caption TEXT,
                             target TEXT, sourcetable TEXT);
        CREATE TABLE actions(app TEXT, page TEXT, page_id INTEGER, path TEXT, name TEXT,
                             kind TEXT, caption TEXT, tooltip TEXT, runobject TEXT);
        CREATE TABLE fields(app TEXT, table_id INTEGER, table_name TEXT, fid INTEGER,
                            name TEXT, ftype TEXT, caption TEXT);
        CREATE TABLE methods(app TEXT, otype TEXT, oid INTEGER, oname TEXT, mname TEXT,
                             sig TEXT, attrs TEXT);
        CREATE INDEX ix_obj_name ON objects(name COLLATE NOCASE);
        CREATE INDEX ix_obj_id ON objects(otype, oid);
        CREATE INDEX ix_act_page ON actions(page COLLATE NOCASE);
        CREATE INDEX ix_act_run ON actions(runobject COLLATE NOCASE);
        CREATE INDEX ix_fld ON fields(table_id);
        CREATE INDEX ix_m_name ON methods(oname COLLATE NOCASE);
    """)
    for app_path in current_packages():
        sr = read_symbol_json(app_path)
        if not sr:
            _out(f"  skipped (no SymbolReference): {app_path.name}")
            continue
        app = sr.get("Name") or app_path.stem
        cur.execute("INSERT INTO apps VALUES (?,?,?,?,?)",
                    (app, sr.get("Publisher", ""), sr.get("Version", ""),
                     str(app_path), app_path.stat().st_mtime))
        coll = collect_buckets(sr)
        for bucket, otype in OBJECT_BUCKETS.items():
            for obj in coll[bucket]:
                op = props(obj)
                target = obj.get("TargetObject") or op.get("Extends") or ""
                cur.execute("INSERT INTO objects VALUES (?,?,?,?,?,?,?)",
                            (app, otype, obj.get("Id"), obj.get("Name", ""),
                             op.get("Caption") or op.get("CaptionML") or "",
                             target, str(op.get("SourceTable") or "")))
                # fields (tables + tableextensions)
                if otype in ("table", "tableextension"):
                    for f in obj.get("Fields") or []:
                        fp = props(f)
                        cur.execute("INSERT INTO fields VALUES (?,?,?,?,?,?,?)",
                                    (app, obj.get("Id"), obj.get("Name", ""), f.get("Id"),
                                     f.get("Name", ""), type_str(f.get("TypeDefinition")),
                                     fp.get("Caption") or fp.get("CaptionML") or ""))
                # actions (pages + pageextensions; extensions attributed to the target page)
                if otype in ("page", "pageextension"):
                    page_name = obj.get("Name", "") if otype == "page" else (target or obj.get("Name", ""))
                    page_id = obj.get("Id") if otype == "page" else None
                    for path, a in iter_actions(obj):
                        ap = props(a)
                        cur.execute("INSERT INTO actions VALUES (?,?,?,?,?,?,?,?,?)",
                                    (app, page_name, page_id, path, a.get("Name", ""),
                                     ACTION_KIND.get(a.get("Kind"), str(a.get("Kind", ""))),
                                     ap.get("Caption") or ap.get("CaptionML") or "",
                                     (ap.get("ToolTip") or ap.get("Tooltip") or "")[:200],
                                     ap.get("RunObject") or ""))
                # methods (everything that has them — codeunits, tables, pages…)
                for m in obj.get("Methods") or []:
                    attrs = ";".join(a.get("Name", "") for a in m.get("Attributes") or [])
                    cur.execute("INSERT INTO methods VALUES (?,?,?,?,?,?,?)",
                                (app, otype, obj.get("Id"), obj.get("Name", ""),
                                 m.get("Name", ""), method_sig(m), attrs))
        _out(f"  {app_path.name}: ok")
    con.commit()
    n_obj = cur.execute("SELECT count(*) FROM objects").fetchone()[0]
    n_act = cur.execute("SELECT count(*) FROM actions").fetchone()[0]
    n_fld = cur.execute("SELECT count(*) FROM fields").fetchone()[0]
    n_met = cur.execute("SELECT count(*) FROM methods").fetchone()[0]
    con.close()
    _out(f"indexed: {n_obj} objects, {n_act} actions, {n_fld} fields, {n_met} methods "
         f"in {time.time()-t0:.1f}s -> {DB_PATH.name}")


def _connect() -> sqlite3.Connection:
    fresh_needed = not DB_PATH.exists()
    if not fresh_needed:
        con = sqlite3.connect(DB_PATH)
        try:
            known = dict(con.execute("SELECT file, mtime FROM apps"))
        except sqlite3.OperationalError:
            known = {}
        con.close()
        now = {str(p): p.stat().st_mtime for p in current_packages()}
        if known != now:
            _out("(.alpackages changed — rebuilding the symbol cache)")
            fresh_needed = True
    if fresh_needed:
        build_index()
    return sqlite3.connect(DB_PATH)


def resolve_object(con, otype: str | None, key: str) -> list[tuple]:
    """Returns matching rows from objects: by id if numeric, else name (exact, then substring)."""
    tsql, params = "", []
    if otype:
        tsql, params = " AND otype = ?", [otype]
    if key.isdigit():
        return con.execute(f"SELECT * FROM objects WHERE oid = ?{tsql}", [int(key), *params]).fetchall()
    rows = con.execute(f"SELECT * FROM objects WHERE name = ? COLLATE NOCASE{tsql}",
                       [key, *params]).fetchall()
    if rows:
        return rows
    return con.execute(f"SELECT * FROM objects WHERE name LIKE ? COLLATE NOCASE{tsql} LIMIT 30",
                       [f"%{key}%", *params]).fetchall()


def cmd_page(key: str, limit: int) -> None:
    con = _connect()
    rows = resolve_object(con, "page", key)
    if not rows:
        _out(f"no page matches '{key}'")
        return
    if len(rows) > 1:
        _out(f"{len(rows)} pages match — be more specific:")
        for r in rows[:30]:
            _out(f"  page {r[2]:>7}  {r[3]}  [{r[0]}]")
        return
    app, _t, oid, name, caption, _tg, sourcetable = rows[0]
    st = ""
    if sourcetable:
        key2 = sourcetable.strip('" ')
        trows = resolve_object(con, "table", key2)
        st = f'  SourceTable: {key2}' + (f' ("{trows[0][3]}")' if trows and key2.isdigit() else "")
    _out(f'page {oid} "{name}"  Caption="{caption}"  [{app}]{st}\n')
    acts = con.execute(
        """SELECT path, kind, name, caption, runobject, app FROM actions
           WHERE page = ? COLLATE NOCASE ORDER BY app, rowid LIMIT ?""",
        [name, limit + 1]).fetchall()
    more = len(acts) > limit
    shown = acts[:limit]
    _out(f"actions ({len(shown)}{'+' if more else ''}):")
    for path, kind, aname, acap, run, aapp in shown:
        indent = "  " * (path.count("/") + 1) if path else "  "
        run_s = f"  -> {run}" if run else ""
        cap_s = f'  "{acap}"' if acap and acap != aname else ""
        src = "" if aapp == app else f"   [+{aapp}]"
        _out(f"{indent}[{kind}] {aname}{cap_s}{run_s}{src}")
    if more:
        _out(f"  ... more — raise with -k")
    con.close()


def cmd_table(key: str, limit: int) -> None:
    con = _connect()
    rows = resolve_object(con, "table", key)
    if not rows:
        _out(f"no table matches '{key}'")
        return
    if len(rows) > 1:
        _out(f"{len(rows)} tables match — be more specific:")
        for r in rows[:30]:
            _out(f"  table {r[2]:>7}  {r[3]}  [{r[0]}]")
        return
    app, _t, oid, name, caption, _tg, _st = rows[0]
    _out(f'table {oid} "{name}"  Caption="{caption}"  [{app}]\n')
    # Fetch one past the limit so truncation can be REPORTED rather than implied. Printing
    # "fields (60)" for a 132-field table reads as "this table has 60 fields" and sends the
    # reader off to conclude a field does not exist — which is worse than no answer at all.
    total = con.execute(
        """SELECT COUNT(*) FROM fields
           WHERE table_id = ? OR table_name = ? COLLATE NOCASE""", [oid, name]).fetchone()[0]
    flds = con.execute(
        """SELECT fid, name, ftype, caption, app, table_name FROM fields
           WHERE table_id = ? OR table_name = ? COLLATE NOCASE ORDER BY fid LIMIT ?""",
        [oid, name, limit]).fetchall()
    if len(flds) < total:
        _out(f"fields ({len(flds)} shown of {total} — the rest are hidden by --limit {limit}):")
    else:
        _out(f"fields ({total}):")
    for fid, fname, ftype, fcap, fapp, tname in flds:
        ext = "" if fapp == app and tname == name else f"   [+{fapp}]"
        _out(f"  {fid:>6}  {fname:40} {ftype:24} {fcap}{ext}")
    if len(flds) < total:
        _out(f"  … {total - len(flds)} more fields not shown. Re-run with --limit {total} "
             f"before concluding a field does not exist.")
    con.close()


def cmd_object(otype: str, key: str, limit: int) -> None:
    con = _connect()
    rows = resolve_object(con, otype, key)
    if not rows:
        _out(f"no {otype} matches '{key}'")
        return
    if len(rows) > 1:
        _out(f"{len(rows)} matches — be more specific:")
        for r in rows[:30]:
            _out(f"  {r[1]} {r[2]:>7}  {r[3]}  [{r[0]}]")
        return
    app, ot, oid, name, caption, target, _st = rows[0]
    tg = f"  extends: {target}" if target else ""
    _out(f'{ot} {oid} "{name}"  Caption="{caption}"  [{app}]{tg}\n')
    mets = con.execute(
        "SELECT mname, sig, attrs FROM methods WHERE oname = ? COLLATE NOCASE AND otype = ? LIMIT ?",
        [name, ot, limit]).fetchall()
    if mets:
        _out(f"methods ({len(mets)}):")
        for _mn, sig, attrs in mets:
            mark = f"  [{attrs}]" if attrs else ""
            _out(f"  {sig}{mark}")
    con.close()


def cmd_find(text: str, limit: int) -> None:
    con = _connect()
    rows = con.execute(
        """SELECT otype, oid, name, caption, app FROM objects
           WHERE name LIKE ? COLLATE NOCASE ORDER BY otype, name LIMIT ?""",
        [f"%{text}%", limit]).fetchall()
    if not rows:
        _out(f"nothing named like '{text}'")
        return
    for ot, oid, name, cap, app in rows:
        cap_s = f'  "{cap}"' if cap and cap != name else ""
        _out(f"  {ot:16} {oid:>9}  {name}{cap_s}  [{app}]")
    con.close()


def cmd_whoruns(text: str, limit: int) -> None:
    con = _connect()
    rows = con.execute(
        """SELECT page, name, caption, runobject, app FROM actions
           WHERE runobject LIKE ? COLLATE NOCASE ORDER BY page LIMIT ?""",
        [f"%{text}%", limit]).fetchall()
    if not rows:
        _out(f"no action runs anything like '{text}'")
        return
    _out(f"{len(rows)} actions:")
    for page, aname, acap, run, app in rows:
        _out(f'  {page}  ->  [{aname}] "{acap}"  runs {run}  [{app}]')
    con.close()


def cmd_events(text: str, limit: int) -> None:
    con = _connect()
    rows = con.execute(
        """SELECT otype, oname, sig, attrs, app FROM methods
           WHERE attrs LIKE '%Event%' AND (oname LIKE ? COLLATE NOCASE
                 OR mname LIKE ? COLLATE NOCASE)
           ORDER BY oname LIMIT ?""",
        [f"%{text}%", f"%{text}%", limit]).fetchall()
    if not rows:
        _out(f"no event publishers matching '{text}'")
        return
    _out(f"{len(rows)} event publishers:")
    for ot, oname, sig, attrs, app in rows:
        _out(f"  {ot} {oname}  [{attrs}]")
        _out(f"      {sig}   [{app}]")
    con.close()


def cmd_stats() -> None:
    con = _connect()
    _out("apps in cache:")
    for app, pub, ver in con.execute("SELECT app, publisher, version FROM apps ORDER BY app"):
        _out(f"  {app}  {ver}  ({pub})")
    _out("")
    for label, sql in [("objects", "SELECT otype, count(*) FROM objects GROUP BY 1 ORDER BY 2 DESC"),
                       ("", "")]:
        if not label:
            break
        _out(f"{label}:")
        for t, n in con.execute(sql):
            _out(f"  {t:20} {n}")
    for label, table in [("actions", "actions"), ("fields", "fields"), ("methods", "methods")]:
        n = con.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
        _out(f"{label}: {n}")
    con.close()


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description="Instant queries over BC/LSC symbol packages")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("index")
    for name, extra in [("page", None), ("table", None), ("find", None),
                        ("whoruns", None), ("events", None)]:
        p = sub.add_parser(name)
        p.add_argument("key")
        # --limit is the discoverable spelling; -k stays for muscle memory.
        p.add_argument("-k", "--limit", dest="k", type=int,
                       default=120 if name == "page" else 60)
    p = sub.add_parser("object")
    p.add_argument("otype", choices=sorted(set(OBJECT_BUCKETS.values())))
    p.add_argument("key")
    p.add_argument("-k", "--limit", dest="k", type=int, default=80)
    sub.add_parser("stats")
    a = ap.parse_args()
    if a.cmd == "index":
        build_index()
    elif a.cmd == "page":
        cmd_page(a.key, a.k)
    elif a.cmd == "table":
        cmd_table(a.key, a.k)
    elif a.cmd == "object":
        cmd_object(a.otype, a.key, a.k)
    elif a.cmd == "find":
        cmd_find(a.key, a.k)
    elif a.cmd == "whoruns":
        cmd_whoruns(a.key, a.k)
    elif a.cmd == "events":
        cmd_events(a.key, a.k)
    elif a.cmd == "stats":
        cmd_stats()


if __name__ == "__main__":
    main()
