#!/usr/bin/env python3
"""Fetch Amtrak route geometry + station coordinates and write compact bundled resources.

Writes:
  Shared/Resources/routes/<slug>.json   -> [[[lat,lon],...], ...]   (segments, DP-simplified ~50 m)
  Shared/Resources/stations.json        -> {"CODE": [lat, lon], ...}

Usage: python3 scripts/fetch_routes.py [tolerance_m]
"""
import json, math, os, re, sys, urllib.parse, urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Shared", "Resources")
TOL = float(sys.argv[1]) if len(sys.argv) > 1 else 50.0


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def simplify(pts, tol):
    if len(pts) < 3:
        return pts
    k = 111320.0
    c = math.cos(math.radians(pts[0][0]))
    xy = [(p[1] * k * c, p[0] * k) for p in pts]
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi - lo < 2:
            continue
        ax, ay = xy[lo]; bx, by = xy[hi]
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        best, bi = 0.0, lo
        for i in range(lo + 1, hi):
            px, py = xy[i]
            t = 0 if l2 == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2))
            d = math.hypot(px - ax - t * dx, py - ay - t * dy)
            if d > best:
                best, bi = d, i
        if best > tol:
            keep[bi] = True
            stack += [(lo, bi), (bi, hi)]
    return [p for p, kp in zip(pts, keep) if kp]


def main():
    os.makedirs(os.path.join(ROOT, "routes"), exist_ok=True)
    names = [r["Name"] for r in get("https://maps.amtrak.com/rttl/js/RoutesList.json")]
    total = 0
    for name in names:
        url = "https://maps.amtrak.com/services/MapDataService/stations/nationalRoute?routeName=" + urllib.parse.quote(name)
        try:
            gj = get(url)
        except Exception as e:
            print("skip", name, e); continue
        segs = []
        for f in gj.get("features", []):
            g = f.get("geometry") or {}
            lines = [g["coordinates"]] if g.get("type") == "LineString" else g.get("coordinates", []) if g.get("type") == "MultiLineString" else []
            for l in lines:
                pts = [[p[1], p[0]] for p in l]
                pts = simplify(pts, TOL)
                if len(pts) > 1:
                    segs.append([[round(a, 5), round(b, 5)] for a, b in pts])
        if not segs:
            print("empty", name); continue
        path = os.path.join(ROOT, "routes", slug(name) + ".json")
        with open(path, "w") as fh:
            json.dump(segs, fh, separators=(",", ":"))
        n = os.path.getsize(path); total += n
        print(f"{name}: {len(segs)} segs, {n/1024:.0f} KB")
    st = get("https://api-v3.amtraker.com/v3/stations")
    out = {k: [round(v["lat"], 5), round(v["lon"], 5)] for k, v in st.items() if "lat" in v and "lon" in v}
    with open(os.path.join(ROOT, "stations.json"), "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    print(f"routes total {total/1024/1024:.2f} MB, {len(out)} stations")


if __name__ == "__main__":
    main()
