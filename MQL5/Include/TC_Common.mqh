//+------------------------------------------------------------------+
//|                                                   TC_Common.mqh  |
//|  Shared types and helpers for the TC_Master / TC_Slave EAs.      |
//|                                                                   |
//|  Transport: Master writes a plain-text snapshot of its open      |
//|  positions to the MT5 "Common" data folder (shared by every      |
//|  terminal installed on this machine, regardless of install path  |
//|  or which account is logged into it). Each Slave EA, running in  |
//|  its own separate terminal install, polls that file on a timer   |
//|  and diffs it against the last snapshot it saw to decide what    |
//|  to open/modify/partial-close/close. No pending-order support:   |
//|  positions only.                                                 |
//+------------------------------------------------------------------+
#property strict

//--- one line per open position, pipe-delimited, no embedded pipes/newlines allowed in fields
#define TC_FILE_VERSION   "TC2"
#define TC_FIELD_SEP      "|"

struct STradeSnapshotHeader
{
   long     login;
   datetime srvTime;   // master broker server time - informational only
   long     localMs;   // GetTickCount64() on the shared machine clock - used for staleness checks,
                        // since master/slave brokers can report different server times/timezones
                        // even though both EAs run on the same physical machine.
   double   balance;
   double   equity;
   int      posCount;
};

struct SPositionRecord
{
   ulong    ticket;
   string   symbol;
   int      posType;   // 0 = POSITION_TYPE_BUY, 1 = POSITION_TYPE_SELL
   double   volume;
   double   priceOpen;
   double   sl;
   double   tp;
   long     magic;
   datetime timeOpen;
};

//+------------------------------------------------------------------+
//| Small string helpers                                             |
//+------------------------------------------------------------------+
string TC_Join(const string &parts[])
{
   string out = "";
   for(int i = 0; i < ArraySize(parts); i++)
   {
      if(i > 0) out += TC_FIELD_SEP;
      out += parts[i];
   }
   return out;
}

int TC_Split(const string line, string &outParts[])
{
   return StringSplit(line, StringGetCharacter(TC_FIELD_SEP, 0), outParts);
}

//+------------------------------------------------------------------+
//| Snapshot file naming                                              |
//+------------------------------------------------------------------+
string TC_SnapshotFileName(const string masterId)
{
   return "TC_Master_" + masterId + ".snap";
}

string TC_SnapshotTempFileName(const string masterId)
{
   return "TC_Master_" + masterId + ".tmp";
}

//+------------------------------------------------------------------+
//| Write the master's current state to the shared Common folder.    |
//| Writes to a temp file then renames over the real file so a slave |
//| never reads a half-written snapshot.                             |
//+------------------------------------------------------------------+
bool TC_WriteSnapshotAtomic(const string masterId, const STradeSnapshotHeader &header, const SPositionRecord &positions[])
{
   string tmpName = TC_SnapshotTempFileName(masterId);
   string finalName = TC_SnapshotFileName(masterId);

   int handle = FileOpen(tmpName, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("TC_Common: failed to open temp snapshot file '%s', error %d", tmpName, GetLastError());
      return false;
   }

   string headerParts[7];
   headerParts[0] = TC_FILE_VERSION;
   headerParts[1] = IntegerToString(header.login);
   headerParts[2] = IntegerToString((long)header.srvTime);
   headerParts[3] = IntegerToString(header.localMs);
   headerParts[4] = DoubleToString(header.balance, 2);
   headerParts[5] = DoubleToString(header.equity, 2);
   headerParts[6] = IntegerToString(header.posCount);
   FileWriteString(handle, TC_Join(headerParts) + "\r\n");

   for(int i = 0; i < ArraySize(positions); i++)
   {
      string parts[10];
      parts[0] = "P";
      parts[1] = IntegerToString((long)positions[i].ticket);
      parts[2] = positions[i].symbol;
      parts[3] = IntegerToString(positions[i].posType);
      parts[4] = DoubleToString(positions[i].volume, 2);
      parts[5] = DoubleToString(positions[i].priceOpen, 8);
      parts[6] = DoubleToString(positions[i].sl, 8);
      parts[7] = DoubleToString(positions[i].tp, 8);
      parts[8] = IntegerToString(positions[i].magic);
      parts[9] = IntegerToString((long)positions[i].timeOpen);
      FileWriteString(handle, TC_Join(parts) + "\r\n");
   }

   FileClose(handle);

   // best-effort atomic rename: MQL5 has no true atomic rename, but this keeps the
   // window where a reader could see a partial file to essentially zero, since the
   // temp file above is fully flushed and closed before this replaces the live file.
   if(!FileMove(tmpName, FILE_COMMON, finalName, FILE_COMMON | FILE_REWRITE))
   {
      PrintFormat("TC_Common: failed to publish snapshot '%s', error %d", finalName, GetLastError());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Read + parse a master's snapshot file. Returns false if the file |
//| doesn't exist yet (master EA not started / no master with that   |
//| ID) or is malformed.                                             |
//+------------------------------------------------------------------+
bool TC_ReadSnapshot(const string masterId, STradeSnapshotHeader &header, SPositionRecord &positions[])
{
   string finalName = TC_SnapshotFileName(masterId);
   ArrayResize(positions, 0);

   if(!FileIsExist(finalName, FILE_COMMON))
      return false;

   int handle = FileOpen(finalName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
      return false;

   bool headerParsed = false;

   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      if(StringLen(line) == 0)
         continue;

      string parts[];
      int n = TC_Split(line, parts);

      if(!headerParsed)
      {
         if(n < 7 || parts[0] != TC_FILE_VERSION)
         {
            FileClose(handle);
            return false;
         }
         header.login    = (long)StringToInteger(parts[1]);
         header.srvTime  = (datetime)StringToInteger(parts[2]);
         header.localMs  = (long)StringToInteger(parts[3]);
         header.balance  = StringToDouble(parts[4]);
         header.equity   = StringToDouble(parts[5]);
         header.posCount = (int)StringToInteger(parts[6]);
         headerParsed = true;
         continue;
      }

      if(n < 10 || parts[0] != "P")
         continue;

      SPositionRecord rec;
      rec.ticket    = (ulong)StringToInteger(parts[1]);
      rec.symbol    = parts[2];
      rec.posType   = (int)StringToInteger(parts[3]);
      rec.volume    = StringToDouble(parts[4]);
      rec.priceOpen = StringToDouble(parts[5]);
      rec.sl        = StringToDouble(parts[6]);
      rec.tp        = StringToDouble(parts[7]);
      rec.magic     = (long)StringToInteger(parts[8]);
      rec.timeOpen  = (datetime)StringToInteger(parts[9]);

      int idx = ArraySize(positions);
      ArrayResize(positions, idx + 1);
      positions[idx] = rec;
   }

   FileClose(handle);
   return headerParsed;
}

//+------------------------------------------------------------------+
//| Volume normalization to a symbol's step/min/max                  |
//+------------------------------------------------------------------+
double TC_NormalizeVolume(const string symbol, double volume)
{
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0) step = 0.01;

   double normalized = MathRound(volume / step) * step;
   if(normalized < minV) normalized = minV;
   if(maxV > 0 && normalized > maxV) normalized = maxV;

   int digits = 2;
   if(step < 0.01) digits = 3;
   return NormalizeDouble(normalized, digits);
}

//+------------------------------------------------------------------+
//| Comma-separated list lookup helper (symbol blacklist, etc.)      |
//+------------------------------------------------------------------+
bool TC_ListContains(const string csv, const string needle)
{
   if(StringLen(csv) == 0 || StringLen(needle) == 0)
      return false;

   string items[];
   int n = StringSplit(csv, ',', items);
   for(int i = 0; i < n; i++)
   {
      string item = items[i];
      StringTrimLeft(item);
      StringTrimRight(item);
      if(item == needle)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| "MASTERSYM:SLAVESYM,MASTERSYM2:SLAVESYM2" style symbol map        |
//+------------------------------------------------------------------+
string TC_MapSymbol(const string csvMap, const string masterSymbol, const string slaveSuffix)
{
   string mapped = masterSymbol;

   if(StringLen(csvMap) > 0)
   {
      string pairs[];
      int n = StringSplit(csvMap, ',', pairs);
      for(int i = 0; i < n; i++)
      {
         string kv[];
         if(StringSplit(pairs[i], StringGetCharacter(":", 0), kv) == 2)
         {
            string k = kv[0]; StringTrimLeft(k); StringTrimRight(k);
            string v = kv[1]; StringTrimLeft(v); StringTrimRight(v);
            if(k == masterSymbol)
            {
               mapped = v;
               break;
            }
         }
      }
   }

   if(StringLen(slaveSuffix) > 0 && StringFind(mapped, slaveSuffix) < 0)
      mapped += slaveSuffix;

   return mapped;
}
