#!/usr/bin/env python3
"""
kb.py — index and search for the local knowledge base (the project's .md files).

Files remain the source of truth; the index is derived and rebuilt at any time.
Indexing is CHUNK-level: every `## heading` section is a separate searchable unit with a
stable anchor, so retrieval returns the exact section, not a 90 KB file.

    python tools/kb.py index                    # (re)build the index
    python tools/kb.py search "awb transfer"    # ranked, diacritics-insensitive, chunk-level
    python tools/kb.py search "..." --scope default   # bc + lscentral only (portable knowledge)
    python tools/kb.py refs 99001452            # reverse lookup: AL object / REQ / BR / endpoint / GUID
    python tools/kb.py check                    # purity + taxonomy + provenance of kb default folders
    python tools/kb.py catalog                  # regenerate kb/catalog.md (one line per fact)
    python tools/kb.py stale --days 60
    python tools/kb.py stats

Scopes from path: kb/bc -> bc | kb/lscentral -> lscentral | kb/client -> client | else project.
'--scope default' = bc,lscentral.  Index: .claude/kb.sqlite (local, gitignored).
"""
from __future__ import annotations

import argparse
import re
import sqlite3
import sys
import time
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / ".claude" / "kb.sqlite"
TAXONOMY = ROOT / "kb" / "taxonomy.yml"
CATALOG = ROOT / "kb" / "catalog.md"
EXCLUDE_PARTS = {".git", ".alpackages", "node_modules", "output", ".snapshots"}
MAX_BODY = 300_000

REF_PATTERNS = [
    # accepts Romanian object names and Markdown formatting between type and number
    ("al-object", re.compile(
        r"\b(codeunit|table|tabela|tabelă|page|pagina|report|raport|query|xmlport|enum|interface"
        r"|permissionset|pageextension|tableextension|reportextension|enumextension"
        r"|permissionsetextension)[\s*_`]{1,5}(\d{1,10})\b", re.IGNORECASE)),
    ("req", re.compile(r"\bREQ-\d{1,3}\b")),
    ("br", re.compile(r"\bBR-[A-Z_]{2,12}-\d{1,3}\b")),
    ("endpoint", re.compile(r"/api/[A-Za-z0-9/{}\-_.]{2,60}")),
    ("guid", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")),
    ("wikilink", re.compile(r"\[\[([a-z0-9\-]{3,60})\]\]")),
]
RO2AL = {"pagina": "page", "tabela": "table", "tabelă": "table", "raport": "report"}

CLIENT_MARKERS = re.compile(
    r"(?i)\b(lensa|convex|batretail|bat car|lsretail2"
    r"|8968e750-b330-49f0-a026-49df6b870f02|5f2a98ed-4a23-4b03-b6d4-cf641d2ab754"
    r"|501[0-4][0-9])\b")
PROVENANCE_VALUES = {"observed", "inferred", "vendor-docs"}

FM_KEY = re.compile(r"^([A-Za-z_]+):\s*(.*)$")
FM_TYPE = re.compile(r"^\s+type:\s*(\S+)", re.MULTILINE)
FM_LIST = re.compile(r"^\s*\[(.*)\]\s*$")
H1 = re.compile(r"^#\s+(.+)$", re.MULTILINE)
H2 = re.compile(r"^##\s+(.+)$", re.MULTILINE)


def _out(s: str) -> None:
    try:
        print(s)
    except UnicodeEncodeError:
        print(s.encode("utf-8", "replace").decode("utf-8", "replace"))


def slug(text: str) -> str:
    s = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    s = re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()
    return s[:70]


def scope_of(rel_path: str, fm_scope: str) -> str:
    if fm_scope:
        return fm_scope
    p = rel_path.replace("\\", "/")
    if p.startswith("kb/bc/"):
        return "bc"
    if p.startswith("kb/lscentral/"):
        return "lscentral"
    if p.startswith("kb/client/"):
        return "client"
    return "project"


def expand_scopes(arg: str | None) -> list[str] | None:
    if not arg:
        return None
    out: list[str] = []
    for s in arg.split(","):
        s = s.strip().lower()
        if s == "default":
            out += ["bc", "lscentral"]
        elif s:
            out.append(s)
    return out


def parse_front_matter(text: str) -> dict:
    meta = {"name": "", "description": "", "type": "", "tags": "",
            "status": "", "verified": "", "scope": "", "provenance": ""}
    if not text.startswith("---"):
        return meta
    end = text.find("\n---", 3)
    if end < 0:
        return meta
    block = text[3:end]
    for line in block.splitlines():
        m = FM_KEY.match(line)
        if not m:
            continue
        key, val = m.group(1).lower(), m.group(2).strip()
        if key in ("name", "description", "status", "scope", "provenance"):
            meta[key] = val.strip("\"'")
        elif key in ("verified", "verificat"):
            meta["verified"] = val.strip("\"'")
        elif key in ("tags", "obiecte", "objects", "module"):
            lst = FM_LIST.match(val)
            items = lst.group(1) if lst else val
            meta["tags"] = (meta["tags"] + " " + items.replace(",", " ")).strip()
    t = FM_TYPE.search(block)
    if t:
        meta["type"] = t.group(1)
    return meta


def tag_list(meta: dict) -> list[str]:
    return [t for t in re.split(r"[\s,]+", meta["tags"]) if t]


def split_chunks(text: str) -> list[tuple[str, str, str]]:
    """Returns [(anchor, heading, chunk_body)]. Preamble gets anchor ''."""
    matches = list(H2.finditer(text))
    if not matches:
        return [("", "", text[:MAX_BODY])]
    chunks = []
    pre = text[:matches[0].start()]
    if pre.strip():
        chunks.append(("", "", pre[:MAX_BODY]))
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        heading = m.group(1).strip()
        chunks.append((slug(heading), heading, text[m.start():end][:MAX_BODY]))
    return chunks


def iter_md_files():
    for p in ROOT.rglob("*.md"):
        if any(part in EXCLUDE_PARTS for part in p.parts):
            continue
        yield p


def build_index() -> None:
    t0 = time.time()
    DB_PATH.parent.mkdir(exist_ok=True)
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.executescript("""
        DROP TABLE IF EXISTS docs; DROP TABLE IF EXISTS refs; DROP TABLE IF EXISTS meta;
        CREATE VIRTUAL TABLE docs USING fts5(
            path UNINDEXED, scope UNINDEXED, anchor UNINDEXED,
            title, description, tags, heading, body,
            tokenize = "unicode61 remove_diacritics 2"
        );
        CREATE TABLE refs(ref TEXT, kind TEXT, path TEXT, scope TEXT);
        CREATE INDEX refs_ref ON refs(ref);
        CREATE TABLE meta(path TEXT PRIMARY KEY, scope TEXT, type TEXT, status TEXT,
                          verified TEXT, provenance TEXT, mtime REAL, kb REAL);
    """)
    n_files = n_chunks = n_refs = 0
    for p in iter_md_files():
        rel = str(p.relative_to(ROOT))
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        fm = parse_front_matter(text)
        scope = scope_of(rel, fm["scope"])
        h = H1.search(text)
        title = fm["name"] or (h.group(1).strip() if h else p.stem)
        for anchor, heading, body in split_chunks(text):
            cur.execute("INSERT INTO docs VALUES (?,?,?,?,?,?,?,?)",
                        (rel, scope, anchor, title, fm["description"], fm["tags"],
                         heading, body))
            n_chunks += 1
        cur.execute("INSERT INTO meta VALUES (?,?,?,?,?,?,?,?)",
                    (rel, scope, fm["type"], fm["status"], fm["verified"], fm["provenance"],
                     p.stat().st_mtime, round(p.stat().st_size / 1024, 1)))
        seen = set()
        for kind, rx in REF_PATTERNS:
            for m in rx.finditer(text):
                if kind == "al-object":
                    typ = m.group(1).lower()
                    ref = f"{RO2AL.get(typ, typ)} {m.group(2)}"
                elif kind == "wikilink":
                    ref = m.group(1)
                else:
                    ref = m.group(0)
                key = (ref.lower(), kind)
                if key in seen:
                    continue
                seen.add(key)
                cur.execute("INSERT INTO refs VALUES (?,?,?,?)", (ref.lower(), kind, rel, scope))
                n_refs += 1
        n_files += 1
    con.commit()
    con.close()
    _out(f"indexed {n_files} files / {n_chunks} chunks, {n_refs} references, "
         f"in {time.time()-t0:.2f}s -> {DB_PATH.name}")


def _connect() -> sqlite3.Connection:
    if not DB_PATH.exists():
        _out("index missing — building it first")
        build_index()
    return sqlite3.connect(DB_PATH)


def _fts_query(raw: str, mode: str) -> str:
    terms = re.findall(r"\w+", raw, re.UNICODE)
    if not terms:
        return '""'
    if mode == "and":
        return " ".join(f'"{t}"' for t in terms)
    if mode == "or":
        return " OR ".join(f'"{t}"' for t in terms)
    return " OR ".join(f'"{t}"*' for t in terms)


BM25 = "bm25(docs, 0, 0, 0, 6.0, 4.0, 5.0, 5.0, 1.0)"


def search(query: str, limit: int, scopes: list[str] | None) -> None:
    con = _connect()
    cur = con.cursor()
    t0 = time.time()
    scope_sql, extra = "", []
    if scopes:
        scope_sql = f" AND scope IN ({','.join('?' * len(scopes))})"
        extra = scopes
    rows, used = [], ""
    for mode in ("and", "or", "prefix"):
        q = _fts_query(query, mode)
        try:
            rows = cur.execute(
                f"""SELECT path, scope, anchor, title, heading,
                           snippet(docs, 7, '>>', '<<', ' ... ', 14), {BM25}
                    FROM docs WHERE docs MATCH ?{scope_sql}
                    ORDER BY {BM25} LIMIT ?""",
                [q, *extra, limit]).fetchall()
        except sqlite3.OperationalError as e:
            _out(f"FTS error: {e}")
            return
        if rows:
            used = mode
            break
    ms = (time.time() - t0) * 1000
    if not rows:
        _out(f"nothing found for '{query}' ({ms:.0f} ms)")
        return
    _out(f"{len(rows)} results ({used}, {ms:.0f} ms):\n")
    for i, (path, scope, anchor, title, heading, snip, _s) in enumerate(rows, 1):
        loc = f"{path}#{anchor}" if anchor else path
        head = f"  ## {heading}" if heading else ""
        _out(f"{i:2}. [{scope}] {loc}")
        _out(f"    {title}{head}")
        # Python < 3.12 refuses a backslash inside an f-string expression (this broke the
        # script on a 3.9 machine) - compute the snippet first.
        snippet = re.sub(r"\s+", " ", snip).strip()
        _out(f"    {snippet}\n")
    con.close()


def refs_cmd(ref_query: str, limit: int, scopes: list[str] | None) -> None:
    con = _connect()
    q = ref_query.lower().strip()
    scope_sql, extra = "", []
    if scopes:
        scope_sql = f" AND scope IN ({','.join('?' * len(scopes))})"
        extra = scopes
    rows = con.execute(
        f"""SELECT DISTINCT ref, kind, path FROM refs
            WHERE ref LIKE '%' || ? || '%'{scope_sql} ORDER BY ref, path LIMIT ?""",
        [q, *extra, limit]).fetchall()
    if not rows:
        _out(f"no reference containing '{ref_query}'")
        return
    _out(f"{len(rows)} references:\n")
    cur_ref = None
    for ref, kind, path in rows:
        if ref != cur_ref:
            _out(f"[{kind}] {ref}")
            cur_ref = ref
        _out(f"    {path}")
    con.close()


def related(ref_query: str, limit: int) -> None:
    """Poor-man's graph query: 2-hop co-occurrence walk over the refs table.
    Hop 1: files containing the seed reference. Hop 2: what else those files reference,
    ranked by how many seed files share it. Co-occurrence, not causality — it answers
    'what lives in the same context as X', which is the discovery half of 'what breaks'.
    The causal half comes from al.py whoruns/events (standard objects) and from the code
    itself (own extension)."""
    con = _connect()
    q = ref_query.lower().strip()
    files = [r[0] for r in con.execute(
        "SELECT DISTINCT path FROM refs WHERE ref LIKE '%' || ? || '%'", (q,))]
    if not files:
        _out(f"no reference containing '{ref_query}'")
        return
    _out(f"hop 1 — {len(files)} files reference '{ref_query}':")
    for f in files[:15]:
        _out(f"    {f}")
    if len(files) > 15:
        _out(f"    ... +{len(files)-15}")
    ph = ",".join("?" * len(files))
    rows = con.execute(
        f"""SELECT ref, kind, count(DISTINCT path) AS n FROM refs
            WHERE path IN ({ph}) AND ref NOT LIKE '%' || ? || '%'
            GROUP BY ref, kind ORDER BY n DESC, ref LIMIT ?""",
        [*files, q, limit]).fetchall()
    _out("\nhop 2 — co-occurring references (shared files count):")
    for ref, kind, n in rows:
        _out(f"  {n:3}x  [{kind}] {ref}")
    con.close()


def load_taxonomy() -> set[str]:
    if not TAXONOMY.exists():
        return set()
    tags = set()
    for line in TAXONOMY.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\s*-\s*(\S+)", line)
        if m:
            tags.add(m.group(1).lower())
    return tags


def check() -> None:
    """Purity + hygiene of the portable folders. Exit code 1 on violations."""
    taxonomy = load_taxonomy()
    problems = 0
    for sub in ("kb/bc", "kb/lscentral"):
        base = ROOT / sub
        if not base.exists():
            continue
        for p in base.rglob("*.md"):
            if p.name == "README.md":
                continue
            rel = str(p.relative_to(ROOT))
            text = p.read_text(encoding="utf-8", errors="replace")
            for i, line in enumerate(text.splitlines(), 1):
                m = CLIENT_MARKERS.search(line)
                if m:
                    _out(f"CLIENT LEAK   {rel}:{i}  -> '{m.group(0)}'")
                    problems += 1
            fm = parse_front_matter(text)
            tags = tag_list(fm)
            if not tags:
                _out(f"MISSING TAGS  {rel}")
                problems += 1
            elif taxonomy:
                unknown = [t for t in tags if t.lower() not in taxonomy]
                if unknown:
                    _out(f"UNKNOWN TAGS  {rel}  -> {', '.join(unknown)} (add to kb/taxonomy.yml first)")
                    problems += 1
            if not fm["description"]:
                _out(f"MISSING DESC  {rel}")
                problems += 1
            if fm["provenance"] not in PROVENANCE_VALUES:
                _out(f"PROVENANCE    {rel}  -> '{fm['provenance'] or '(missing)'}' "
                     f"(must be one of: {', '.join(sorted(PROVENANCE_VALUES))})")
                problems += 1
    if problems:
        _out(f"\n{problems} problem(s) — the default folders are NOT clean.")
        sys.exit(1)
    _out("kb/bc and kb/lscentral are clean: no client markers; tags in taxonomy; "
         "descriptions and provenance present.")


def catalog() -> None:
    """One line per kb fact — regenerated, never edited by hand."""
    lines = ["# kb catalog — generated by `python tools/kb.py catalog`; do not edit\n"]
    kb_root = ROOT / "kb"
    entries = []
    for p in sorted(kb_root.rglob("*.md")):
        rel = str(p.relative_to(ROOT))
        if p.name in ("README.md", "catalog.md"):
            continue
        fm = parse_front_matter(p.read_text(encoding="utf-8", errors="replace"))
        scope = scope_of(rel, fm["scope"])
        entries.append((scope, fm["name"] or p.stem, fm["description"], fm["tags"], rel))
    for scope, name, desc, tags, rel in sorted(entries):
        rel_from_kb = rel.replace("\\", "/").removeprefix("kb/")
        lines.append(f"- **[{scope}]** [{name}]({rel_from_kb}) — {desc}  ·  `{tags}`")
    CATALOG.write_text("\n".join(lines) + "\n", encoding="utf-8")
    _out(f"catalog: {len(entries)} facts -> {CATALOG.relative_to(ROOT)}")


def stale(days: int) -> None:
    con = _connect()
    cutoff = time.time() - days * 86400
    rows = con.execute(
        "SELECT path, scope, type, verified, mtime FROM meta WHERE mtime < ? ORDER BY mtime",
        (cutoff,)).fetchall()
    if not rows:
        _out(f"nothing older than {days} days — the corpus is fresh")
        return
    _out(f"{len(rows)} files untouched for over {days} days (candidates for re-verification):\n")
    for path, scope, typ, ver, mtime in rows:
        age = int((time.time() - mtime) / 86400)
        extra = f"  verified: {ver}" if ver else ""
        _out(f"  {age:4}d  [{scope:9}][{typ or '-':9}] {path}{extra}")
    con.close()


def stats() -> None:
    con = _connect()
    n_files = con.execute("SELECT count(*) FROM meta").fetchone()[0]
    n_chunks = con.execute("SELECT count(*) FROM docs").fetchone()[0]
    n_refs = con.execute("SELECT count(*) FROM refs").fetchone()[0]
    _out(f"files: {n_files}   chunks: {n_chunks}   extracted references: {n_refs}\n")
    _out("by scope:")
    for scope, n in con.execute("SELECT scope, count(*) FROM meta GROUP BY 1 ORDER BY 2 DESC"):
        _out(f"  {scope:11} {n}")
    _out("\nreferences by kind:")
    for kind, n in con.execute("SELECT kind, count(DISTINCT ref) FROM refs GROUP BY 1 ORDER BY 2 DESC"):
        _out(f"  {kind:11} {n} distinct")
    con.close()


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description="Index and search for the .md knowledge base")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("index")
    p = sub.add_parser("search")
    p.add_argument("query"); p.add_argument("-k", type=int, default=8); p.add_argument("--scope")
    p = sub.add_parser("refs")
    p.add_argument("ref"); p.add_argument("-k", type=int, default=40); p.add_argument("--scope")
    p = sub.add_parser("related")
    p.add_argument("ref"); p.add_argument("-k", type=int, default=20)
    p = sub.add_parser("stale"); p.add_argument("--days", type=int, default=90)
    sub.add_parser("check")
    sub.add_parser("catalog")
    sub.add_parser("stats")
    a = ap.parse_args()
    if a.cmd == "index":
        build_index()
    elif a.cmd == "search":
        search(a.query, a.k, expand_scopes(a.scope))
    elif a.cmd == "refs":
        refs_cmd(a.ref, a.k, expand_scopes(a.scope))
    elif a.cmd == "related":
        related(a.ref, a.k)
    elif a.cmd == "stale":
        stale(a.days)
    elif a.cmd == "check":
        check()
    elif a.cmd == "catalog":
        catalog()
    elif a.cmd == "stats":
        stats()


if __name__ == "__main__":
    main()
