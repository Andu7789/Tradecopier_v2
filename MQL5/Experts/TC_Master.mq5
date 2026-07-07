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
//|  This EA does not place or modify any orders itself - it only    |
//|  reports state.                                                  |
//+------------------------------------------------------------------+
#property copyright "Tradecopier_v2"
#property version   "1.00"
#property strict

#include <TC_Common.mqh>

input string MasterID         = "";   // ID slaves use to find this master. Blank = account login number.
input int    UpdateIntervalMs = 250;  // How often to publish the snapshot (ms)
input long   MagicFilter      = 0;    // Only publish positions with this magic number (0 = publish all)

string g_masterId;

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
