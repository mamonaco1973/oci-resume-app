#!/usr/bin/env python3
"""Generate the oci-resume-app architecture diagram in the lucid style.

Emits a draw.io file matching the house style: 1920x1080 canvas, dashed
navy region frame, rounded white cards with a colored 2px stroke, a 52px
lucide icon, a 22px bold title and 15px grey subtitles, and 2.5px
orthogonal edges with bold 16px labels.

The layout is deliberately laid out as two horizontal bands: the fast
synchronous request path along the top, and the slow asynchronous scoring
path along the bottom, so the thing the project is actually about — the
request returning before the work is done — is visible in the shape.
"""

from urllib.parse import quote

OUT = r"c:\cloudenv\oracle\oci-resume-app\oci-resume-app.drawio"

# ==============================================================================
# Palette — one hue per concern so edges and cards read as a single system
# ==============================================================================

NAVY = "#1A2B4A"    # structure: region, frames, browser
BLUE = "#336791"    # synchronous request path: gateway, api function
GREEN = "#2F8F4E"   # authentication: identity domain
AMBER = "#B5732E"   # the async tier: queue, connector hub
PURPLE = "#7A5CA6"  # the worker and the model call
TEAL = "#2E8B8B"    # persistence: NoSQL, Object Storage
GREY = "#5B6B82"    # subtitle text

BG_SYNC = "#F2F7FB"   # synchronous band tint
BG_ASYNC = "#FDF6EE"  # asynchronous band tint

# ==============================================================================
# Lucide icon paths — 24x24 viewBox, stroked (never filled) so the card's
# accent color carries through via the stroke parameter
# ==============================================================================

ICONS = {
    "cloud": '<path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"/>',
    "browser": '<rect width="20" height="16" x="2" y="4" rx="2"/>'
               '<path d="M10 4v4"/><path d="M2 8h20"/><path d="M6 4v4"/>',
    "route": '<circle cx="6" cy="19" r="3"/>'
             '<path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15"/>'
             '<circle cx="18" cy="5" r="3"/>',
    "shield": '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 '
              '18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 '
              '0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>',
    "code": '<path d="m18 16 4-4-4-4"/><path d="m6 8-4 4 4 4"/>'
            '<path d="m14.5 4-5 16"/>',
    "layers": '<path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 '
              '3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/>'
              '<path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65"/>'
              '<path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"/>',
    "share": '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/>'
             '<circle cx="18" cy="19" r="3"/>'
             '<line x1="8.59" x2="15.42" y1="13.51" y2="17.49"/>'
             '<line x1="15.41" x2="8.59" y1="6.51" y2="10.49"/>',
    "sparkles": '<path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 '
                '1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 '
                '.963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 '
                '.964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1'
                '-.963 0z"/>',
    "database": '<ellipse cx="12" cy="5" rx="9" ry="3"/>'
                '<path d="M3 5V19A9 3 0 0 0 21 19V5"/>'
                '<path d="M3 12A9 3 0 0 0 21 12"/>',
    "drive": '<line x1="22" x2="2" y1="12" y2="12"/>'
             '<path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45'
             '-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>'
             '<line x1="6" x2="6.01" y1="16" y2="16"/>'
             '<line x1="10" x2="10.01" y1="16" y2="16"/>',
}


def icon_uri(name, color):
    """Return a draw.io image= data URI for a lucide glyph in `color`."""
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
        'viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="2" '
        'stroke-linecap="round" stroke-linejoin="round">%s</svg>'
        % (color, ICONS[name])
    )
    return "data:image/svg+xml," + quote(svg, safe="")


cells = []


def esc(html):
    """Escape an HTML label so it survives inside an XML value attribute."""
    return (html.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace('"', "&quot;"))


def card(cid, x, y, w, h, color, icon, title, subs, title_note=""):
    """Emit a rounded accent-stroked card with icon, title and subtitles."""
    cells.append(
        '<mxCell id="%s" value="" style="rounded=1;whiteSpace=wrap;html=1;'
        'fillColor=#FFFFFF;strokeColor=%s;strokeWidth=2;" vertex="1" parent="1">'
        '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
        % (cid, color, x, y, w, h)
    )
    cells.append(
        '<mxCell id="%s_i" value="" style="shape=image;html=1;imageAspect=0;'
        'aspect=fixed;verticalAlign=middle;image=%s" vertex="1" parent="1">'
        '<mxGeometry x="%d" y="%d" width="52" height="52" as="geometry"/></mxCell>'
        % (cid, icon_uri(icon, color), x + 24, y + h // 2 - 26)
    )
    note = ('  <span style="font-size:16px;color:%s">%s</span>'
            % (color, title_note)) if title_note else ""
    body = "".join(
        '<br><span style="font-size:15px;color:%s">%s</span>' % (GREY, s)
        for s in subs
    )
    label = ('<b style="font-size:22px">%s</b>%s%s' % (title, note, body))
    cells.append(
        '<mxCell id="%s_t" value="%s" style="text;html=1;align=left;'
        'verticalAlign=middle;fillColor=none;strokeColor=none;fontColor=%s;" '
        'vertex="1" parent="1">'
        '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
        % (cid, esc(label), NAVY, x + 88, y + 10, w - 104, h - 20)
    )


def container(cid, x, y, w, h, color, label, fill="none", fsize=18,
              dash=False, icon=None):
    """Emit a grouping frame with a top-left label."""
    # Square corners on every frame — a percentage arc balloons on shapes
    # this large and reads as a blob rather than a boundary.
    style = (
        'rounded=0;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;'
        'strokeWidth=%s;fontColor=%s;align=left;verticalAlign=top;spacingTop=12;'
        'spacingLeft=%d;fontStyle=1;fontSize=%d;%s'
        % (fill, color, "2.5" if dash else "2", color,
           58 if icon else 20, fsize,
           "dashed=1;dashPattern=8 6;" if dash else "")
    )
    cells.append(
        '<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
        '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
        % (cid, label, style, x, y, w, h)
    )
    if icon:
        cells.append(
            '<mxCell id="%s_i" value="" style="shape=image;html=1;imageAspect=0;'
            'aspect=fixed;verticalAlign=middle;image=%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="34" height="34" as="geometry"/>'
            '</mxCell>' % (cid, icon_uri(icon, color), x + 16, y + 14)
        )


def edge(cid, src, dst, label, color, ex, ey, nx, ny, dash=False, dot=False,
         width="2.5"):
    """Emit a labelled orthogonal edge between two card ids."""
    style = (
        'edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;strokeColor=%s;'
        'strokeWidth=%s;fontColor=%s;fontSize=16;fontStyle=1;endArrow=classic;'
        'exitX=%s;exitY=%s;exitDx=0;exitDy=0;entryX=%s;entryY=%s;entryDx=0;'
        'entryDy=0;labelBackgroundColor=#FFFFFF;%s'
        % (color, width, color, ex, ey, nx, ny,
           "dashed=1;" if dash else
           ("dashed=1;dashPattern=1 4;endArrow=none;" if dot else ""))
    )
    cells.append(
        '<mxCell id="%s" value="%s" style="%s" edge="1" parent="1" source="%s" '
        'target="%s"><mxGeometry relative="1" as="geometry"/></mxCell>'
        % (cid, label, style, src, dst)
    )


def note(cid, x, y, w, h, text, color=GREY, size=16):
    """Free-floating annotation text.

    whiteSpace=wrap is load-bearing: without it draw.io lays the string out on
    a single line that runs straight across the canvas and through every card
    in its path.
    """
    cells.append(
        '<mxCell id="%s" value="%s" style="text;html=1;whiteSpace=wrap;'
        'align=left;verticalAlign=top;fillColor=none;strokeColor=none;'
        'fontColor=%s;fontSize=%d;fontStyle=2;" vertex="1" parent="1">'
        '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
        % (cid, esc(text), color, size, x, y, w, h)
    )


# ==============================================================================
# Canvas and frames
# ==============================================================================

cells.append('<mxCell id="frame" value="" style="rounded=0;fillColor=#FFFFFF;'
             'strokeColor=none;" vertex="1" parent="1"><mxGeometry x="0" y="0" '
             'width="1920" height="1080" as="geometry"/></mxCell>')

container("region", 360, 55, 1510, 975, NAVY,
          "OCI Region  —  us-ashburn-1", dash=True, fsize=24, icon="cloud")

# Two bands. The split is the point of the diagram: everything above the line
# happens while the user waits; everything below happens after they stop.
container("band_sync", 400, 285, 1430, 215, BLUE,
          "Synchronous  —  returns in milliseconds",
          fill=BG_SYNC, fsize=19)
container("band_async", 400, 575, 1430, 215, AMBER,
          "Asynchronous  —  seconds to minutes",
          fill=BG_ASYNC, fsize=19)

# ==============================================================================
# Cards
# ==============================================================================

card("browser", 60, 335, 270, 150, NAVY, "browser",
     "Browser", ["Static SPA", "PKCE sign-in", "polls for the score"])

card("idp", 430, 120, 400, 130, GREEN, "shield",
     "IAM Identity Domain",
     ["OAuth2 / OIDC + PKCE", "issues the id_token"])

card("apigw", 440, 340, 400, 140, BLUE, "route",
     "API Gateway", ["Validates JWT against JWKS", "20 routes, X-Route header"])

card("api_fn", 900, 340, 400, 140, BLUE, "code",
     "Function: resume-api", ["60s timeout", "writes row, then enqueues"])

card("nosql", 1390, 340, 400, 140, TEAL, "database",
     "NoSQL: resume_app", ["pk / sk + doc JSON", "jobs, resumes, folders, usage"])

card("queue", 440, 630, 400, 140, AMBER, "layers",
     "OCI Queue", ["resume-job-requests", "visibility 900s"])

card("sch", 900, 630, 400, 140, AMBER, "share",
     "Connector Hub", ["x4 — one connector is serial", "batch_size_in_num = 1"])

card("worker", 1390, 630, 400, 140, PURPLE, "code",
     "Function: resume-worker", ["300s timeout, 2 GB", "scrape, extract, score"])

card("genai", 1390, 855, 400, 140, PURPLE, "sparkles",
     "OCI Generative AI", ["xai.grok-4.3", "extract fields, then score"])

card("store", 900, 855, 400, 140, TEAL, "drive",
     "Object Storage", ["backend: resume text, analyses", "web: the SPA itself"])

# ==============================================================================
# Edges
# ==============================================================================

edge("e_https", "browser", "apigw", "HTTPS + Bearer", BLUE, "1", "0.5", "0", "0.5")
edge("e_jwks", "apigw", "idp", "JWKS", GREEN, "0.5", "0", "0.5", "1", dash=True)
edge("e_login", "browser", "idp", "PKCE login", GREEN, "0.5", "0", "0", "0.5",
     dash=True)
edge("e_route", "apigw", "api_fn", "X-Route", BLUE, "1", "0.5", "0", "0.5")
edge("e_row", "api_fn", "nosql", "job row", TEAL, "1", "0.5", "0", "0.5")

edge("e_enq", "api_fn", "queue", "enqueue", AMBER, "0.25", "1", "0.5", "0")
edge("e_poll", "queue", "sch", "poll", AMBER, "1", "0.5", "0", "0.5")
edge("e_invoke", "sch", "worker", "one message", AMBER, "1", "0.5", "0", "0.5")

edge("e_model", "worker", "genai", "two calls", PURPLE, "0.5", "1", "0.5", "0")
edge("e_blob", "worker", "store", "analysis", TEAL, "0", "0.75", "1", "0.5")
edge("e_score", "worker", "nosql", "score + status", TEAL, "0.5", "0", "0.5", "1")


# ==============================================================================
# Emit
# ==============================================================================

doc = (
    '<mxfile host="app.diagrams.net">'
    '<diagram name="oci-resume-app">'
    '<mxGraphModel dx="1920" dy="1080" grid="0" gridSize="10" guides="1" '
    'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
    'pageWidth="1920" pageHeight="1080" math="0" shadow="0">'
    '<root><mxCell id="0"/><mxCell id="1" parent="0"/>'
    + "".join(cells) +
    '</root></mxGraphModel></diagram></mxfile>'
)

with open(OUT, "w", encoding="utf-8") as fh:
    fh.write(doc)

print("wrote", OUT, len(doc), "bytes")
