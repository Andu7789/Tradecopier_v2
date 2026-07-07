# Architecture

## Transport: the shared Common data folder

Every MT5 terminal installed on a Windows machine shares one "Common" data
folder — `%APPDATA%\MetaQuotes\Terminal\Common\Files` — independent of the
terminal's own install path or which account is logged in. `FileOpen(...,
FILE_COMMON)` in MQL5 reads/writes there. This is what lets a master EA
running in *terminal install A, account 1001* hand data to a slave EA
running in *terminal install B, account 2002*, on the same machine, with no
sockets, DLLs, or network calls.

## Snapshot file (master → slaves)

Filename: `TC_Master_<MasterID>.snap` (Common folder).

Written on a timer, always as a full snapshot (not a delta) — this makes
the format self-healing: a slave that starts mid-session, or missed a few
cycles, just reads current truth on the next successful read. It's written
to a `.tmp` file first, then `FileMove`d over the real filename, so a slave
never observes a half-written file (MQL5 doesn't guarantee true atomic
rename, but flush-close-then-rename keeps the exposure window effectively
zero for a file this small).

```
TC2|<login>|<serverTime>|<localMs>|<balance>|<equity>|<posCount>
P|<ticket>|<symbol>|<type 0=buy/1=sell>|<volume>|<priceOpen>|<sl>|<tp>|<magic>|<openTime>|<profit>
P|...
```

`profit` is the position's current floating P/L (`POSITION_PROFIT`), included for
display purposes only — it's not read by the slave's diff algorithm.

`localMs` is `GetTickCount64()` — milliseconds since the *machine* booted,
not broker server time. It's the field slaves use for staleness checks.
Broker server time isn't safe for that: master and slave accounts can be
on different brokers with different server timezones, so comparing
`serverTime` across them can look "stale" (or falsely fresh) by hours even
when both EAs are running fine. Since master and slave always run on the
same physical machine by design, `GetTickCount64()` is directly comparable
between the two processes.

## Slave status file (slave → dashboard)

Filename: `TC_Slave_<MasterID>_<slaveLogin>.status` (Common folder). Written
by `TC_Slave.mq5` on the same timer as its copy cycle, and *always* written
even on cycles where no copying happened (no master data, stale master
data, halted) so it acts as a heartbeat. This is what lets the web
dashboard (`webapp/`) show every slave's live equity, halted state, and
mirrored positions by reading only the Common folder — it never needs to
know about each terminal's separate (per-install) local `Files` folder.

```
TCSTAT1|<login>|<localMs>|<balance>|<equity>|<peakEquity>|<halted 0/1>|<masterLinkMs>|<mappedCount>
S|<masterTicket>|<slaveTicket>|<symbol>|<volume>|<sl>|<tp>|<profit>
S|...
```

`profit` is the slave position's current floating P/L, looked up fresh each
publish cycle — same display-only role as the master snapshot's `profit` field.

`masterLinkMs` is how old the master snapshot was (in machine-clock ms) the
last time this slave successfully read it, or `-1` if it has never seen a
master snapshot at all. The dashboard itself determines file freshness
from each file's own mtime rather than parsing `localMs`, so it works the
same regardless of what host it's read from.

## Ticket map (per slave, local disk)

Filename: `TC_Slave_<MasterID>_<slaveLogin>_map.dat`, in that terminal's
own (non-Common) `Files` folder — deliberately *not* shared, since each
destination account's map is only meaningful to that account.

```
TCMAP1
M|<masterTicket>|<slaveTicket>|<slaveSymbol>|<lastMasterVolume>|<lastSl>|<lastTp>
M|...
```

Reloaded on `OnInit` (so restarting the terminal/EA doesn't lose track of
open positions), and any entry whose slave ticket no longer resolves to an
open position is dropped at load time.

## Diff algorithm (per slave, each timer tick)

1. Run equity protection checks first (independent of master data).
2. Read the master's snapshot. If it's missing or unparseable, do nothing
   this cycle.
3. If `now (localMs) - snapshot.localMs > MaxStaleSeconds`, treat the master
   as offline and do nothing this cycle (no opens, closes, or modifies) —
   better to freeze than to act on stale data.
4. For every position in the snapshot (after magic/blacklist filtering):
   - **Not in the ticket map** → open a mirrored position, add the mapping.
   - **In the ticket map**, volume decreased → partial close the
     proportional fraction on the slave side.
   - **In the ticket map**, volume increased → re-baseline only (adding to
     a position isn't mirrored — no pyramiding support).
   - **In the ticket map**, SL and/or TP differ from what's recorded →
     modify the slave position to match (swapped if `ReverseTrade` is on).
5. For every mapped entry whose master ticket is no longer present in the
   snapshot at all → the master closed it → close the slave position and
   drop the mapping.
6. Persist the updated ticket map to disk.

`ReverseTrade` flips buy↔sell for the open direction. Because the
direction is inverted, what was the stop-loss level for the original
position isn't the stop-loss level for the mirrored one — it's the
take-profit level (and vice versa), since SL/TP are always relative to the
position's own direction. The EA swaps them accordingly whenever it copies
SL/TP.

## Lot sizing

`LOT_FIXED` and `LOT_MULTIPLIER` are direct (master volume × constant).
`LOT_BALANCE_RATIO` / `LOT_EQUITY_RATIO` scale by the ratio of the slave
account's current balance/equity to the master's balance/equity *at
snapshot time* (published in the snapshot header), times `LotMultiplier` —
this is how differently-capitalized destination accounts can follow the
same master proportionally to their own size rather than copying raw lots.

## Equity protection

Each slave independently tracks its own peak equity since the EA started.
If equity drops to/below `EquityFloor`, or drawdown from that peak reaches
`MaxDrawdownPercent`, the EA halts and stops opening *new* copied trades
(it still processes closes/modifies for positions it already opened,
unless `CloseAllOnEquityBreach` force-closes everything immediately). It
does not auto-resume — a deliberate restart is required, so a breach
always gets human attention.

## Explicitly out of scope

- Pending orders (limit/stop) are not copied — positions only.
- Pyramiding (mirroring additions to an already-copied position) is not
  supported; only the initial open, SL/TP changes, partial closes, and
  the final close are mirrored.
