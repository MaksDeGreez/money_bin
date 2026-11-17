"""The static contact sheet the owner uses to check the grouping and write the override file."""

from __future__ import annotations

from html import escape

from receipt_ingest import taxurl

_STYLE = """
:root { color-scheme: light dark; --bg: #f7f7f5; --card: #ffffff; --text: #1c1c1c;
  --muted: #666666; --line: #dddddd; --flag: #a33a00; --tax: #1f6f3a; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #161616; --card: #222222; --text: #eeeeee; --muted: #a0a0a0; --line: #3a3a3a;
    --flag: #ff9a62; --tax: #6fd08c; }
}
body { margin: 0; padding: 1.5rem; background: var(--bg); color: var(--text);
  font: 14px/1.4 -apple-system, "Segoe UI", Roboto, sans-serif; }
h1 { font-size: 1.4rem; margin: 0 0 1rem; }
h2 { font-size: 1.15rem; margin: 2rem 0 0.75rem; border-bottom: 1px solid var(--line); }
.grid { display: flex; flex-wrap: wrap; gap: 0.75rem; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 8px;
  padding: 0.6rem; }
.head { display: flex; gap: 0.5rem; align-items: baseline; flex-wrap: wrap;
  margin-bottom: 0.4rem; }
.id { font-weight: 600; font-family: ui-monospace, Menlo, monospace; }
.qr { font-size: 0.8rem; color: var(--muted); }
.qr.tax { color: var(--tax); }
.flag { font-size: 0.75rem; color: var(--flag); border: 1px solid currentColor; border-radius: 4px;
  padding: 0 0.3rem; }
.parts { display: flex; gap: 0.4rem; }
figure { margin: 0; width: 160px; }
img { width: 160px; height: auto; display: block; border-radius: 4px; background: var(--line); }
figcaption { font-size: 0.72rem; color: var(--muted); word-break: break-all; margin-top: 0.2rem;
  font-family: ui-monospace, Menlo, monospace; }
.excluded { color: var(--muted); font-family: ui-monospace, Menlo, monospace; font-size: 0.8rem; }
"""


def qr_status(payload: str | None) -> str:
    if payload is None:
        return "none"
    return "tax" if taxurl.is_tax_url(payload) else "other"


def render(records: list[dict], flags: dict[str, list[str]], excluded: dict[str, list[str]]) -> str:
    """Build the page. `records` are state records ordered by id; `flags` maps id to its flags."""
    batches = sorted({record["batch"] for record in records} | set(excluded))
    out = [
        "<!DOCTYPE html>",
        '<html lang="en">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>Receipt groups</title>",
        f"<style>{_STYLE}</style>",
        "</head>",
        "<body>",
        "<h1>Receipt groups</h1>",
    ]
    for batch in batches:
        out.append(f"<h2>{escape(batch)}</h2>")
        out.append('<div class="grid">')
        in_batch = [record for record in records if record["batch"] == batch]
        for record in sorted(in_batch, key=lambda r: (r["seq_in_batch"], r["receipt_id"])):
            out.append(_card(record, flags.get(record["receipt_id"], [])))
        out.append("</div>")
        if excluded.get(batch):
            names = ", ".join(escape(name) for name in excluded[batch])
            out.append(f'<p class="excluded">Excluded: {names}</p>')
    out += ["</body>", "</html>", ""]
    return "\n".join(out)


def _card(record: dict, flags: list[str]) -> str:
    payload = (record.get("qr") or {}).get("payload")
    status = qr_status(payload)
    qr_class = "qr tax" if status == "tax" else "qr"
    pieces = [
        '<div class="card">',
        '<div class="head">',
        f'<span class="id">{escape(record["receipt_id"])}</span>',
        f'<span class="{qr_class}">QR: {status}</span>',
    ]
    pieces += [f'<span class="flag">{escape(flag)}</span>' for flag in flags]
    pieces.append("</div>")
    pieces.append('<div class="parts">')
    thumbs = record.get("thumbs") or []
    for index, raw_name in enumerate(record["raw_files"]):
        image = ""
        if index < len(thumbs):
            src = escape(thumbs[index]["file"], quote=True)
            image = f'<img src="{src}" alt="" loading="lazy">'
        pieces.append(f"<figure>{image}<figcaption>{escape(raw_name)}</figcaption></figure>")
    pieces.append("</div>")
    pieces.append("</div>")
    return "\n".join(pieces)
