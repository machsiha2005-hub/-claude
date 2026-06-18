//+------------------------------------------------------------------+
//|                                              MicroHunter_EA.mq5  |
//|                        Self-Learning Micro-Account Scalper       |
//|                 10-Second Execution | $10-$50 Accounts           |
//+------------------------------------------------------------------+
#property copyright "MicroHunter EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== EXECUTION ENGINE ==="
input int      InpTimerSeconds     = 5;        // Timer Interval (seconds)
input int      InpTradeCooldownSec = 30;       // Min seconds between entries
input int      InpFastEMA          = 3;        // Fast EMA Period
input int      InpMidEMA           = 9;        // Mid EMA Period
input int      InpSlowEMA          = 21;       // Slow EMA Period
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // Indicator Timeframe

input group "=== RISK MANAGEMENT ==="
input double   InpRiskPercent      = 3.0;      // Risk Per Trade (%)
input double   InpMaxRiskPercent   = 5.0;      // Max Risk Cap (%)
input double   InpMaxSpreadPips    = 0.5;      // Max Allowed Spread (pips)
input int      InpMaxSLPips        = 5;        // Maximum Stop Loss (pips)
input double   InpATRMultiplier    = 1.5;      // ATR Multiplier for SL
input int      InpATRPeriod        = 14;       // ATR Period
input double   InpRRRatio          = 1.5;      // Risk:Reward Ratio for TP

input group "=== SELF-LEARNING FILTER ==="
input int      InpMaxStates        = 200;      // Max Stored States
input double   InpMatchThreshold   = 0.90;     // State Match Threshold (0-1)
input bool     InpEnableLearning   = true;     // Enable Self-Learning

input group "=== PROFIT PROTECTION ==="
input double   InpBEMultiplier     = 1.5;      // Breakeven Trigger (x Spread)
input double   InpTrailLockPct     = 70.0;     // Trail Lock-In Percent (%)
input int      InpMaxPositions     = 1;        // Max Simultaneous Positions

input group "=== SESSION FILTER ==="
input int      InpSessionStartHour = 0;        // Session Start Hour (server)
input int      InpSessionEndHour   = 23;       // Session End Hour (server)

input group "=== SAFETY CIRCUIT BREAKERS ==="
input double   InpMaxDailyLossPct  = 5.0;      // Daily Loss Limit (%)
input int      InpMaxConsecLosses  = 3;        // Pause after N consecutive losses
input double   InpMinMarginLevel   = 300.0;    // Min Margin Level (%)
input double   InpATRSpikeMult     = 2.0;      // Skip if ATR spikes >Nx prev

//+------------------------------------------------------------------+
struct MarketState
  {
   int               trendDirection;
   double            rsi;
   double            atr;
   double            emaDist;
   int               sessionHour;
   double            spread;
  };

CTrade            trade;
CPositionInfo     posInfo;
CAccountInfo      accInfo;
CSymbolInfo       symInfo;

int               handleFastEMA, handleMidEMA, handleSlowEMA, handleRSI, handleATR;

MarketState       FailedStates[];
MarketState       SuccessStates[];
int               failedCount = 0;
int               successCount = 0;

double            peakProfit[];
ulong             trackedTickets[];
MarketState       entryStates[];

datetime          lastTradeTime = 0;
ulong             lastProcessedDeal = 0;

// Safety state
double            dailyStartBalance = 0;
datetime          dailyStartDay     = 0;
int               consecLosses      = 0;
double            prevATR           = 0;
datetime          lastTimerSec      = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   symInfo.Name(_Symbol);
   symInfo.Refresh();

   handleFastEMA = iMA(_Symbol, InpTimeframe, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleMidEMA  = iMA(_Symbol, InpTimeframe, InpMidEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(_Symbol, InpTimeframe, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(_Symbol, InpTimeframe, 14, PRICE_CLOSE);
   handleATR     = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(handleFastEMA == INVALID_HANDLE || handleMidEMA == INVALID_HANDLE ||
      handleSlowEMA == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE)
     { Print("ERROR: Failed to create indicator handles"); return(INIT_FAILED); }

   trade.SetExpertMagicNumber(777555);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   ArrayResize(FailedStates, 0, InpMaxStates);
   ArrayResize(SuccessStates, 0, InpMaxStates);
   ArrayResize(peakProfit, 0, 10);
   ArrayResize(trackedTickets, 0, 10);
   ArrayResize(entryStates, 0, 10);

   LoadStatesFromFile();
   EventSetTimer(InpTimerSeconds);

   Print("MicroHunter EA initialized | Balance: $", DoubleToString(accInfo.Balance(), 2),
         " | Timer: ", InpTimerSeconds, "s | Cooldown: ", InpTradeCooldownSec, "s");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   SaveStatesToFile();
   if(handleFastEMA != INVALID_HANDLE) IndicatorRelease(handleFastEMA);
   if(handleMidEMA  != INVALID_HANDLE) IndicatorRelease(handleMidEMA);
   if(handleSlowEMA != INVALID_HANDLE) IndicatorRelease(handleSlowEMA);
   if(handleRSI     != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleATR     != INVALID_HANDLE) IndicatorRelease(handleATR);
   Print("MicroHunter EA removed | States saved: Failed=", failedCount, " Success=", successCount);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   // Overload protection: run logic at most once per second
   if(TimeCurrent() == lastTimerSec) return;
   lastTimerSec = TimeCurrent();

   symInfo.Refresh();
   CheckClosedDeals();
   ManageOpenPositions();
   if(CountMyPositions() < InpMaxPositions)
      EvaluateEntry();
  }

//+------------------------------------------------------------------+
bool DailyLossExceeded()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(today != dailyStartDay)
     { dailyStartDay = today; dailyStartBalance = accInfo.Balance(); consecLosses = 0; }
   if(dailyStartBalance <= 0) return false;
   double lossPct = (dailyStartBalance - accInfo.Equity()) / dailyStartBalance * 100.0;
   if(lossPct >= InpMaxDailyLossPct)
     { Print("DAILY LOSS LIMIT hit: ", DoubleToString(lossPct,2), "%"); return true; }
   return false;
  }

//+------------------------------------------------------------------+
bool MarginTooLow()
  {
   double level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(level > 0 && level < InpMinMarginLevel)
     { Print("MARGIN LEVEL low: ", DoubleToString(level,1), "%"); return true; }
   return false;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   symInfo.Refresh();
   ManageOpenPositions();
  }

//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol()==_Symbol && posInfo.Magic()==777555)
         count++;
   return count;
  }

//+------------------------------------------------------------------+
bool GetIndicators(double &fastEMA, double &midEMA, double &slowEMA, double &rsi, double &atr)
  {
   double bF[2], bM[2], bS[2], bR[2], bA[2];
   if(CopyBuffer(handleFastEMA, 0, 0, 2, bF) < 2) return false;
   if(CopyBuffer(handleMidEMA,  0, 0, 2, bM) < 2) return false;
   if(CopyBuffer(handleSlowEMA, 0, 0, 2, bS) < 2) return false;
   if(CopyBuffer(handleRSI,     0, 0, 2, bR) < 2) return false;
   if(CopyBuffer(handleATR,     0, 0, 2, bA) < 2) return false;
   fastEMA=bF[1]; midEMA=bM[1]; slowEMA=bS[1]; rsi=bR[1]; atr=bA[1];
   return true;
  }

//+------------------------------------------------------------------+
int GetTrendDirection(double f, double m, double s)
  {
   if(f > m && m > s) return +1;
   if(f < m && m < s) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
MarketState CaptureState(int dir, double rsi, double atr, double price, double midEMA)
  {
   MarketState st;
   st.trendDirection = dir;
   st.rsi = rsi; st.atr = atr;
   st.emaDist = (midEMA!=0) ? (price-midEMA)/midEMA*10000.0 : 0;
   st.sessionHour = TimeHour(TimeCurrent());
   st.spread = symInfo.Spread() * symInfo.Point();
   return st;
  }

//+------------------------------------------------------------------+
double StateDistance(const MarketState &a, const MarketState &b)
  {
   if(a.trendDirection != b.trendDirection) return 1.0;
   double d = 0;
   double dR = (a.rsi-b.rsi)/100.0; d += dR*dR;
   double av = (a.atr+b.atr)/2.0;
   double dA = (av>0) ? (a.atr-b.atr)/av : 0; d += dA*dA;
   double dE = (a.emaDist-b.emaDist)/100.0; d += dE*dE;
   double dH = (double)(a.sessionHour-b.sessionHour)/24.0; d += dH*dH;
   return MathSqrt(d/4.0);
  }

double StateSimilarity(const MarketState &a, const MarketState &b) { return 1.0 - StateDistance(a,b); }

//+------------------------------------------------------------------+
bool IsFailedStateMatch(const MarketState &c)
  {
   if(!InpEnableLearning) return false;
   for(int i=0; i<failedCount; i++)
     {
      double sim = StateSimilarity(c, FailedStates[i]);
      if(sim >= InpMatchThreshold)
        { Print("BLOCKED: Failed State #",i," sim=",DoubleToString(sim*100,1),"%"); return true; }
     }
   return false;
  }

bool IsSuccessStateMatch(const MarketState &c)
  {
   if(!InpEnableLearning) return false;
   for(int i=0; i<successCount; i++)
      if(StateSimilarity(c, SuccessStates[i]) >= InpMatchThreshold) return true;
   return false;
  }

//+------------------------------------------------------------------+
void RecordState(MarketState &state, bool isSuccess)
  {
   if(isSuccess)
     {
      if(successCount >= InpMaxStates)
        { for(int i=0;i<successCount-1;i++) SuccessStates[i]=SuccessStates[i+1]; successCount--; }
      ArrayResize(SuccessStates, successCount+1);
      SuccessStates[successCount++] = state;
      Print("STATE Success #",successCount," RSI=",DoubleToString(state.rsi,1));
     }
   else
     {
      if(failedCount >= InpMaxStates)
        { for(int i=0;i<failedCount-1;i++) FailedStates[i]=FailedStates[i+1]; failedCount--; }
      ArrayResize(FailedStates, failedCount+1);
      FailedStates[failedCount++] = state;
      Print("STATE Failed #",failedCount," RSI=",DoubleToString(state.rsi,1));
     }
  }

//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
  {
   double balance = accInfo.Balance();
   double risk = MathMin(balance*InpRiskPercent/100.0, balance*InpMaxRiskPercent/100.0);
   double tv = symInfo.TickValue(); double ts = symInfo.TickSize();
   if(tv<=0||ts<=0||slPoints<=0) return symInfo.LotsMin();
   double lot = risk / (slPoints/ts*tv);
   lot = MathMax(symInfo.LotsMin(), lot);
   lot = MathMin(symInfo.LotsMax(), lot);
   lot = MathFloor(lot/symInfo.LotsStep()) * symInfo.LotsStep();
   double margin=0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lot,symInfo.Ask(),margin)) return symInfo.LotsMin();
   if(margin > accInfo.FreeMargin()*0.8) lot = symInfo.LotsMin();
   return NormalizeDouble(lot, 2);
  }

double CalculateSLPoints(double atr)
  {
   double sl = atr * InpATRMultiplier;
   double mx = InpMaxSLPips * symInfo.Point() * 10;
   if(sl > mx) sl = mx;
   double mn = symInfo.Spread() * symInfo.Point() * 2.0;
   if(sl < mn) sl = mn;
   return sl;
  }

bool IsWithinSession()
  {
   int h = TimeHour(TimeCurrent());
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   return (h >= InpSessionStartHour || h < InpSessionEndHour);
  }

bool IsSpreadAcceptable()
  {
   double sp = symInfo.Spread() * symInfo.Point() / (symInfo.Point()*10);
   return (sp <= InpMaxSpreadPips);
  }

//+------------------------------------------------------------------+
void EvaluateEntry()
  {
   // === SAFETY CIRCUIT BREAKERS ===
   if(DailyLossExceeded()) return;
   if(MarginTooLow()) return;
   if(consecLosses >= InpMaxConsecLosses)
     { Print("PAUSED: ",consecLosses," consecutive losses"); return; }

   if(!IsWithinSession()) return;
   if(!IsSpreadAcceptable()) return;
   if(TimeCurrent() - lastTradeTime < InpTradeCooldownSec) return;

   double fastEMA, midEMA, slowEMA, rsi, atr;
   if(!GetIndicators(fastEMA, midEMA, slowEMA, rsi, atr)) return;

   // ATR volatility spike guard
   if(prevATR > 0 && atr > prevATR * InpATRSpikeMult)
     { Print("VOL SPIKE skip: ATR=",atr," prev=",prevATR); prevATR=atr; return; }
   prevATR = atr;

   int trend = GetTrendDirection(fastEMA, midEMA, slowEMA);
   if(trend == 0) return;
   if(trend == +1 && rsi > 75) return;
   if(trend == -1 && rsi < 25) return;

   double price = (trend==+1) ? symInfo.Ask() : symInfo.Bid();
   MarketState cur = CaptureState(trend, rsi, atr, price, midEMA);

   if(IsFailedStateMatch(cur)) return;
   if(IsSuccessStateMatch(cur)) Print("HIGH-CONFIDENCE: matches successful pattern");

   double slPts = CalculateSLPoints(atr);
   double tpPts = slPts * InpRRRatio;
   double lots  = CalculateLotSize(slPts);
   double sl, tp;

   if(trend == +1)
     {
      sl = NormalizeDouble(symInfo.Ask()-slPts, symInfo.Digits());
      tp = NormalizeDouble(symInfo.Ask()+tpPts, symInfo.Digits());
      if(trade.Buy(lots,_Symbol,symInfo.Ask(),sl,tp,"MicroHunter BUY"))
        { lastTradeTime=TimeCurrent(); TrackNewPosition(cur);
          Print("BUY | Lot=",lots," SL=",sl," TP=",tp," RSI=",DoubleToString(rsi,1)); }
      else Print("BUY FAILED: ",trade.ResultRetcodeDescription());
     }
   else
     {
      sl = NormalizeDouble(symInfo.Bid()+slPts, symInfo.Digits());
      tp = NormalizeDouble(symInfo.Bid()-tpPts, symInfo.Digits());
      if(trade.Sell(lots,_Symbol,symInfo.Bid(),sl,tp,"MicroHunter SELL"))
        { lastTradeTime=TimeCurrent(); TrackNewPosition(cur);
          Print("SELL | Lot=",lots," SL=",sl," TP=",tp," RSI=",DoubleToString(rsi,1)); }
      else Print("SELL FAILED: ",trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void TrackPosition(ulong ticket, const MarketState &es)
  {
   int n = ArraySize(trackedTickets);
   ArrayResize(trackedTickets, n+1);
   ArrayResize(peakProfit, n+1);
   ArrayResize(entryStates, n+1);
   trackedTickets[n] = ticket; peakProfit[n] = 0; entryStates[n] = es;
  }

void TrackNewPosition(const MarketState &es)
  {
   ulong deal = trade.ResultDeal(); ulong pid = 0;
   if(deal!=0 && HistoryDealSelect(deal))
      pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(pid==0)
      for(int i=PositionsTotal()-1; i>=0; i--)
         if(posInfo.SelectByIndex(i) && posInfo.Symbol()==_Symbol && posInfo.Magic()==777555)
           { pid=posInfo.Ticket(); break; }
   if(pid!=0) TrackPosition(pid, es);
  }

void TrackPositionOrphan(ulong ticket)
  {
   MarketState e; e.trendDirection=0; e.rsi=0; e.atr=0; e.emaDist=0;
   e.sessionHour=-1; e.spread=0;
   TrackPosition(ticket, e);
  }

//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol()!=_Symbol || posInfo.Magic()!=777555) continue;

      double op = posInfo.PriceOpen();
      double cs = posInfo.StopLoss();
      double pr = posInfo.Profit();
      double sp = symInfo.Spread() * symInfo.Point();
      ulong  tk = posInfo.Ticket();

      int idx=-1;
      for(int j=0;j<ArraySize(trackedTickets);j++)
         if(trackedTickets[j]==tk) { idx=j; break; }
      if(idx<0) { TrackPositionOrphan(tk); idx=ArraySize(trackedTickets)-1; }

      if(pr > peakProfit[idx]) peakProfit[idx] = pr;

      bool isBuy = (posInfo.PositionType()==POSITION_TYPE_BUY);
      double cp = isBuy ? symInfo.Bid() : symInfo.Ask();
      double diff = isBuy ? (cp-op) : (op-cp);

      // BREAKEVEN
      if(diff >= sp*InpBEMultiplier)
        {
         double be = isBuy ? op+sp+symInfo.Point() : op-sp-symInfo.Point();
         be = NormalizeDouble(be, symInfo.Digits());
         if(isBuy && (cs<be||cs==0))
            if(trade.PositionModify(tk,be,posInfo.TakeProfit())) Print("BE BUY #",tk," SL->",be);
         if(!isBuy && (cs>be||cs==0))
            if(trade.PositionModify(tk,be,posInfo.TakeProfit())) Print("BE SELL #",tk," SL->",be);
        }

      // RATCHET TRAIL
      if(peakProfit[idx]>0 && pr>0)
        {
         double lk = diff * (InpTrailLockPct/100.0);
         double tl = isBuy ? op+lk : op-lk;
         tl = NormalizeDouble(tl, symInfo.Digits());
         if(isBuy && tl>cs && tl>op)
            if(trade.PositionModify(tk,tl,posInfo.TakeProfit())) Print("TRAIL BUY #",tk," SL->",tl);
         if(!isBuy && (tl<cs||cs==0) && tl<op)
            if(trade.PositionModify(tk,tl,posInfo.TakeProfit())) Print("TRAIL SELL #",tk," SL->",tl);
        }
     }
  }

//+------------------------------------------------------------------+
void CheckClosedDeals()
  {
   if(!InpEnableLearning) return;
   datetime from = TimeCurrent() - InpTimerSeconds * 3;
   if(!HistorySelect(from, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   ulong maxSeen = lastProcessedDeal;

   for(int i=0; i<total; i++)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt==0 || dt<=lastProcessedDeal) continue;
      if(dt>maxSeen) maxSeen=dt;

      if(HistoryDealGetInteger(dt,DEAL_MAGIC)!=777555) continue;
      if(HistoryDealGetString(dt,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(dt,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;

      double net = HistoryDealGetDouble(dt,DEAL_PROFIT)
                 + HistoryDealGetDouble(dt,DEAL_COMMISSION)
                 + HistoryDealGetDouble(dt,DEAL_SWAP);

      ulong pid = (ulong)HistoryDealGetInteger(dt,DEAL_POSITION_ID);
      int idx=-1;
      for(int j=0;j<ArraySize(trackedTickets);j++)
         if(trackedTickets[j]==pid) { idx=j; break; }

      if(idx>=0 && entryStates[idx].sessionHour>=0)
        {
         if(net<0) RecordState(entryStates[idx], false);
         else if(net>0) RecordState(entryStates[idx], true);
        }

      // Consecutive-loss counter
      if(net<0) consecLosses++;
      else if(net>0) consecLosses = 0;

      if(idx>=0)
        {
         int n=ArraySize(trackedTickets);
         for(int k=idx;k<n-1;k++)
           { trackedTickets[k]=trackedTickets[k+1]; peakProfit[k]=peakProfit[k+1]; entryStates[k]=entryStates[k+1]; }
         ArrayResize(trackedTickets, n-1);
         ArrayResize(peakProfit, n-1);
         ArrayResize(entryStates, n-1);
        }
     }
   lastProcessedDeal = maxSeen;
  }

//+------------------------------------------------------------------+
void SaveStatesToFile()
  {
   int fh = FileOpen("MicroHunter_States.bin", FILE_WRITE|FILE_BIN);
   if(fh==INVALID_HANDLE) { Print("WARNING: cannot save states"); return; }
   FileWriteInteger(fh, failedCount);
   for(int i=0;i<failedCount;i++)
     {
      FileWriteInteger(fh, FailedStates[i].trendDirection);
      FileWriteDouble(fh, FailedStates[i].rsi);
      FileWriteDouble(fh, FailedStates[i].atr);
      FileWriteDouble(fh, FailedStates[i].emaDist);
      FileWriteInteger(fh, FailedStates[i].sessionHour);
      FileWriteDouble(fh, FailedStates[i].spread);
     }
   FileWriteInteger(fh, successCount);
   for(int i=0;i<successCount;i++)
     {
      FileWriteInteger(fh, SuccessStates[i].trendDirection);
      FileWriteDouble(fh, SuccessStates[i].rsi);
      FileWriteDouble(fh, SuccessStates[i].atr);
      FileWriteDouble(fh, SuccessStates[i].emaDist);
      FileWriteInteger(fh, SuccessStates[i].sessionHour);
      FileWriteDouble(fh, SuccessStates[i].spread);
     }
   FileClose(fh);
   Print("States saved: Failed=", failedCount, " Success=", successCount);
  }

//+------------------------------------------------------------------+
void LoadStatesFromFile()
  {
   if(!FileIsExist("MicroHunter_States.bin"))
     { Print("No states file - starting fresh"); return; }
   int fh = FileOpen("MicroHunter_States.bin", FILE_READ|FILE_BIN);
   if(fh==INVALID_HANDLE) return;

   bool bad = false;
   if(FileIsEnding(fh)) { FileClose(fh); return; }
   failedCount = FileReadInteger(fh);
   if(failedCount<0 || failedCount>InpMaxStates) { failedCount=0; bad=true; }
   ArrayResize(FailedStates, failedCount);
   for(int i=0;i<failedCount&&!bad;i++)
     {
      if(FileIsEnding(fh)) { failedCount=i; bad=true; break; }
      FailedStates[i].trendDirection = FileReadInteger(fh);
      FailedStates[i].rsi = FileReadDouble(fh);
      FailedStates[i].atr = FileReadDouble(fh);
      FailedStates[i].emaDist = FileReadDouble(fh);
      FailedStates[i].sessionHour = FileReadInteger(fh);
      FailedStates[i].spread = FileReadDouble(fh);
     }
   if(bad || FileIsEnding(fh))
     { successCount=0; ArrayResize(SuccessStates,0); FileClose(fh);
       Print("States loaded (truncated): Failed=",failedCount); return; }

   successCount = FileReadInteger(fh);
   if(successCount<0 || successCount>InpMaxStates) successCount=0;
   ArrayResize(SuccessStates, successCount);
   for(int i=0;i<successCount;i++)
     {
      if(FileIsEnding(fh)) { successCount=i; ArrayResize(SuccessStates,i); break; }
      SuccessStates[i].trendDirection = FileReadInteger(fh);
      SuccessStates[i].rsi = FileReadDouble(fh);
      SuccessStates[i].atr = FileReadDouble(fh);
      SuccessStates[i].emaDist = FileReadDouble(fh);
      SuccessStates[i].sessionHour = FileReadInteger(fh);
      SuccessStates[i].spread = FileReadDouble(fh);
     }
   FileClose(fh);
   Print("States loaded: Failed=", failedCount, " Success=", successCount);
  }

//+------------------------------------------------------------------+
int TimeHour(datetime t)
  {
   MqlDateTime dt; TimeToStruct(t, dt); return dt.hour;
  }
//+------------------------------------------------------------------+
