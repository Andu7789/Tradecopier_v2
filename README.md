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
| `MagicFilter` | Only publish positions with this magic number (0 = all). |

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

Once equity protection triggers, the EA stops opening new trades until it's
restarted — it does not auto-resume.

## Disclaimer

This is trading software that places real orders. Test thoroughly on demo
accounts before running it against a live account, and understand the
lot-sizing, symbol-mapping, and equity-protection settings before you turn
it on. Provided as-is, with no warranty of correctness or fitness for any
particular use.
