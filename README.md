# Tradecopier v2

A local, same-machine MT5 trade copier. One **master** EA on a source
account publishes its open positions; one **slave** EA per destination
account reads that data and mirrors opens, closes, SL/TP changes, and
partial closes. Pending orders are not copied.

No cloud service, no VPN, no broker API keys — everything runs through a
snapshot file on disk that every MT5 terminal on the machine can see.

## Architecture

- **Same-machine, multi-terminal.** Each account (master and every
  destination) runs its own separate MT5 terminal installation on the same
  computer. MT5's per-terminal "Common" data folder
  (`%APPDATA%\MetaQuotes\Terminal\Common\Files`) is shared by *every*
  terminal install on the machine, regardless of install path or which
  account is logged in — that's the transport. No sockets, no DLLs, no
  firewall rules.
- **Master EA (`TC_Master.mq5`)** runs on the source account. On a timer it
  writes a full snapshot of the account's open positions to a file in the
  Common folder, using a write-to-temp-then-rename pattern so a slave never
  reads a half-written file.
- **Slave EA (`TC_Slave.mq5`)** runs on each destination account, in its own
  terminal install. On a timer it reads the master's snapshot and **diffs
  it against a locally persisted ticket map** (master ticket → slave
  ticket) to figure out what changed since last cycle:
  - master ticket not in the map yet → open it
  - mapped ticket missing from the new snapshot → master closed it, close it here
  - mapped ticket's SL/TP differs from what's recorded → modify it here
  - mapped ticket's volume shrank → partial-close the proportional amount here
  - This is what lets the copier follow SL/TP edits and partial closes, not
    just opens/closes.
- **Scaling to more destination accounts** is just installing another
  separate MT5 terminal and dropping `TC_Slave.mq5` on a chart in it,
  pointed at the same `MasterID`. There's no hard limit — every slave reads
  the same snapshot file independently.
- The ticket map is persisted locally on each destination terminal
  (`TC_Slave_<MasterID>_<login>_map.dat` in that terminal's own `Files`
  folder, *not* the shared Common folder), so an EA/terminal restart
  doesn't lose track of what it already copied.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the on-disk file
formats and the full diff algorithm.

## Web dashboard (`webapp/`)

A small local, read-only dashboard for watching the copier: master
account(s), every slave's live equity/halted state, and each slave's
currently mirrored positions. It just reads the same Common-folder files
the EAs already publish — it doesn't change any settings (those are still
configured via each EA's MT5 input parameters) and it's bound to
`127.0.0.1` only, not exposed on the network.

```
cd webapp
pip install -r requirements.txt
python app.py
```

Then open `http://127.0.0.1:8787`. If MT5's Common folder isn't at the
default Windows location, point the app at it first:

```
TC_COMMON_FOLDER="C:\Users\you\AppData\Roaming\MetaQuotes\Terminal\Common\Files" python app.py
```

## Setup

1. Install a separate MT5 terminal for the master account and one more per
   destination account (each destination account needs its own terminal
   install on this machine — that's what lets a broker's copy-trading
   agreement across an EA-per-account model, and what lets each slave have
   independent lot-sizing settings).
2. In each terminal, copy `MQL5/Include/TC_Common.mqh` into that terminal's
   `MQL5/Include/` folder, and the relevant EA (`TC_Master.mq5` or
   `TC_Slave.mq5`) from `MQL5/Experts/` into that terminal's `MQL5/Experts/`
   folder, then compile in MetaEditor (F7).
3. On the **master** terminal, attach `TC_Master` to any chart. Set
   `MasterID` to something memorable (defaults to the account login number
   if left blank). Enable **Algo Trading**.
4. On each **destination** terminal, attach `TC_Slave` to any chart. Set
   `MasterID` to the exact same value used on the master. Configure lot
   sizing, symbol mapping, and equity protection per account (see inputs
   below). Enable **Algo Trading**.
5. Make sure "Allow DLL imports" isn't required (it isn't — this uses only
   standard file I/O) and that **Common Files access** isn't disabled by
   your MT5 install; the Common folder is used automatically via the
   `FILE_COMMON` flag.

## `TC_Master` inputs

| Input | Meaning |
|---|---|
| `MasterID` | Identifier slaves use to find this master. Blank = account login number. |
| `UpdateIntervalMs` | How often to publish the snapshot. |
| `MagicFilter` | Only publish positions with this magic number (0 = all). Only affects what gets *published* to slaves. |
| `MaxTotalRiskPercent` | Closes the newest position(s) pushing total open risk over this % of equity (0 = disabled). |
| `DailyLossLimitPercent` | Closes everything and blocks new positions for the rest of the day if today's loss reaches this % (0 = disabled). Auto-resumes the next broker day. |

`MaxTotalRiskPercent` and `DailyLossLimitPercent` are **optional, self-protection
features for the master account itself** — separate from the copier's job of
publishing state. Unlike `MagicFilter`, they look at *every* open position on
the account regardless of what opened it, because they exist specifically to
protect the account from your own manual trading, not just what an EA does.

> **This means the master EA will close your manually-opened trades** if you
> enable either setting and breach it. `MaxTotalRiskPercent` sums up "what
> would I lose if every position's stop-loss got hit" across the whole
> account, and closes the newest position(s) pushing that total over the
> limit — a position with no stop-loss is always closed immediately, since
> its risk can't be measured. `DailyLossLimitPercent` is blunter: once
> today's loss crosses the limit, it closes *everything* and then keeps
> closing anything you open for the rest of the day (checked every
> `UpdateIntervalMs`), resuming automatically the next broker day. Neither
> setting can stop an order before it fills — MT5 gives an EA no way to veto
> a manual click — so what actually happens is the position exists very
> briefly (well under a second, typically) before the EA closes it back out.

## `TC_Slave` inputs

| Input | Meaning |
|---|---|
| `MasterID` | Must exactly match the master's `MasterID`. |
| `PollIntervalMs` | How often to check for changes. |
| `MaxStaleSeconds` | Ignore snapshots older than this (machine clock, not broker server time — protects against a frozen/crashed master or terminal). |
| `MagicFilterMaster` | Only copy master positions with this magic (0 = all). |
| `SymbolBlacklist` | CSV of master symbol names to never copy. |
| `SymbolMap` | CSV `MASTERSYM:SLAVESYM,...` for broker symbol-name differences (e.g. `GOLD:XAUUSD`). |
| `SlaveSymbolSuffix` | Appended to the mapped symbol if missing, e.g. `.a`. |
| `ReverseTrade` | Mirror buys as sells and vice versa (SL/TP are swapped accordingly). |
| `LotMode` | `LOT_FIXED`, `LOT_MULTIPLIER`, `LOT_BALANCE_RATIO`, or `LOT_EQUITY_RATIO`. |
| `FixedLot` / `LotMultiplier` | Sizing parameters for the mode above. |
| `SlaveMagic` | Magic number tagged on every trade this EA opens; also scopes which positions belong to it. |
| `MaxSlippagePoints` | Max slippage allowed on market execution. |
| `EquityFloor` | Halt new copying once account equity drops to/below this (0 = disabled). |
| `MaxDrawdownPercent` | Halt new copying once equity drawdown from this EA's peak reaches this % (0 = disabled). |
| `CloseAllOnEquityBreach` | If true, force-close everything tagged with `SlaveMagic` when equity protection triggers. |
| `DailyLossLimitPercent` | Force-close everything if today's loss (from the equity level first seen on this broker day) reaches this % (0 = disabled). |
| `MaxTotalRiskPercent` | Hard cap on total open risk (see below) as a % of equity (0 = disabled). |

Once `EquityFloor` or `MaxDrawdownPercent` triggers, the EA stops opening new
trades until it's restarted — it does not auto-resume. `DailyLossLimitPercent`
is different: it's a per-day circuit breaker, so it force-closes everything
for the rest of that broker day, then **resumes on its own** at the start of
the next broker day, using that day's opening equity as the new reference
point. (Caveat: if the EA is restarted partway through a day, that day's
reference point becomes whatever equity it had at that moment, not
midnight's — there's no way to recover a day's true opening equity after
the fact.)

`MaxTotalRiskPercent` works differently from the other protections above —
it doesn't watch equity, it gates what's allowed to open in the first place.
Each destination account computes its own "risk" per position as the money
it would lose if that position's stop-loss were hit, then sums that across
every position the EA has open. Before opening a new mirrored trade, it
checks whether adding that trade's risk would push the total over
`MaxTotalRiskPercent`% of current equity — if so, the trade is skipped
entirely (not opened smaller, not queued, just skipped for that cycle; it'll
be retried on the next cycle in case account equity or open risk has since
changed). A master position with no stop-loss is always skipped under this
rule, since there's no way to measure how much it could lose.

## Disclaimer

This is trading software that places real orders. Test thoroughly on demo
accounts before running it against a live account, and understand the
lot-sizing, symbol-mapping, and equity-protection settings before you turn
it on. Provided as-is, with no warranty of correctness or fitness for any
particular use.
