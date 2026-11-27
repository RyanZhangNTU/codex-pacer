"""Render the roadmap data into a light and a dark SVG card."""
import json
import sys
from html import escape
from pathlib import Path

THEMES = {
    "light": {
        "bg": "#ffffff", "border": "#d0d7de", "text": "#1f2328", "muted": "#59636e",
        "subtle": "#818b98", "track": "#e6eaef", "grid": "#eaeef2", "band": "#f6f8fa",
        "ship": "#1a7f37", "progress": "#0969da", "next": "#8250df",
        "ship_soft": "#dafbe1", "progress_soft": "#ddf4ff", "next_soft": "#fbefff",
    },
    "dark": {
        "bg": "#0d1117", "border": "#30363d", "text": "#e6edf3", "muted": "#9198a1",
        "subtle": "#6e7681", "track": "#262c36", "grid": "#1c2129", "band": "#151b23",
        "ship": "#3fb950", "progress": "#4493f8", "next": "#ab7df8",
        "ship_soft": "#12261e", "progress_soft": "#121d2f", "next_soft": "#1e1a2e",
    },
}

FONT = ("-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', 'PingFang SC', "
        "'Hiragino Sans GB', 'Microsoft YaHei', Helvetica, Arial, sans-serif")
MONO = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace"

W = 960
PAD = 32
X0, X1 = 412, 928          # stage area
HEADER_H = 128
COLHEAD_H = 52
SECTION_H = 40
ROW_H = 54
FOOTER_H = 52


def text(x, y, s, size, fill, weight=400, anchor="start", family=FONT, extra=""):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{family}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}"{extra}>{escape(s)}</text>')


def render(data, theme_name):
    t = THEMES[theme_name]
    stages = data["stages"]
    n = len(stages)
    colw = (X1 - X0) / n
    cx = [X0 + (i + 0.5) * colw for i in range(n)]

    rows = sum(len(g["items"]) for g in data["groups"])
    H = HEADER_H + COLHEAD_H + SECTION_H * len(data["groups"]) + ROW_H * rows + FOOTER_H
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
           f'role="img" aria-label="Codex Pacer roadmap">',
           f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="16" fill="{t["bg"]}" stroke="{t["border"]}"/>']

    # Header
    out.append(text(PAD, 46, "CODEX PACER", 12, t["muted"], 600, extra=' letter-spacing="1.6"'))
    out.append(f'<text x="{PAD}" y="86" font-family="{FONT}" font-size="30" font-weight="700" fill="{t["text"]}">'
               f'路线图<tspan font-weight="400" fill="{t["subtle"]}" dx="12">Roadmap</tspan></text>')

    stats_x = W - PAD
    stat_w = 128
    for idx, g in enumerate(reversed(data["groups"])):
        x = stats_x - idx * stat_w
        color = t[g["key"]]
        out.append(text(x, 70, str(len(g["items"])), 30, color, 700, "end"))
        out.append(text(x, 92, g["title"], 13, t["text"], 600, "end"))
        out.append(text(x, 109, g["subtitle"], 11, t["muted"], 400, "end"))

    y = HEADER_H
    out.append(f'<line x1="0" y1="{y}" x2="{W}" y2="{y}" stroke="{t["border"]}"/>')

    # Column headers
    out.append(f'<rect x="1" y="{y+0.5}" width="{W-2}" height="{COLHEAD_H-0.5}" fill="{t["band"]}"/>')
    out.append(text(PAD, y + 31, "事项", 13, t["text"], 600))
    out.append(text(PAD + 32, y + 31, "Item", 11, t["muted"]))
    for i, (zh, en) in enumerate(stages):
        out.append(text(cx[i], y + 25, zh, 13, t["text"], 600, "middle"))
        out.append(text(cx[i], y + 41, en, 11, t["muted"], 400, "middle"))
    y += COLHEAD_H
    out.append(f'<line x1="0" y1="{y}" x2="{W}" y2="{y}" stroke="{t["border"]}"/>')

    grid_top = y
    body = []
    for g in data["groups"]:
        color, soft = t[g["key"]], t[g["key"] + "_soft"]
        # Section header
        body.append(f'<rect x="{PAD-10}" y="{y+9}" width="{W-2*PAD+20}" height="{SECTION_H-14}" rx="7" fill="{soft}"/>')
        body.append(f'<circle cx="{PAD+4}" cy="{y+22}" r="4" fill="{color}"/>')
        body.append(f'<text x="{PAD+16}" y="{y+26.5}" font-family="{FONT}" font-size="13" font-weight="600" fill="{color}">'
                    f'{escape(g["title"])}<tspan font-weight="400" fill="{t["muted"]}" font-size="12" dx="8">'
                    f'{escape(g["subtitle"])}</tspan></text>')
        y += SECTION_H
        for item in g["items"]:
            mid = y + 30
            body.append(text(PAD, y + 24, item["title"], 14, t["text"], 600))
            body.append(text(PAD, y + 42, item["en"], 12, t["muted"]))
            if item["refs"]:
                body.append(text(X0 - 24, y + 24, "  ".join(item["refs"]), 12, t["subtle"], 400, "end", MONO))
            s = item["stage"]
            # Stepper
            body.append(f'<line x1="{cx[0]:.1f}" y1="{mid}" x2="{cx[-1]:.1f}" y2="{mid}" stroke="{t["track"]}" '
                        f'stroke-width="4" stroke-linecap="round"/>')
            if s > 1:
                body.append(f'<line x1="{cx[0]:.1f}" y1="{mid}" x2="{cx[s-1]:.1f}" y2="{mid}" stroke="{color}" '
                            f'stroke-width="4" stroke-linecap="round"/>')
            for i in range(n):
                if i < s - 1:
                    body.append(f'<circle cx="{cx[i]:.1f}" cy="{mid}" r="5" fill="{color}"/>')
                elif i > s - 1:
                    body.append(f'<circle cx="{cx[i]:.1f}" cy="{mid}" r="4.5" fill="{t["bg"]}" '
                                f'stroke="{t["track"]}" stroke-width="2"/>')
            c = cx[s - 1]
            if g["key"] == "progress":
                body.append(f'<circle cx="{c:.1f}" cy="{mid}" r="9" fill="none" stroke="{color}" stroke-width="2">'
                            f'<animate attributeName="r" values="9;17" dur="1.8s" repeatCount="indefinite"/>'
                            f'<animate attributeName="opacity" values="0.6;0" dur="1.8s" repeatCount="indefinite"/>'
                            f'</circle>')
            body.append(f'<circle cx="{c:.1f}" cy="{mid}" r="10" fill="{color}" stroke="{t["bg"]}" stroke-width="3"/>')
            if s == n:
                body.append(f'<path d="M{c-4.2:.1f} {mid+0.2} l2.9 2.9 l5.6 -5.8" fill="none" stroke="{t["bg"]}" '
                            f'stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>')
            else:
                body.append(f'<circle cx="{c:.1f}" cy="{mid}" r="3" fill="{t["bg"]}"/>')
            y += ROW_H
            body.append(f'<line x1="{PAD}" y1="{y}" x2="{W-PAD}" y2="{y}" stroke="{t["grid"]}"/>')

    # Column guides behind the rows
    for i in range(1, n):
        gx = X0 + i * colw
        out.append(f'<line x1="{gx:.1f}" y1="{grid_top}" x2="{gx:.1f}" y2="{y}" stroke="{t["grid"]}" '
                   f'stroke-dasharray="3 4"/>')
    out.extend(body)

    # Footer
    out.append(f'<line x1="0" y1="{y}" x2="{W}" y2="{y}" stroke="{t["border"]}"/>')
    out.append(text(PAD, y + 32, f'最新版本 {data["release"]}  ·  更新于 {data["updated"]}', 12, t["muted"]))
    out.append(text(W - PAD, y + 32, "想要哪项先来？在下面评论告诉我们", 12, t["muted"], 400, "end"))
    out.append("</svg>")
    return "\n".join(out)


def main():
    src = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    data = json.loads(src.read_text(encoding="utf-8"))
    for name in THEMES:
        (out_dir / f"roadmap-{name}.svg").write_text(render(data, name), encoding="utf-8")


if __name__ == "__main__":
    main()
