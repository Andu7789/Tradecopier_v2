"""Read-only local dashboard for the TC_Master / TC_Slave EAs.

Watches MT5's shared "Common" data folder for the snapshot/status files the
EAs publish and serves them as JSON + a small browser dashboard. It never
writes anything back - all copier settings still live in each EA's MT5
input parameters.

Run:
    python app.py
    (binds to 127.0.0.1:8787 - localhost only, by design)

Point it at a non-default Common folder with:
    TC_COMMON_FOLDER="/path/to/Common/Files" python app.py
"""
import os
import re
import time
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from parser import parse_master_snapshot, parse_slave_status

DEFAULT_COMMON_FOLDER = os.path.expandvars(r"%APPDATA%\MetaQuotes\Terminal\Common\Files")
COMMON_FOLDER = Path(os.environ.get("TC_COMMON_FOLDER", DEFAULT_COMMON_FOLDER))

MASTER_RE = re.compile(r"^TC_Master_(.+)\.snap$")
SLAVE_RE = re.compile(r"^TC_Slave_(.+)_(\d+)\.status$")

app = FastAPI(title="Tradecopier Dashboard")


@app.get("/api/status")
def api_status():
    masters: dict[str, dict] = {}
    slaves: list[dict] = []

    if COMMON_FOLDER.is_dir():
        for f in COMMON_FOLDER.glob("TC_Master_*.snap"):
            m = MASTER_RE.match(f.name)
            if not m:
                continue
            try:
                data = parse_master_snapshot(f)
            except (OSError, ValueError):
                continue
            if data:
                data["masterId"] = m.group(1)
                masters[m.group(1)] = data

        for f in COMMON_FOLDER.glob("TC_Slave_*.status"):
            m = SLAVE_RE.match(f.name)
            if not m:
                continue
            try:
                data = parse_slave_status(f)
            except (OSError, ValueError):
                continue
            if data:
                data["masterId"] = m.group(1)
                slaves.append(data)

    slaves.sort(key=lambda s: (s["masterId"], s["login"]))

    return JSONResponse({
        "commonFolder": str(COMMON_FOLDER),
        "commonFolderExists": COMMON_FOLDER.is_dir(),
        "masters": sorted(masters.values(), key=lambda m: m["masterId"]),
        "slaves": slaves,
        "serverTime": time.time(),
    })


app.mount("/", StaticFiles(directory=Path(__file__).parent / "static", html=True), name="static")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8787)
