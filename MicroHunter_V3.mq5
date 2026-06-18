//+------------------------------------------------------------------+
//|                                          MicroHunter_V3.mq5      |
//|  10-second timer entry | Self-learning pattern memory            |
//|  XAUUSD micro $10-$50 | ATR-scaled stops | Partial close 2:1 RR |
//+------------------------------------------------------------------+
//  DEEP ANALYSIS vs V1/V2:
//  V1 problem: timer fires but 6 filters too tight, triple-EMA rare
//  V2 problem: single-tick momentum = noise, fires on every tick = overtrading
//  V3 solution:
//    - OnTimer(10s) for entry, OnTick for position mgmt only
//    - 2-bar confirmed EMA cross (not single tick momentum)
//    - RSI safe-zone filter (35-65) blocks overbought/oversold entries
//    - HTF M15 EMA50 as trend gate
//    - Partial close 50% at 1R + instant BE => protects profit
//    - Trailing locks 65% of peak move => rides winners
//    - Time-based force-exit after 4h (no overnight swap on micro)
//    - Self-learning: entry MarketState stored on win/loss, blocks similar losses
//    - Stats: learning, daily loss, consec loss, margin, ATR spike, session
//+------------------------------------------------------------------+
#property copyright "MicroHunter V3"
#property version   "3.00"
#property strict
#property description "10s timer XAUUSD scalper | Self-learning | Partial close | 2:1 RR"

#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUTS ====================================
input group "=== GENERAL ==="
input long   InpMagic            = 990203;
input int    InpSlippagePoints   = 30;
input bool   InpVerboseLog       = true;

input group "=== TIMER ==="
input int    InpTimerSec         = 10;        // Entry check interval (seconds)

input group "=== RISK ==="
enum ENUM_LOT_MODE3 { LOT_FIXED3=0, LOT_RISK_PCT3=1 };
input ENUM_LOT_MODE3 InpLotMode  = LOT_RISK_PCT3;
input double InpFixedLot         = 0.01;
input double InpRiskPct          = 1.0;       // Risk % per trade
input int    InpMaxPositions     = 1;

input group "=== SIGNAL (M1 entry) ==="
input ENUM_TIMEFRAMES InpEntryTF = PERIOD_M1;
input int    InpFastEMA          = 8;
input int    InpSlowEMA          = 21;
input int    InpRSIPeriod        = 14;
input int    InpRSIBuyMax        = 65;        // RSI max for BUY
input int    InpRSISellMin       = 35;        // RSI min for SELL
input int    InpATRPeriod        = 14;

input group "=== HTF TREND FILTER ==="
input bool   InpUseHTF           = true;
input ENUM_TIMEFRAMES InpHTFTF   = PERIOD_M15;
input int    InpHTFEMA           = 50;

input group "=== STOPS (ATR-scaled) ==="
input double InpSL_ATR_Mult      = 1.2;       // SL = ATR x mult
input double InpRRRatio          = 2.0;       // TP = SL x RR
input int    InpMinSLPts         = 200;       // Floor SL (points)
input int    InpMaxSLPts         = 600;       // Cap SL (points)

input group "=== POSITION MGMT ==="
input bool   InpPartialClose     = true;
input double InpPartialPct       = 50.0;      // % volume to close at 1R
input bool   InpUseBreakEven     = true;
input int    InpBEOffsetPts      = 10;        // BE offset above entry
input bool   InpUseTrailing      = true;
input double InpTrailLockPct     = 65.0;      // Lock X% of peak profit
input int    InpMaxTradeMin      = 240;       // Force exit after N minutes (0=off)

input group "=== FILTERS ==="
input int    InpMaxSpreadPts     = 50;
input int    InpMinATRPts        = 150;       // Min ATR to trade
input int    InpCooldownSec      = 30;        // Min seconds between entries
input int    InpSessionStart     = 1;         // Server hour session start
input int    InpSessionEnd       = 22;        // Server hour session end

input group "=== SAFETY ==="
input double InpMaxDailyLossPct  = 5.0;
input int    InpMaxConsecLosses  = 3;
input double InpMinMarginLevel   = 300.0;
input double InpATRSpikeMult     = 2.5;

input group "=== SELF-LEARNING ==="
input bool   InpEnableLearning   = true;
input int    InpMaxStates        = 200;
input double InpBlockThresh      = 0.88;      // Block if loss similarity >= this
input double InpBoostThresh      = 0.90;      // Log "high confidence" if win sim >= this

input group "=== FILES ==="
input bool   InpUseJournal       = true;
input string InpJournalFile      = "MH_V3_journal.csv";
input string InpStateFile        = "MH_V3_states.bin";

//====================== MARKET STATE STRUCT =======================
struct MarketState
  {
   int    trendDir;
   double rsi;
   double atrPts;
   double emaSlope;
   int    htfDir;
   int    hour;
  };

//====================== GLOBALS ==================================
int g_hFast=INVALID_HANDLE, g_hSlow=INVALID_HANDLE;
int g_hRSI =INVALID_HANDLE, g_hATR =INVALID_HANDLE, g_hHTF=INVALID_HANDLE;

MarketState g_lossStates[], g_winStates[];
int         g_lossCnt=0,    g_winCnt=0;

ulong       g_tkts[];
datetime    g_tkEntryTime[];
double      g_tkSLPts[];
bool        g_tkPartDone[];
MarketState g_tkState[];

int    g_totalTrades=0, g_wins=0, g_losses=0;
double g_grossProfit=0, g_grossLoss=0;

double   g_dailyBal=0;
datetime g_dailyDay=0;
int      g_consecLoss=0;
double   g_prevATR=0;
datetime g_lastEntry=0;

string   g_lastSignal="INIT", g_lastTrigger="WAIT";
long     g_tickCount=0;
datetime g_lastSec=0;
int      g_ticksThisSec=0, g_ticksPerSec=0;

//====================== HELPERS ==================================
double Pt()        { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
double Bid()       { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
double Ask()       { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
long   SpreadPts() { return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD); }
long   StopsMin()  { return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
double VolStep()   { double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); return s>0?s:0.01; }
double VolMin()    { return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN); }
double VolMax()    { return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX); }
int    VolDig()    { double s=VolStep(); int d=0; while(s<1.0&&d<8){s*=10;d++;} return d; }
int    HourNow()   { MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); return dt.hour; }

void ConfigFill()
  {
   long m=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if(m & SYMBOL_FILLING_FOK)       trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if(m & SYMBOL_FILLING_IOC)  trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                             trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

int CountMyPos()
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i); if(!t) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      n++;
     }
   return n;
  }

double NormVol(double v, bool &uf)
  {
   uf=false;
   double step=VolStep(),mn=VolMin(),mx=VolMax();
   v=MathFloor(v/step)*step;
   if(v<mn){uf=true;v=mn;} if(v>mx) v=mx;
   return NormalizeDouble(v,VolDig());
  }

double EnforceSL(double pts)
  { double mn=(double)StopsMin(); return pts<mn?mn:pts; }

//====================== INDICATORS ===============================
bool GetInd(double &fast, double &slow, double &rsi, double &atrPts)
  {
   double bF[3],bS[3],bR[3],bA[3];
   ArraySetAsSeries(bF,true); ArraySetAsSeries(bS,true);
   ArraySetAsSeries(bR,true); ArraySetAsSeries(bA,true);
   if(CopyBuffer(g_hFast,0,0,3,bF)<3) return false;
   if(CopyBuffer(g_hSlow,0,0,3,bS)<3) return false;
   if(CopyBuffer(g_hRSI, 0,0,3,bR)<3) return false;
   if(CopyBuffer(g_hATR, 0,0,3,bA)<3) return false;
   fast=bF[0]; slow=bS[0]; rsi=bR[0];
   double p=Pt(); atrPts=(p>0?bA[0]/p:-1);
   return atrPts>0;
  }

int GetEMACross()
  {
   double bF[3],bS[3];
   ArraySetAsSeries(bF,true); ArraySetAsSeries(bS,true);
   if(CopyBuffer(g_hFast,0,0,3,bF)<3) return 0;
   if(CopyBuffer(g_hSlow,0,0,3,bS)<3) return 0;
   bool upNow=bF[0]>bS[0], upPrev=bF[1]>bS[1];
   bool dnNow=bF[0]<bS[0], dnPrev=bF[1]<bS[1];
   if(upNow && upPrev) return +1;
   if(dnNow && dnPrev) return -1;
   return 0;
  }

int HTFDir()
  {
   if(!InpUseHTF) return 0;
   double e[2]; ArraySetAsSeries(e,true);
   if(CopyBuffer(g_hHTF,0,0,2,e)<2) return 0;
   double mid=(Bid()+Ask())/2.0;
   return mid>e[0]?+1:(mid<e[0]?-1:0);
  }

//====================== SELF-LEARNING ============================
double StateDist(const MarketState &a, const MarketState &b)
  {
   if(a.trendDir!=b.trendDir || a.htfDir!=b.htfDir) return 1.0;
   double d=0;
   double dR=(a.rsi-b.rsi)/100.0; d+=dR*dR;
   double av=(a.atrPts+b.atrPts)/2.0;
   double dA=(av>0?(a.atrPts-b.atrPts)/av:0); d+=dA*dA;
   double dE=(a.emaSlope-b.emaSlope)/100.0; d+=dE*dE;
   double dH=(double)(a.hour-b.hour)/24.0; d+=dH*dH;
   return MathSqrt(d/4.0);
  }

double StateSim(const MarketState &a, const MarketState &b) { return 1.0-StateDist(a,b); }

bool IsBlockedByLoss(const MarketState &cur)
  {
   if(!InpEnableLearning) return false;
   for(int i=0;i<g_lossCnt;i++)
      if(StateSim(cur,g_lossStates[i])>=InpBlockThresh)
        { if(InpVerboseLog) Print("LEARN: blocked by loss#",i," sim=",DoubleToString(StateSim(cur,g_lossStates[i])*100,1),"%"); return true; }
   return false;
  }

bool IsWinConfirmed(const MarketState &cur)
  {
   if(!InpEnableLearning) return false;
   for(int i=0;i<g_winCnt;i++)
      if(StateSim(cur,g_winStates[i])>=InpBoostThresh) return true;
   return false;
  }

void StoreState(const MarketState &st, bool isWin)
  {
   if(!InpEnableLearning) return;
   if(isWin)
     {
      if(g_winCnt>=InpMaxStates)
        { for(int i=0;i<g_winCnt-1;i++) g_winStates[i]=g_winStates[i+1]; g_winCnt--; }
      ArrayResize(g_winStates,g_winCnt+1);
      g_winStates[g_winCnt++]=st;
      if(InpVerboseLog) Print("LEARN: WIN stored #",g_winCnt);
     }
   else
     {
      if(g_lossCnt>=InpMaxStates)
        { for(int i=0;i<g_lossCnt-1;i++) g_lossStates[i]=g_lossStates[i+1]; g_lossCnt--; }
      ArrayResize(g_lossStates,g_lossCnt+1);
      g_lossStates[g_lossCnt++]=st;
      if(InpVerboseLog) Print("LEARN: LOSS stored #",g_lossCnt);
     }
   SaveStates();
  }

void SaveStates()
  {
   int f=FileOpen(InpStateFile,FILE_WRITE|FILE_BIN);
   if(f==INVALID_HANDLE) return;
   FileWriteInteger(f,g_lossCnt);
   for(int i=0;i<g_lossCnt;i++)
     {
      FileWriteInteger(f,g_lossStates[i].trendDir);
      FileWriteDouble(f,g_lossStates[i].rsi);
      FileWriteDouble(f,g_lossStates[i].atrPts);
      FileWriteDouble(f,g_lossStates[i].emaSlope);
      FileWriteInteger(f,g_lossStates[i].htfDir);
      FileWriteInteger(f,g_lossStates[i].hour);
     }
   FileWriteInteger(f,g_winCnt);
   for(int i=0;i<g_winCnt;i++)
     {
      FileWriteInteger(f,g_winStates[i].trendDir);
      FileWriteDouble(f,g_winStates[i].rsi);
      FileWriteDouble(f,g_winStates[i].atrPts);
      FileWriteDouble(f,g_winStates[i].emaSlope);
      FileWriteInteger(f,g_winStates[i].htfDir);
      FileWriteInteger(f,g_winStates[i].hour);
     }
   FileClose(f);
  }

void LoadStates()
  {
   if(!FileIsExist(InpStateFile)) { Print("LEARN: no state file, fresh start"); return; }
   int f=FileOpen(InpStateFile,FILE_READ|FILE_BIN);
   if(f==INVALID_HANDLE) return;
   g_lossCnt=FileReadInteger(f);
   if(g_lossCnt<0||g_lossCnt>InpMaxStates) g_lossCnt=0;
   ArrayResize(g_lossStates,g_lossCnt);
   for(int i=0;i<g_lossCnt;i++)
     {
      if(FileIsEnding(f)){g_lossCnt=i;break;}
      g_lossStates[i].trendDir=FileReadInteger(f);
      g_lossStates[i].rsi=FileReadDouble(f);
      g_lossStates[i].atrPts=FileReadDouble(f);
      g_lossStates[i].emaSlope=FileReadDouble(f);
      g_lossStates[i].htfDir=FileReadInteger(f);
      g_lossStates[i].hour=FileReadInteger(f);
     }
   if(FileIsEnding(f)){FileClose(f);Print("LEARN: loaded loss=",g_lossCnt," win=0");return;}
   g_winCnt=FileReadInteger(f);
   if(g_winCnt<0||g_winCnt>InpMaxStates) g_winCnt=0;
   ArrayResize(g_winStates,g_winCnt);
   for(int i=0;i<g_winCnt;i++)
     {
      if(FileIsEnding(f)){g_winCnt=i;break;}
      g_winStates[i].trendDir=FileReadInteger(f);
      g_winStates[i].rsi=FileReadDouble(f);
      g_winStates[i].atrPts=FileReadDouble(f);
      g_winStates[i].emaSlope=FileReadDouble(f);
      g_winStates[i].htfDir=FileReadInteger(f);
      g_winStates[i].hour=FileReadInteger(f);
     }
   FileClose(f);
   Print("LEARN: loaded loss=",g_lossCnt," win=",g_winCnt);
  }

//====================== POSITION TRACKING ========================
void TrackPos(ulong ticket, double slPts, const MarketState &st)
  {
   int n=ArraySize(g_tkts);
   ArrayResize(g_tkts,n+1);        g_tkts[n]=ticket;
   ArrayResize(g_tkEntryTime,n+1); g_tkEntryTime[n]=TimeCurrent();
   ArrayResize(g_tkSLPts,n+1);     g_tkSLPts[n]=slPts;
   ArrayResize(g_tkPartDone,n+1);  g_tkPartDone[n]=false;
   ArrayResize(g_tkState,n+1);     g_tkState[n]=st;
  }

int FindTkt(ulong ticket)
  {
   for(int i=0;i<ArraySize(g_tkts);i++) if(g_tkts[i]==ticket) return i;
   return -1;
  }

void RemoveTkt(int idx)
  {
   int n=ArraySize(g_tkts);
   for(int i=idx;i<n-1;i++)
     {
      g_tkts[i]=g_tkts[i+1];
      g_tkEntryTime[i]=g_tkEntryTime[i+1];
      g_tkSLPts[i]=g_tkSLPts[i+1];
      g_tkPartDone[i]=g_tkPartDone[i+1];
      g_tkState[i]=g_tkState[i+1];
     }
   ArrayResize(g_tkts,n-1); ArrayResize(g_tkEntryTime,n-1);
   ArrayResize(g_tkSLPts,n-1); ArrayResize(g_tkPartDone,n-1);
   ArrayResize(g_tkState,n-1);
  }

//====================== SAFETY ===================================
bool DailyLossHit()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   datetime today=StringToTime(StringFormat("%04d.%02d.%02d",dt.year,dt.mon,dt.day));
   if(today!=g_dailyDay)
     { g_dailyDay=today; g_dailyBal=AccountInfoDouble(ACCOUNT_BALANCE); g_consecLoss=0; }
   if(g_dailyBal<=0) return false;
   double pct=(g_dailyBal-AccountInfoDouble(ACCOUNT_EQUITY))/g_dailyBal*100.0;
   if(pct>=InpMaxDailyLossPct)
     { Print("SAFETY: daily loss ",DoubleToString(pct,2),"%"); return true; }
   return false;
  }

bool MarginLow()
  { double lvl=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL); return lvl>0 && lvl<InpMinMarginLevel; }

bool InSession()
  { int h=HourNow(); return (h>=InpSessionStart && h<InpSessionEnd); }

//====================== LOT SIZE =================================
double ComputeLot(double slPts)
  {
   bool uf=false;
   if(InpLotMode==LOT_FIXED3) return NormVol(InpFixedLot,uf);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double risk=bal*(InpRiskPct/100.0);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double p=Pt();
   if(tv<=0||ts<=0||p<=0||slPts<=0) return NormVol(InpFixedLot,uf);
   double pv=tv*(p/ts); double slMoney=slPts*pv;
   if(slMoney<=0) return NormVol(InpFixedLot,uf);
   double out=NormVol(risk/slMoney,uf);
   double margin=0;
   if(OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,out,Ask(),margin))
      if(margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.8) out=VolMin();
   return out;
  }

//====================== JOURNAL ==================================
void JournalEntry(int dir, double lot, double price, int spread, string label, long order)
  {
   if(!InpUseJournal) return;
   int h=FileOpen(InpJournalFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0) FileWrite(h,"time","event","type","lot","price","spread","label","net","ticket");
   FileSeek(h,0,SEEK_END);
   FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),"ENTRY",
            (dir>0?"BUY":"SELL"),DoubleToString(lot,2),DoubleToString(price,_Digits),
            IntegerToString(spread),label,"",IntegerToString(order));
   FileClose(h);
  }

void JournalExit(ulong deal, string type, double lot, double price, double net)
  {
   if(!InpUseJournal) return;
   int h=FileOpen(InpJournalFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0) FileWrite(h,"time","event","type","lot","price","spread","label","net","ticket");
   FileSeek(h,0,SEEK_END);
   FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),"EXIT",
            type,"",DoubleToString(price,_Digits),"","",DoubleToString(net,2),IntegerToString((long)deal));
   FileClose(h);
  }

//====================== DISPLAY ==================================
void UpdateDisplay()
  {
   double fast=0,slow=0,rsi=0,atrPts=0;
   GetInd(fast,slow,rsi,atrPts);
   int htf=HTFDir();
   string s=
      "=== MicroHunter V3 | "+_Symbol+" ===\n"+
      "Bid/Ask    : "+DoubleToString(Bid(),_Digits)+" / "+DoubleToString(Ask(),_Digits)+"\n"+
      "Spread(pt) : "+IntegerToString(SpreadPts())+" (max "+IntegerToString(InpMaxSpreadPts)+")\n"+
      "ATR(pt)    : "+DoubleToString(atrPts,0)+" (min "+IntegerToString(InpMinATRPts)+")\n"+
      "RSI        : "+DoubleToString(rsi,1)+" (buy<="+IntegerToString(InpRSIBuyMax)+" sell>="+IntegerToString(InpRSISellMin)+")\n"+
      "HTF Trend  : "+(htf>0?"UP":(htf<0?"DOWN":"FLAT"))+"\n"+
      "EMA        : "+(fast>slow?"fast ABOVE slow":"fast BELOW slow")+"\n"+
      "Ticks/s    : "+IntegerToString(g_ticksPerSec)+"\n"+
      "Open Pos   : "+IntegerToString(CountMyPos())+"/"+IntegerToString(InpMaxPositions)+"\n"+
      "Signal     : "+g_lastSignal+"\n"+
      "Trigger    : "+g_lastTrigger+"\n"+
      "ConsecLoss : "+IntegerToString(g_consecLoss)+"/"+IntegerToString(InpMaxConsecLosses)+"\n"+
      "--- Session ---\n"+
      "Trades     : "+IntegerToString(g_totalTrades)+"\n"+
      "W / L      : "+IntegerToString(g_wins)+" / "+IntegerToString(g_losses)+"\n"+
      "WinRate    : "+(g_totalTrades>0?DoubleToString(100.0*g_wins/g_totalTrades,1):"0.0")+"%\n"+
      "PF         : "+(g_grossLoss>0?DoubleToString(g_grossProfit/g_grossLoss,2):"-")+"\n"+
      "--- Learning ---\n"+
      "LossStates : "+IntegerToString(g_lossCnt)+"\n"+
      "WinStates  : "+IntegerToString(g_winCnt)+"\n";
   Comment(s);
  }

//====================== MANAGE POSITIONS =========================
void ManagePositions()
  {
   double p=Pt(), bid=Bid(), ask=Ask();
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i); if(!t) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long   type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  =PositionGetDouble(POSITION_SL);
      double tp  =PositionGetDouble(POSITION_TP);
      double vol =PositionGetDouble(POSITION_VOLUME);
      double cur =(type==POSITION_TYPE_BUY?bid:ask);
      double profPts=(type==POSITION_TYPE_BUY?(cur-open)/p:(open-cur)/p);

      int idx=FindTkt(t);
      double refSL=(idx>=0?g_tkSLPts[idx]:(double)InpMinSLPts);

      // Time-based force exit
      if(InpMaxTradeMin>0 && idx>=0)
        {
         int elapsed=(int)((TimeCurrent()-g_tkEntryTime[idx])/60);
         if(elapsed>=InpMaxTradeMin)
           { trade.PositionClose(t); if(InpVerboseLog) Print("TIME EXIT #",t," after ",elapsed,"min"); continue; }
        }

      // Partial close at 1R profit
      if(InpPartialClose && idx>=0 && !g_tkPartDone[idx] && profPts>=refSL)
        {
         double closeVol=NormalizeDouble(vol*(InpPartialPct/100.0),VolDig());
         double mn=VolMin();
         if(closeVol>=mn && (vol-closeVol)>=mn)
           {
            if(trade.PositionClosePartial(t,closeVol))
              { g_tkPartDone[idx]=true; if(InpVerboseLog) Print("PARTIAL ",DoubleToString(closeVol,2)," of #",t," at 1R"); }
           }
        }

      double newSL=sl;

      // Breakeven at 1R
      if(InpUseBreakEven && profPts>=refSL)
        {
         double be=(type==POSITION_TYPE_BUY?open+InpBEOffsetPts*p:open-InpBEOffsetPts*p);
         if(type==POSITION_TYPE_BUY  && (sl==0||be>sl)) newSL=be;
         if(type==POSITION_TYPE_SELL && (sl==0||be<sl)) newSL=be;
        }

      // Trailing: lock X% of move from open
      if(InpUseTrailing && profPts>0)
        {
         double lockDist=profPts*(InpTrailLockPct/100.0);
         double trail=(type==POSITION_TYPE_BUY?open+lockDist*p:open-lockDist*p);
         if(type==POSITION_TYPE_BUY  && trail>newSL)               newSL=trail;
         if(type==POSITION_TYPE_SELL && (newSL==0||trail<newSL))   newSL=trail;
        }

      if(newSL!=sl && newSL!=0)
        {
         double mind=StopsMin()*p;
         bool ok=(type==POSITION_TYPE_BUY?(cur-newSL)>=mind:(newSL-cur)>=mind);
         if(ok) trade.PositionModify(t,NormalizeDouble(newSL,_Digits),tp);
        }
     }
  }

//====================== ENTRY EVALUATION =========================
void EvaluateEntry()
  {
   if(DailyLossHit())                               { g_lastTrigger="WAIT(daily_loss)";  return; }
   if(MarginLow())                                  { g_lastTrigger="WAIT(margin)";      return; }
   if(g_consecLoss>=InpMaxConsecLosses)             { g_lastTrigger="WAIT(consec_loss)"; return; }
   if(!InSession())                                 { g_lastTrigger="WAIT(session)";     return; }
   if(SpreadPts()>InpMaxSpreadPts)                  { g_lastTrigger="WAIT(spread)";      return; }
   if(CountMyPos()>=InpMaxPositions)                { g_lastTrigger="WAIT(max_pos)";     return; }
   if(TimeCurrent()-g_lastEntry<InpCooldownSec)     { g_lastTrigger="WAIT(cooldown)";    return; }

   double fast,slow,rsi,atrPts;
   if(!GetInd(fast,slow,rsi,atrPts))                { g_lastTrigger="WAIT(ind_na)";      return; }

   if(atrPts<InpMinATRPts)                          { g_lastTrigger="WAIT(atr_low)";     return; }
   if(g_prevATR>0 && atrPts>g_prevATR*InpATRSpikeMult)
     { g_lastTrigger="WAIT(atr_spike)"; g_prevATR=atrPts; return; }
   g_prevATR=atrPts;

   int cross=GetEMACross();
   if(cross==0) { g_lastSignal="WAIT"; g_lastTrigger="WAIT(no_cross)"; return; }

   if(cross>0 && rsi>InpRSIBuyMax)  { g_lastSignal="BUY?";  g_lastTrigger="WAIT(rsi_overbought)"; return; }
   if(cross<0 && rsi<InpRSISellMin) { g_lastSignal="SELL?"; g_lastTrigger="WAIT(rsi_oversold)";   return; }

   int htf=HTFDir();
   if(InpUseHTF && cross>0 && htf<0) { g_lastSignal="BUY?";  g_lastTrigger="WAIT(htf_bearish)"; return; }
   if(InpUseHTF && cross<0 && htf>0) { g_lastSignal="SELL?"; g_lastTrigger="WAIT(htf_bullish)"; return; }

   g_lastSignal=(cross>0?"BUY":"SELL");

   MarketState cur;
   cur.trendDir=cross; cur.rsi=rsi; cur.atrPts=atrPts;
   cur.emaSlope=(slow>0?(fast-slow)/slow*10000.0:0);
   cur.htfDir=htf; cur.hour=HourNow();

   if(IsBlockedByLoss(cur))  { g_lastTrigger="WAIT(learn_block)"; return; }
   if(IsWinConfirmed(cur) && InpVerboseLog) Print("LEARN: high-confidence pattern match!");

   double slPts=atrPts*InpSL_ATR_Mult;
   if(slPts<InpMinSLPts) slPts=InpMinSLPts;
   if(slPts>InpMaxSLPts) slPts=InpMaxSLPts;
   slPts=EnforceSL(slPts);
   double tpPts=EnforceSL(slPts*InpRRRatio);

   double lot=ComputeLot(slPts);
   if(lot<=0) { g_lastTrigger="WAIT(lot_zero)"; return; }

   double p=Pt(), price, sl, tp;
   bool ok=false;
   if(cross>0)
     { price=Ask(); sl=price-slPts*p; tp=price+tpPts*p;
       ok=trade.Buy(lot,_Symbol,0.0,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits),"MHV3"); }
   else
     { price=Bid(); sl=price+slPts*p; tp=price-tpPts*p;
       ok=trade.Sell(lot,_Symbol,0.0,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits),"MHV3"); }

   if(ok)
     {
      g_lastEntry=TimeCurrent();
      g_lastTrigger=(cross>0?"OPEN_BUY":"OPEN_SELL");
      ulong ticket=0;
      ulong deal=trade.ResultDeal();
      if(deal && HistoryDealSelect(deal))
         ticket=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      if(!ticket)
         for(int i=PositionsTotal()-1;i>=0;i--)
           { ulong t=PositionGetTicket(i);
             if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagic)
               { ticket=t; break; } }
      if(ticket) TrackPos(ticket,slPts,cur);
      JournalEntry(cross,lot,trade.ResultPrice(),(int)SpreadPts(),g_lastTrigger,(long)trade.ResultOrder());
      if(InpVerboseLog)
         Print("OPEN ",(cross>0?"BUY":"SELL")," lot=",DoubleToString(lot,2),
               " SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits),
               " ATR=",DoubleToString(atrPts,0)," RSI=",DoubleToString(rsi,1));
     }
   else if(InpVerboseLog)
      Print("OPEN FAILED ret=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
  }

//====================== EVENTS ===================================
int OnInit()
  {
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   ConfigFill();

   g_hFast=iMA(_Symbol,InpEntryTF,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_hSlow=iMA(_Symbol,InpEntryTF,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   g_hRSI =iRSI(_Symbol,InpEntryTF,InpRSIPeriod,PRICE_CLOSE);
   g_hATR =iATR(_Symbol,InpEntryTF,InpATRPeriod);
   g_hHTF =iMA(_Symbol,InpHTFTF,InpHTFEMA,0,MODE_EMA,PRICE_CLOSE);
   if(g_hFast==INVALID_HANDLE||g_hSlow==INVALID_HANDLE||
      g_hRSI==INVALID_HANDLE||g_hATR==INVALID_HANDLE||g_hHTF==INVALID_HANDLE)
     { Print("Indicator init failed"); return INIT_FAILED; }

   ArrayResize(g_lossStates,0,InpMaxStates); ArrayResize(g_winStates,0,InpMaxStates);
   ArrayResize(g_tkts,0,10); ArrayResize(g_tkEntryTime,0,10);
   ArrayResize(g_tkSLPts,0,10); ArrayResize(g_tkPartDone,0,10); ArrayResize(g_tkState,0,10);

   LoadStates();
   g_dailyBal=AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(InpTimerSec);
   Print("MicroHunter V3 init | ",_Symbol," | Timer=",InpTimerSec,"s | Bal=$",
         DoubleToString(g_dailyBal,2)," | Loss=",g_lossCnt," Win=",g_winCnt);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer(); SaveStates();
   if(g_hFast!=INVALID_HANDLE) IndicatorRelease(g_hFast);
   if(g_hSlow!=INVALID_HANDLE) IndicatorRelease(g_hSlow);
   if(g_hRSI !=INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hATR !=INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hHTF !=INVALID_HANDLE) IndicatorRelease(g_hHTF);
   Comment("");
   Print("MicroHunter V3 deinit | Trades=",g_totalTrades," W=",g_wins," L=",g_losses,
         " PF=",(g_grossLoss>0?DoubleToString(g_grossProfit/g_grossLoss,2):"n/a"));
  }

void OnTimer()   { EvaluateEntry(); UpdateDisplay(); }

void OnTick()
  {
   g_tickCount++;
   datetime now=TimeCurrent();
   if(now!=g_lastSec){g_ticksPerSec=g_ticksThisSec;g_ticksThisSec=0;g_lastSec=now;}
   g_ticksThisSec++;
   ManagePositions();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal=trans.deal; if(!deal) return;
   datetime to=TimeCurrent()+60, from=to-7*24*3600;
   if(!HistorySelect(from,to)) return;
   if(HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol)  return;
   long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_INOUT && entry!=DEAL_ENTRY_OUT_BY) return;

   double net=HistoryDealGetDouble(deal,DEAL_PROFIT)
             +HistoryDealGetDouble(deal,DEAL_SWAP)
             +HistoryDealGetDouble(deal,DEAL_COMMISSION);
   double price=HistoryDealGetDouble(deal,DEAL_PRICE);
   double lot  =HistoryDealGetDouble(deal,DEAL_VOLUME);
   long   dtype=HistoryDealGetInteger(deal,DEAL_TYPE);
   string closed=(dtype==DEAL_TYPE_SELL?"BUY":"SELL");

   ulong pid=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   int   idx=FindTkt(pid);

   // Only count as final close when position is gone
   bool stillOpen=PositionSelectByTicket(pid);
   if(!stillOpen)
     {
      g_totalTrades++;
      if(net>=0)
        { g_wins++; g_grossProfit+=net; g_consecLoss=0;
          if(idx>=0) StoreState(g_tkState[idx],true); }
      else
        { g_losses++; g_grossLoss+=(-net); g_consecLoss++;
          if(idx>=0) StoreState(g_tkState[idx],false); }
      if(idx>=0) RemoveTkt(idx);
      JournalExit(deal,closed,lot,price,net);
      if(InpVerboseLog) Print("EXIT ",closed," net=",DoubleToString(net,2)," consec=",g_consecLoss);
     }
  }
//+------------------------------------------------------------------+
