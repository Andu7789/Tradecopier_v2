//+------------------------------------------------------------------+
//|                                                     TC_Slave.mq5 |
//|  Trade Copier - Slave (destination) EA.                          |
//|                                                                   |
//|  Attach to a chart on a destination account, in its own separate |
//|  terminal install. On a timer it reads the master's snapshot     |
//|  file from the shared MT5 "Common" data folder and diffs it      |
//|  against the ticket map it saved last cycle to decide what to    |
//|  open, partially close, modify (SL/TP), or close on this         |
//|  account. Run one instance of this EA (one terminal install) per |
//|  destination account; all of them read the same master snapshot. |
//|                                                                   |
//|  Pending orders are intentionally not copied - positions only.   |
//+------------------------------------------------------------------+
#property copyright "Tradecopier_v2"
#property version   "1.00"
#property strict

#include <TC_Common.mqh>
#include <Trade\Trade.mqh>

enum ENUM_TC_LOT_MODE
{
   LOT_FIXED,          // Fixed lot size for every copied trade
   LOT_MULTIPLIER,     // masterVolume * LotMultiplier
   LOT_BALANCE_RATIO,  // masterVolume * (slaveBalance / masterBalance) * LotMultiplier
   LOT_EQUITY_RATIO    // masterVolume * (slaveEquity / masterEquity) * LotMultiplier
};

input string          MasterID              = "";     // Must match the MasterID set on TC_Master
input int              PollIntervalMs        = 250;    // How often to check the master snapshot (ms)
input int              MaxStaleSeconds       = 5;       // Ignore snapshots older than this (machine clock) - protects against a frozen/crashed master

input long             MagicFilterMaster     = 0;       // Only copy master positions with this magic (0 = copy all)
input string           SymbolBlacklist       = "";      // CSV of master symbol names to never copy, e.g. "US30,XAUUSD"
input string           SymbolMap             = "";      // CSV "MASTERSYM:SLAVESYM,MASTERSYM2:SLAVESYM2" for broker symbol name differences
input string           SlaveSymbolSuffix     = "";      // Appended to the mapped symbol if not already present, e.g. ".a"
input bool             ReverseTrade          = false;   // Mirror buys as sells and vice versa

input ENUM_TC_LOT_MODE LotMode               = LOT_MULTIPLIER;
input double           FixedLot              = 0.01;    // Used when LotMode = LOT_FIXED
input double           LotMultiplier         = 1.0;     // Used by LOT_MULTIPLIER / LOT_BALANCE_RATIO / LOT_EQUITY_RATIO

input long             SlaveMagic            = 990001;  // Magic tag applied to every trade this EA opens. Used to identify "our" trades for closes/protection sweeps.
input int              MaxSlippagePoints     = 30;

input double           EquityFloor           = 0;       // Halt new copying if account equity drops to/below this (0 = disabled)
input double           MaxDrawdownPercent    = 0;        // Halt new copying if equity drawdown from this EA's peak equity reaches this % (0 = disabled)
input bool             CloseAllOnEquityBreach = false;   // If true, force-close every position tagged with SlaveMagic when the equity protection triggers

input double           DailyLossLimitPercent = 0;        // Force-close everything if today's loss from this morning's starting equity reaches this % (0 = disabled). Auto-resumes the next broker day.
input double           MaxTotalRiskPercent   = 0;        // Hard cap: total risk (sum of potential loss if every SlaveMagic position's SL were hit) must never exceed this % of equity. A new trade that would breach it, or has no SL, is skipped entirely. (0 = disabled)

struct SMapEntry
{
   ulong  masterTicket;
   ulong  slaveTicket;
   string slaveSymbol;
   double lastMasterVolume;
   double lastSl;
   double lastTp;
};

CTrade      g_trade;
SMapEntry   g_map[];
string      g_mapFileName;
double      g_peakEquity;
bool        g_halted = false;
int         g_staleLogThrottle = 0;
long        g_lastMasterAgeMs = -1; // -1 = master snapshot never seen at all

double      g_dayAnchorEquity = 0;      // equity when this broker day was first seen
int         g_dayAnchorYear = -1, g_dayAnchorMonth = -1, g_dayAnchorDay = -1;
bool        g_dailyHalted = false;      // separate from g_halted - resets automatically each new broker day

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(MasterID) == 0)
   {
      Print("TC_Slave: MasterID input must be set to match the TC_Master's MasterID. EA will not run.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_trade.SetExpertMagicNumber(SlaveMagic);
   g_trade.SetDeviationInPoints(MaxSlippagePoints);

   g_mapFileName = "TC_Slave_" + MasterID + "_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "_map.dat";
   LoadMap();

   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_halted = false;

   int interval = (PollIntervalMs < 50) ? 50 : PollIntervalMs;
   EventSetMillisecondTimer(interval);

   PublishStatus();

   PrintFormat("TC_Slave: following MasterID='%s', %d existing mapped position(s) restored.", MasterID, ArraySize(g_map));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveMap();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   RunCopyCycle();
   PublishStatus(); // always publish, even on cycles that skipped copying, so the
                     // dashboard sees a live heartbeat rather than a frozen file.
}

void RunCopyCycle()
{
   CheckEquityProtection();
   CheckDailyLossLimit();

   STradeSnapshotHeader header;
   SPositionRecord masterPositions[];

   if(!TC_ReadSnapshot(MasterID, header, masterPositions))
   {
      g_lastMasterAgeMs = -1;
      return; // master not publishing yet (or wrong MasterID)
   }

   long ageMs = (long)GetTickCount64() - header.localMs;
   g_lastMasterAgeMs = ageMs;

   if(ageMs > (long)MaxStaleSeconds * 1000)
   {
      if(g_staleLogThrottle % 40 == 0)
         PrintFormat("TC_Slave: master snapshot is stale (%dms old, limit %dms) - skipping this cycle.", ageMs, MaxStaleSeconds * 1000);
      g_staleLogThrottle++;
      return;
   }
   g_staleLogThrottle = 0;

   // --- opens / modifies / partial closes -----------------------------------
   for(int i = 0; i < ArraySize(masterPositions); i++)
   {
      SPositionRecord mp = masterPositions[i];

      if(MagicFilterMaster != 0 && mp.magic != MagicFilterMaster)
         continue;
      if(TC_ListContains(SymbolBlacklist, mp.symbol))
         continue;

      int idx = FindMapIndexByMasterTicket(mp.ticket);
      if(idx < 0)
      {
         if(!g_halted && !g_dailyHalted)
            OpenNewSlavePosition(mp, header);
      }
      else
      {
         UpdateExistingSlavePosition(mp, idx);
      }
   }

   // --- closes: anything mapped whose master ticket disappeared -------------
   for(int j = ArraySize(g_map) - 1; j >= 0; j--)
   {
      if(!IsMasterTicketPresent(masterPositions, g_map[j].masterTicket))
      {
         CloseSlavePosition(g_map[j]);
         ArrayRemove(g_map, j, 1);
      }
   }

   SaveMap();
}

//+------------------------------------------------------------------+
//| Publish this slave's live status to the shared Common folder, so |
//| a monitoring tool can see it without touching this terminal's own|
//| (per-install) Files folder.                                      |
//+------------------------------------------------------------------+
void PublishStatus()
{
   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);

   string headerParts[9];
   headerParts[0] = "TCSTAT1";
   headerParts[1] = IntegerToString(login);
   headerParts[2] = IntegerToString((long)GetTickCount64());
   headerParts[3] = DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2);
   headerParts[4] = DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);
   headerParts[5] = DoubleToString(g_peakEquity, 2);
   headerParts[6] = g_halted ? "1" : "0";
   headerParts[7] = IntegerToString(g_lastMasterAgeMs);
   headerParts[8] = IntegerToString(ArraySize(g_map));

   string content = TC_Join(headerParts) + "\r\n";

   for(int i = 0; i < ArraySize(g_map); i++)
   {
      double profit = 0;
      if(PositionSelectByTicket(g_map[i].slaveTicket))
         profit = PositionGetDouble(POSITION_PROFIT);

      string parts[8];
      parts[0] = "S";
      parts[1] = IntegerToString((long)g_map[i].masterTicket);
      parts[2] = IntegerToString((long)g_map[i].slaveTicket);
      parts[3] = g_map[i].slaveSymbol;
      parts[4] = DoubleToString(g_map[i].lastMasterVolume, 2);
      parts[5] = DoubleToString(g_map[i].lastSl, 8);
      parts[6] = DoubleToString(g_map[i].lastTp, 8);
      parts[7] = DoubleToString(profit, 2);
      content += TC_Join(parts) + "\r\n";
   }

   TC_WriteTextAtomic(TC_SlaveStatusFileName(MasterID, login), TC_SlaveStatusTempFileName(MasterID, login), content);
}

//+------------------------------------------------------------------+
//| Lot sizing                                                        |
//+------------------------------------------------------------------+
double ComputeLotSize(double masterVolume, double masterBalance, double masterEquity)
{
   switch(LotMode)
   {
      case LOT_FIXED:
         return FixedLot;

      case LOT_BALANCE_RATIO:
         if(masterBalance <= 0)
            return masterVolume * LotMultiplier;
         return masterVolume * (AccountInfoDouble(ACCOUNT_BALANCE) / masterBalance) * LotMultiplier;

      case LOT_EQUITY_RATIO:
         if(masterEquity <= 0)
            return masterVolume * LotMultiplier;
         return masterVolume * (AccountInfoDouble(ACCOUNT_EQUITY) / masterEquity) * LotMultiplier;

      case LOT_MULTIPLIER:
      default:
         return masterVolume * LotMultiplier;
   }
}

//+------------------------------------------------------------------+
//| Open a new slave position mirroring a newly-seen master position |
//+------------------------------------------------------------------+
void OpenNewSlavePosition(const SPositionRecord &mp, const STradeSnapshotHeader &header)
{
   string slaveSymbol = TC_MapSymbol(SymbolMap, mp.symbol, SlaveSymbolSuffix);
   if(!SymbolSelect(slaveSymbol, true))
   {
      PrintFormat("TC_Slave: symbol '%s' (mapped from '%s') not available, skipping master ticket #%d", slaveSymbol, mp.symbol, (int)mp.ticket);
      return;
   }
   g_trade.SetTypeFillingBySymbol(slaveSymbol);

   int effType = mp.posType;
   if(ReverseTrade) effType = 1 - effType;

   double lots = ComputeLotSize(mp.volume, header.balance, header.equity);
   lots = TC_NormalizeVolume(slaveSymbol, lots);
   if(lots <= 0)
   {
      PrintFormat("TC_Slave: computed lot size <= 0 for master ticket #%d, skipping", (int)mp.ticket);
      return;
   }

   double effSl = ReverseTrade ? mp.tp : mp.sl;
   double effTp = ReverseTrade ? mp.sl : mp.tp;

   double price = (effType == POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(slaveSymbol, SYMBOL_ASK)
                     : SymbolInfoDouble(slaveSymbol, SYMBOL_BID);

   if(MaxTotalRiskPercent > 0)
   {
      double newRisk = ComputePositionRisk(slaveSymbol, effType, lots, price, effSl);
      if(newRisk < 0)
      {
         PrintFormat("TC_Slave: master ticket #%d would open with no stop-loss - skipping, since risk can't be measured under MaxTotalRiskPercent.", (int)mp.ticket);
         return;
      }

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double maxAllowed = equity * MaxTotalRiskPercent / 100.0;
      double existingRisk = ComputeTotalOpenRisk();

      if(existingRisk + newRisk > maxAllowed)
      {
         PrintFormat("TC_Slave: skipping master ticket #%d - would take total open risk to %.2f (existing %.2f + new %.2f), cap is %.2f (%.2f%% of equity %.2f).",
                     (int)mp.ticket, existingRisk + newRisk, existingRisk, newRisk, maxAllowed, MaxTotalRiskPercent, equity);
         return;
      }
   }

   string comment = "TC:" + IntegerToString((long)mp.ticket);
   bool ok = (effType == POSITION_TYPE_BUY)
                ? g_trade.Buy(lots, slaveSymbol, price, effSl, effTp, comment)
                : g_trade.Sell(lots, slaveSymbol, price, effSl, effTp, comment);

   if(!ok)
   {
      PrintFormat("TC_Slave: failed to open %s %s %.2f lots for master ticket #%d - retcode %d (%s)",
                  (effType == POSITION_TYPE_BUY ? "BUY" : "SELL"), slaveSymbol, lots, (int)mp.ticket,
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return;
   }

   // On MT5 a position's ticket equals the ticket of the order that opened it.
   ulong slaveTicket = g_trade.ResultOrder();

   SMapEntry entry;
   entry.masterTicket     = mp.ticket;
   entry.slaveTicket      = slaveTicket;
   entry.slaveSymbol      = slaveSymbol;
   entry.lastMasterVolume = mp.volume;
   entry.lastSl = mp.sl;
   entry.lastTp = mp.tp;

   int idx = ArraySize(g_map);
   ArrayResize(g_map, idx + 1);
   g_map[idx] = entry;

   PrintFormat("TC_Slave: opened %s %s %.2f lots (slave #%d) mirroring master ticket #%d",
               (effType == POSITION_TYPE_BUY ? "BUY" : "SELL"), slaveSymbol, lots, (int)slaveTicket, (int)mp.ticket);
}

//+------------------------------------------------------------------+
//| Diff an existing mapped position: partial close + SL/TP changes  |
//+------------------------------------------------------------------+
void UpdateExistingSlavePosition(const SPositionRecord &mp, int idx)
{
   double volDelta = g_map[idx].lastMasterVolume - mp.volume;

   if(volDelta > 0.0000001)
   {
      double closeFraction = volDelta / g_map[idx].lastMasterVolume;

      if(PositionSelectByTicket(g_map[idx].slaveTicket))
      {
         double slaveVol = PositionGetDouble(POSITION_VOLUME);
         double slaveCloseVol = TC_NormalizeVolume(g_map[idx].slaveSymbol, slaveVol * closeFraction);

         if(slaveCloseVol >= slaveVol)
         {
            g_trade.PositionClose(g_map[idx].slaveTicket);
         }
         else if(slaveCloseVol > 0)
         {
            g_trade.PositionClosePartial(g_map[idx].slaveTicket, slaveCloseVol);
         }
      }
      g_map[idx].lastMasterVolume = mp.volume;
   }
   else if(volDelta < -0.0000001)
   {
      // Master added to the position. Pyramiding into the existing slave
      // position isn't supported yet - just re-baseline so a later partial
      // close is measured against the new (larger) master volume.
      g_map[idx].lastMasterVolume = mp.volume;
   }

   bool slChanged = MathAbs(mp.sl - g_map[idx].lastSl) > 0.0000001;
   bool tpChanged = MathAbs(mp.tp - g_map[idx].lastTp) > 0.0000001;

   if(slChanged || tpChanged)
   {
      double effSl = ReverseTrade ? mp.tp : mp.sl;
      double effTp = ReverseTrade ? mp.sl : mp.tp;

      if(PositionSelectByTicket(g_map[idx].slaveTicket))
         g_trade.PositionModify(g_map[idx].slaveTicket, effSl, effTp);

      g_map[idx].lastSl = mp.sl;
      g_map[idx].lastTp = mp.tp;
   }
}

//+------------------------------------------------------------------+
void CloseSlavePosition(const SMapEntry &entry)
{
   if(PositionSelectByTicket(entry.slaveTicket))
   {
      g_trade.PositionClose(entry.slaveTicket);
      PrintFormat("TC_Slave: closed slave #%d following close of master ticket #%d", (int)entry.slaveTicket, (int)entry.masterTicket);
   }
}

//+------------------------------------------------------------------+
//| Equity protection                                                 |
//+------------------------------------------------------------------+
void CheckEquityProtection()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity)
      g_peakEquity = eq;

   if(g_halted)
      return;

   bool breach = false;
   if(EquityFloor > 0 && eq <= EquityFloor)
      breach = true;

   if(!breach && MaxDrawdownPercent > 0 && g_peakEquity > 0)
   {
      double ddPct = (g_peakEquity - eq) / g_peakEquity * 100.0;
      if(ddPct >= MaxDrawdownPercent)
         breach = true;
   }

   if(breach)
   {
      g_halted = true;
      PrintFormat("TC_Slave: EQUITY PROTECTION TRIGGERED (equity=%.2f, peak=%.2f). New trade copying halted; restart the EA to resume.", eq, g_peakEquity);

      if(CloseAllOnEquityBreach)
         CloseAllManagedPositions();
   }
}

void CloseAllManagedPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != SlaveMagic) continue;
      g_trade.PositionClose(ticket);
   }
   ArrayResize(g_map, 0);
   PrintFormat("TC_Slave: equity protection closed all managed positions.");
}

//+------------------------------------------------------------------+
//| Daily loss limit - unlike EquityFloor/MaxDrawdownPercent, this is |
//| a per-day circuit breaker: it force-closes everything once        |
//| today's loss (from the equity first seen on this broker day)      |
//| crosses the limit, then auto-resumes copying the next broker day. |
//| Note: if the EA is (re)started partway through a day, that day's  |
//| anchor is the equity at that moment, not midnight's equity.       |
//+------------------------------------------------------------------+
void CheckDailyLossLimit()
{
   if(DailyLossLimitPercent <= 0)
      return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.year != g_dayAnchorYear || dt.mon != g_dayAnchorMonth || dt.day != g_dayAnchorDay)
   {
      g_dayAnchorYear   = dt.year;
      g_dayAnchorMonth  = dt.mon;
      g_dayAnchorDay    = dt.day;
      g_dayAnchorEquity = AccountInfoDouble(ACCOUNT_EQUITY);

      if(g_dailyHalted)
         PrintFormat("TC_Slave: new broker day - daily loss limit reset, copying resumed (anchor equity=%.2f).", g_dayAnchorEquity);
      g_dailyHalted = false;
   }

   if(g_dailyHalted || g_dayAnchorEquity <= 0)
      return;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayAnchorEquity - eq) / g_dayAnchorEquity * 100.0;

   if(lossPct >= DailyLossLimitPercent)
   {
      g_dailyHalted = true;
      PrintFormat("TC_Slave: DAILY LOSS LIMIT TRIGGERED (today's loss=%.2f%%, limit=%.2f%%). Closing all managed positions; copying halted until the next broker day.", lossPct, DailyLossLimitPercent);
      CloseAllManagedPositions();
   }
}

//+------------------------------------------------------------------+
//| Monetary risk (potential loss) if this position's SL is hit.      |
//| Returns -1 if there's no SL, since risk can't be measured then.   |
//+------------------------------------------------------------------+
double ComputePositionRisk(const string symbol, int posType, double volume, double priceOpen, double sl)
{
   if(sl == 0)
      return -1;

   ENUM_ORDER_TYPE orderType = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double profit = 0;
   if(!OrderCalcProfit(orderType, symbol, volume, priceOpen, sl, profit))
      return -1;

   return MathAbs(profit);
}

//+------------------------------------------------------------------+
//| Sum of risk across every currently open position tagged with     |
//| SlaveMagic. A position with no SL contributes nothing to the sum |
//| (its risk is unmeasurable) - a known limitation for any position |
//| opened before MaxTotalRiskPercent was enabled.                   |
//+------------------------------------------------------------------+
double ComputeTotalOpenRisk()
{
   double total = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != SlaveMagic) continue;

      double sl = PositionGetDouble(POSITION_SL);
      if(sl == 0) continue;

      double risk = ComputePositionRisk(
         PositionGetString(POSITION_SYMBOL),
         (int)PositionGetInteger(POSITION_TYPE),
         PositionGetDouble(POSITION_VOLUME),
         PositionGetDouble(POSITION_PRICE_OPEN),
         sl);

      if(risk > 0)
         total += risk;
   }
   return total;
}

//+------------------------------------------------------------------+
//| Map helpers                                                       |
//+------------------------------------------------------------------+
int FindMapIndexByMasterTicket(ulong masterTicket)
{
   for(int i = 0; i < ArraySize(g_map); i++)
      if(g_map[i].masterTicket == masterTicket)
         return i;
   return -1;
}

bool IsMasterTicketPresent(const SPositionRecord &positions[], ulong masterTicket)
{
   for(int i = 0; i < ArraySize(positions); i++)
      if(positions[i].ticket == masterTicket)
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| Ticket-map persistence (local terminal Files folder - NOT common,|
//| each destination terminal keeps its own map on disk so an EA/    |
//| terminal restart doesn't lose track of what it already copied)   |
//+------------------------------------------------------------------+
void SaveMap()
{
   int handle = FileOpen(g_mapFileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("TC_Slave: failed to save ticket map '%s', error %d", g_mapFileName, GetLastError());
      return;
   }

   FileWriteString(handle, "TCMAP1\r\n");
   for(int i = 0; i < ArraySize(g_map); i++)
   {
      string parts[7];
      parts[0] = "M";
      parts[1] = IntegerToString((long)g_map[i].masterTicket);
      parts[2] = IntegerToString((long)g_map[i].slaveTicket);
      parts[3] = g_map[i].slaveSymbol;
      parts[4] = DoubleToString(g_map[i].lastMasterVolume, 2);
      parts[5] = DoubleToString(g_map[i].lastSl, 8);
      parts[6] = DoubleToString(g_map[i].lastTp, 8);
      FileWriteString(handle, TC_Join(parts) + "\r\n");
   }
   FileClose(handle);
}

void LoadMap()
{
   ArrayResize(g_map, 0);

   if(!FileIsExist(g_mapFileName))
      return;

   int handle = FileOpen(g_mapFileName, FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;

   bool first = true;
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      if(StringLen(line) == 0)
         continue;

      if(first)
      {
         first = false;
         continue; // header line
      }

      string parts[];
      int n = TC_Split(line, parts);
      if(n < 7 || parts[0] != "M")
         continue;

      SMapEntry entry;
      entry.masterTicket     = (ulong)StringToInteger(parts[1]);
      entry.slaveTicket      = (ulong)StringToInteger(parts[2]);
      entry.slaveSymbol      = parts[3];
      entry.lastMasterVolume = StringToDouble(parts[4]);
      entry.lastSl = StringToDouble(parts[5]);
      entry.lastTp = StringToDouble(parts[6]);

      // Drop stale entries whose slave position no longer exists (e.g. it was
      // closed manually while the terminal was offline) so we don't try to
      // manage a ticket that isn't there.
      if(PositionSelectByTicket(entry.slaveTicket))
      {
         int idx = ArraySize(g_map);
         ArrayResize(g_map, idx + 1);
         g_map[idx] = entry;
      }
   }
   FileClose(handle);
}
