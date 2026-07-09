//+------------------------------------------------------------------+
//|                                                    TC_Master.mq5 |
//|  Trade Copier - Master EA.                                       |
//|                                                                   |
//|  Attach to any chart on the source account. On a timer it        |
//|  publishes a full snapshot of the account's open positions to    |
//|  the shared MT5 "Common" data folder, which every MT5 terminal   |
//|  installed on this machine can read regardless of which account  |
//|  it is logged into. One or more TC_Slave EAs (each in its own    |
//|  separate terminal install, one per destination account) poll    |
//|  that file and copy trades across.                               |
//|                                                                   |
//|  By default this EA only reports state - it never places an      |
//|  order. If MaxTotalRiskPercent or DailyLossLimitPercent are set,  |
//|  it will actively close positions on THIS account (regardless of |
//|  magic number - every open position, since these two settings    |
//|  exist specifically to protect against your own manual trading)  |
//|  when those limits are breached. See docs/ARCHITECTURE.md.       |
//+------------------------------------------------------------------+
#property copyright "Tradecopier_v2"
#property version   "1.00"
#property strict

#include <TC_Common.mqh>
#include <Trade\Trade.mqh>

input string MasterID         = "";   // ID slaves use to find this master. Blank = account login number.
input int    UpdateIntervalMs = 250;  // How often to publish the snapshot (ms)
input long   MagicFilter      = 0;    // Only publish positions with this magic number (0 = publish all)

input double MaxTotalRiskPercent   = 0; // Close the newest position(s) pushing total open risk (across the WHOLE account, any magic) over this % of equity (0 = disabled)
input double DailyLossLimitPercent = 0; // Close every position on this account and block new ones for the rest of the day if today's loss reaches this % (0 = disabled). Auto-resumes the next broker day.

string g_masterId;
CTrade g_trade;

double   g_dayAnchorEquity = 0;
int      g_dayAnchorYear = -1, g_dayAnchorMonth = -1, g_dayAnchorDay = -1;
bool     g_dailyHalted = false;

//+------------------------------------------------------------------+
int OnInit()
{
   g_masterId = (StringLen(MasterID) == 0) ? IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) : MasterID;

   if(UpdateIntervalMs < 50)
   {
      Print("TC_Master: UpdateIntervalMs too small, clamping to 50ms");
      EventSetMillisecondTimer(50);
   }
   else
   {
      EventSetMillisecondTimer(UpdateIntervalMs);
   }

   PublishSnapshot();
   PrintFormat("TC_Master: publishing snapshot for MasterID='%s' every %dms", g_masterId, UpdateIntervalMs);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   CheckDailyLossLimit();
   CheckTotalRiskCap();
   PublishSnapshot();
}

//+------------------------------------------------------------------+
void PublishSnapshot()
{
   SPositionRecord positions[];
   ArrayResize(positions, 0);

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(MagicFilter != 0 && magic != MagicFilter) continue;

      SPositionRecord rec;
      rec.ticket    = ticket;
      rec.symbol    = PositionGetString(POSITION_SYMBOL);
      rec.posType   = (int)PositionGetInteger(POSITION_TYPE);
      rec.volume    = PositionGetDouble(POSITION_VOLUME);
      rec.priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      rec.sl        = PositionGetDouble(POSITION_SL);
      rec.tp        = PositionGetDouble(POSITION_TP);
      rec.magic     = magic;
      rec.timeOpen  = (datetime)PositionGetInteger(POSITION_TIME);
      rec.profit    = PositionGetDouble(POSITION_PROFIT);

      int idx = ArraySize(positions);
      ArrayResize(positions, idx + 1);
      positions[idx] = rec;
   }

   STradeSnapshotHeader header;
   header.login    = AccountInfoInteger(ACCOUNT_LOGIN);
   header.srvTime  = TimeCurrent();
   header.localMs  = (long)GetTickCount64();
   header.balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   header.equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   header.posCount = ArraySize(positions);

   TC_WriteSnapshotAtomic(g_masterId, header, positions);
}

//+------------------------------------------------------------------+
//| Daily loss limit - protects the account from further manual      |
//| trading after a bad day, not just from the copier. Unlike        |
//| TC_Slave's version, this doesn't just do a one-time sweep: while  |
//| the lockout is active it closes ANY position found open on this  |
//| account, every cycle, for the rest of the broker day - since a   |
//| human can keep clicking "buy" immediately after a one-time close.|
//| Resumes automatically the next broker day.                       |
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
         PrintFormat("TC_Master: new broker day - daily loss lockout lifted (anchor equity=%.2f).", g_dayAnchorEquity);
      g_dailyHalted = false;
   }

   if(g_dailyHalted)
   {
      if(PositionsTotal() > 0)
         CloseEveryPosition("daily loss lockout still active today");
      return;
   }

   if(g_dayAnchorEquity <= 0)
      return;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayAnchorEquity - eq) / g_dayAnchorEquity * 100.0;

   if(lossPct >= DailyLossLimitPercent)
   {
      g_dailyHalted = true;
      PrintFormat("TC_Master: DAILY LOSS LIMIT TRIGGERED (today's loss=%.2f%%, limit=%.2f%%). Closing everything; locked out for the rest of today.", lossPct, DailyLossLimitPercent);
      Alert(StringFormat("TC_Master: DAILY LOSS LIMIT TRIGGERED (today's loss=%.2f%%, limit=%.2f%%). Closing everything; locked out for the rest of today.", lossPct, DailyLossLimitPercent));
      CloseEveryPosition("daily loss limit triggered");
   }
}

void CloseEveryPosition(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      PrintFormat("TC_Master: closing ticket #%d - %s.", (int)ticket, reason);
      g_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Total risk cap - looks at EVERY open position on this account    |
//| (any magic, any symbol - deliberately ignores MagicFilter, which |
//| only controls what gets published to slaves) and closes whichever|
//| position(s) push the running total over the cap. A position with |
//| no stop-loss has unmeasurable (effectively unlimited) risk, so   |
//| it's always closed immediately regardless of the running total.  |
//| Oldest positions are kept up to the cap; newest are shed first,  |
//| on the basis that the newest trade is what pushed things over.   |
//+------------------------------------------------------------------+
void CheckTotalRiskCap()
{
   if(MaxTotalRiskPercent <= 0)
      return;

   int total = PositionsTotal();
   if(total == 0)
      return;

   ulong    tickets[];
   datetime times[];
   double   risks[]; // -1 = no SL, an immediate violation regardless of the running total
   ArrayResize(tickets, total);
   ArrayResize(times, total);
   ArrayResize(risks, total);

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
      {
         tickets[i] = 0;
         risks[i] = 0;
         continue;
      }

      tickets[i] = ticket;
      times[i]   = (datetime)PositionGetInteger(POSITION_TIME);
      risks[i]   = TC_ComputePositionRisk(
         PositionGetString(POSITION_SYMBOL),
         (int)PositionGetInteger(POSITION_TYPE),
         PositionGetDouble(POSITION_VOLUME),
         PositionGetDouble(POSITION_PRICE_OPEN),
         PositionGetDouble(POSITION_SL));
   }

   for(int i = 0; i < total; i++)
   {
      if(tickets[i] != 0 && risks[i] < 0)
      {
         PrintFormat("TC_Master: closing ticket #%d - no stop-loss set, risk can't be measured under MaxTotalRiskPercent.", (int)tickets[i]);
         Alert(StringFormat("TC_Master: closing ticket #%d - opened with no stop-loss, not allowed under MaxTotalRiskPercent.", (int)tickets[i]));
         g_trade.PositionClose(tickets[i]);
         tickets[i] = 0;
      }
   }

   // Insertion sort by open time ascending - oldest first. Position counts on a
   // manually-traded account are small, so O(n^2) here is not worth optimizing.
   for(int i = 1; i < total; i++)
   {
      ulong    tk = tickets[i];
      datetime tm = times[i];
      double   rk = risks[i];
      int j = i - 1;
      while(j >= 0 && times[j] > tm)
      {
         tickets[j + 1] = tickets[j];
         times[j + 1]   = times[j];
         risks[j + 1]   = risks[j];
         j--;
      }
      tickets[j + 1] = tk;
      times[j + 1]   = tm;
      risks[j + 1]   = rk;
   }

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxAllowed = equity * MaxTotalRiskPercent / 100.0;
   double running     = 0;

   for(int i = 0; i < total; i++)
   {
      if(tickets[i] == 0)
         continue; // already closed above (no SL)

      running += risks[i];
      if(running > maxAllowed)
      {
         PrintFormat("TC_Master: closing ticket #%d - total open risk %.2f exceeds cap %.2f (%.2f%% of equity %.2f).",
                     (int)tickets[i], running, maxAllowed, MaxTotalRiskPercent, equity);
         Alert(StringFormat("TC_Master: closing ticket #%d - total open risk exceeded the %.2f%% cap.", (int)tickets[i], MaxTotalRiskPercent));
         g_trade.PositionClose(tickets[i]);
         running -= risks[i];
      }
   }
}
