"""Parsers for the pipe-delimited status files TC_Master.mq5 / TC_Slave.mq5
write to MT5's shared Common data folder. See docs/ARCHITECTURE.md for the
exact file formats.
"""
import time
from pathlib import Path
from typing import Optional


def _read_lines(path: Path) -> list[str]:
    text = path.read_text(encoding="ascii", errors="replace")
    return [line for line in text.splitlines() if line]


def parse_master_snapshot(path: Path) -> Optional[dict]:
    lines = _read_lines(path)
    if not lines:
        return None

    header = lines[0].split("|")
    if len(header) < 7 or header[0] != "TC2":
        return None

    positions = []
    for line in lines[1:]:
        f = line.split("|")
        if len(f) < 10 or f[0] != "P":
            continue
        positions.append({
            "ticket": f[1],
            "symbol": f[2],
            "type": "BUY" if f[3] == "0" else "SELL",
            "volume": float(f[4]),
            "priceOpen": float(f[5]),
            "sl": float(f[6]),
            "tp": float(f[7]),
            "magic": f[8],
            "openTime": int(f[9]),
        })

    return {
        "login": header[1],
        "balance": float(header[4]),
        "equity": float(header[5]),
        "posCount": int(header[6]),
        "positions": positions,
        "ageSeconds": round(time.time() - path.stat().st_mtime, 1),
    }


def parse_slave_status(path: Path) -> Optional[dict]:
    lines = _read_lines(path)
    if not lines:
        return None

    header = lines[0].split("|")
    if len(header) < 9 or header[0] != "TCSTAT1":
        return None

    mapped = []
    for line in lines[1:]:
        f = line.split("|")
        if len(f) < 7 or f[0] != "S":
            continue
        mapped.append({
            "masterTicket": f[1],
            "slaveTicket": f[2],
            "symbol": f[3],
            "volume": float(f[4]),
            "sl": float(f[5]),
            "tp": float(f[6]),
        })

    master_link_ms = int(header[7])

    return {
        "login": header[1],
        "balance": float(header[3]),
        "equity": float(header[4]),
        "peakEquity": float(header[5]),
        "halted": header[6] == "1",
        "masterLinkMs": master_link_ms if master_link_ms >= 0 else None,
        "mappedCount": int(header[8]),
        "mapped": mapped,
        "ageSeconds": round(time.time() - path.stat().st_mtime, 1),
    }
