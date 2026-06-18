//+------------------------------------------------------------------+
//|                                              MicroHunter_V2.mq5  |
//|     Tick-driven scalper merging HyperScalp execution + MicroHunter|
//|     safety. Default target: XAUUSD, $10-$50 micro accounts.       |
//+------------------------------------------------------------------+
#property copyright "MicroHunter V2"
#property version   "2.00"
#property strict
#property description "Tick-based scalper with HTF trend filter, ATR SL/TP,"
#property description "6 safety circuit breakers, BE+trail, OnTradeTransaction stats."

#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUTS ====================================
input group "=== GENERAL ==="
input long   InpMagic              = 990202;
input int    InpSlippagePoints     = 30;
input bool   InpVerboseLog         = true;

input group "=== RISK ==="
enum ENUM_LOT_MODE { LOT_FIXED=0, LOT_RISK_PERCENT=1 };
input ENUM_LOT_MODE InpLotMode     = LOT_RISK_PERCENT;
input double InpFixedLot           = 0.01;
input double InpRiskPercent        = 0.5;
input bool   InpUseMinLotIfUnderflow = true;
input int    InpMaxPositions       = 1;

input group "=== SIGNAL ==="
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M1;
input int    InpFastEMA            = 8;
input int    InpSlowEMA            = 21;
input int    InpATRPeriod          = 14;

input group "=== HTF TREND FILTER ==="
input bool   InpUseHTFTrend        = true;
input ENUM_TIMEFRAMES InpHTFTimeframe = PERIOD_M15;
input int    InpHTFEMA             = 50;

input group "=== STOPS (ATR-scaled) ==="
input double InpSL_ATR_Mult        = 1.5;
input double InpRRRatio            = 1.8;
input int    InpMinSLPoints        = 150;
input int    InpMaxSLPoints        = 800;

input group "=== FILTERS ==="
input int    InpMaxSpreadPoints    = 50;
input int    InpMinATRPoints       = 100;
input int    InpMaxATRPoints       = 0;
input int    InpMinSecsBetweenTrades = 5;
input int    InpSessionStartHour   = 0;
input int    InpSessionEndHour     = 23;

input group "=== POSITION MGMT ==="
input bool   InpUseBreakEven       = true;
input int    InpBETriggerPoints    = 120;
input int    InpBEOffsetPoints     = 20;
input bool   InpUseTrailing        = true;
input int    InpTrailStartPoints   = 180;
input int    InpTrailDistancePoints= 120;

input group "=== SAFETY CIRCUIT BREAKERS ==="
input double InpMaxDailyLossPct    = 5.0;
input int    InpMaxConsecLosses    = 4;
input double InpMinMarginLevel     = 300.0;
input double InpATRSpikeMult       = 2.5;

input group "=== JOURNAL ==="
input bool   InpUseJournal         = true;
input string InpJournalFile        = "MicroHunter_V2_journal.csv";

//====================== GLOBALS ===================================
int      g_ema_fast=INVALID_HANDLE, g_ema_slow=INVALID_HANDLE, g_atr=INVALID_HANDLE;
int      g_htf_ema=INVALID_HANDLE;
long     g_tick_count=0;
datetime g_last_sec=0;
int      g_ticks_this_sec=0, g_ticks_per_sec=0;
datetime g_last_entry_time=0;
double   g_prev_bid=0.0;
string   g_last_signal="INIT", g_last_trigger="WAIT";
int      g_total_trades=0, g_wins=0, g_losses=0;
double   g_gross_profit=0.0, g_gross_loss=0.0;
double   g_daily_start_balance=0;
datetime g_daily_start_day=0;
int      g_consec_losses=0;
double   g_prev_atr=0;

//====================== HELPERS ===================================
double Pt()       { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
double Bid()      { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
double Ask()      { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
long   SpreadPts(){ return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD); }
long   StopsLevelPts(){ return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
double VolStep(){ double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); return (s>0?s:0.01); }
double VolMin() { return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN); }
double VolMax() { return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX); }
int    VolDigits(){ double s=VolStep(); int d=0; while(s<1.0&&d<8){s*=10.0;d++;} return d; }
int    HourNow(){ MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); return dt.hour; }

void ConfigureFilling()
{
   long m = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((m & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((m & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                                    trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

int CountMyPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      n++;
   }
   return n;
}

double NormalizeVol(double v, bool &underflow)
{
   underflow=false;
   double step=VolStep(), mn=VolMin(), mx=VolMax();
   v = MathFloor(v/step)*step;
   if(v<mn) { underflow=true; v = (InpUseMinLotIfUnderflow ? mn : 0.0); }
   if(v>mx) v = mx;
   return NormalizeDouble(v, VolDigits());
}

double ComputeLot(double sl_points)
{
   bool uf=false;
   if(InpLotMode==LOT_FIXED) return NormalizeVol(InpFixedLot, uf);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double risk=bal*(InpRiskPercent/100.0);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double p=Pt();
   if(tv<=0||ts<=0||p<=0||sl_points<=0) return NormalizeVol(InpFixedLot, uf);
   double pv = tv*(p/ts);
   double slm = sl_points*pv;
   if(slm<=0) return NormalizeVol(InpFixedLot, uf);
   double lot = risk/slm;
   double out = NormalizeVol(lot, uf);
   double margin=0;
   if(OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,out,Ask(),margin))
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.8) out=VolMin();
   return out;
}

double EnforceStopDistance(double points)
{
   double minp=(double)StopsLevelPts();
   return (points<minp ? minp : points);
}

bool GetEMA(double &fast, double &slow)
{
   double bF[2], bS[2];
   ArraySetAsSeries(bF,true); ArraySetAsSeries(bS,true);
   if(CopyBuffer(g_ema_fast,0,0,2,bF)<2) return false;
   if(CopyBuffer(g_ema_slow,0,0,2,bS)<2) return false;
   fast=bF[0]; slow=bS[0];
   return true;
}

double GetATRPoints()
{
   double a[2]; ArraySetAsSeries(a,true);
   if(CopyBuffer(g_atr,0,0,2,a)<2) return -1.0;
   double p=Pt(); if(p<=0) return -1.0;
   return a[0]/p;
}

int HTFTrend()
{
   if(!InpUseHTFTrend) return 0;
   double e[2]; ArraySetAsSeries(e,true);
   if(CopyBuffer(g_htf_ema,0,0,2,e)<2) return 0;
   double price = (Bid()+Ask())/2.0;
   if(price > e[0]) return +1;
   if(price < e[0]) return -1;
   return 0;
}

int GetSignal()
{
   double fast, slow;
   if(!GetEMA(fast,slow)) return 0;
   double mom = Bid() - g_prev_bid;
   bool up = (fast>slow);
   bool dn = (fast<slow);
   int htf = HTFTrend();
   if(up && mom>0.0 && (!InpUseHTFTrend || htf>=0)) return +1;
   if(dn && mom<0.0 && (!InpUseHTFTrend || htf<=0)) return -1;
   return 0;
}

bool DailyLossExceeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d",dt.year,dt.mon,dt.day));
   if(today!=g_daily_start_day)
     { g_daily_start_day=today; g_daily_start_balance=AccountInfoDouble(ACCOUNT_BALANCE); g_consec_losses=0; }
   if(g_daily_start_balance<=0) return false;
   double lossPct = (g_daily_start_balance - AccountInfoDouble(ACCOUNT_EQUITY))/g_daily_start_balance*100.0;
   if(lossPct >= InpMaxDailyLossPct)
     { if(InpVerboseLog) Print("DAILY LOSS ",DoubleToString(lossPct,2),"%"); return true; }
   return false;
}

bool MarginTooLow()
{
   double lvl = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   return (lvl>0 && lvl<InpMinMarginLevel);
}

bool InSession()
{
   int h=HourNow();
   if(InpSessionStartHour<=InpSessionEndHour)
      return (h>=InpSessionStartHour && h<InpSessionEndHour);
   return (h>=InpSessionStartHour || h<InpSessionEndHour);
}

bool FiltersPass(string &reason)
{
   if(DailyLossExceeded())                                      { reason="daily_loss"; return false; }
   if(MarginTooLow())                                           { reason="margin";     return false; }
   if(g_consec_losses>=InpMaxConsecLosses)                      { reason="consec_loss";return false; }
   if(!InSession())                                             { reason="session";    return false; }
   if(InpMaxSpreadPoints>0 && SpreadPts()>InpMaxSpreadPoints)   { reason="spread";     return false; }
   double atrp=GetATRPoints();
   if(atrp<0)                                                   { reason="atr_na";     return false; }
   if(InpMinATRPoints>0 && atrp<InpMinATRPoints)                { reason="atr_low";    return false; }
   if(InpMaxATRPoints>0 && atrp>InpMaxATRPoints)                { reason="atr_high";   return false; }
   if(g_prev_atr>0 && atrp > g_prev_atr*InpATRSpikeMult)        { reason="atr_spike";  g_prev_atr=atrp; return false; }
   g_prev_atr=atrp;
   if((TimeCurrent()-g_last_entry_time)<InpMinSecsBetweenTrades){ reason="cooldown";   return false; }
   if(CountMyPositions()>=InpMaxPositions)                      { reason="max_pos";    return false; }
   reason="ok";
   return true;
}

double CalcSLPoints()
{
   double atrp = GetATRPoints();
   if(atrp<=0) return (double)InpMinSLPoints;
   double sl = atrp*InpSL_ATR_Mult;
   if(sl<InpMinSLPoints) sl=InpMinSLPoints;
   if(sl>InpMaxSLPoints) sl=InpMaxSLPoints;
   return EnforceStopDistance(sl);
}

void JournalEntry(int dir, double lot, double price, int spread_pts, string label, long order)
{
   if(!InpUseJournal) return;
   int h=FileOpen(InpJournalFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0) FileWrite(h,"time","event","type","lot","price","spread","label","net","ticket");
   FileSeek(h,0,SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS), "ENTRY",
            (dir>0?"BUY":"SELL"), DoubleToString(lot,2), DoubleToString(price,_Digits),
            IntegerToString(spread_pts), label, "", IntegerToString(order));
   FileClose(h);
}

void JournalExit(ulong deal, string type_str, double lot, double price, int spread_pts, double net)
{
   if(!InpUseJournal) return;
   int h=FileOpen(InpJournalFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0) FileWrite(h,"time","event","type","lot","price","spread","label","net","ticket");
   FileSeek(h,0,SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS), "EXIT",
            type_str, DoubleToString(lot,2), DoubleToString(price,_Digits),
            IntegerToString(spread_pts), "", DoubleToString(net,2), IntegerToString((long)deal));
   FileClose(h);
}

void OpenTrade(int dir, string label)
{
   double sl_pts = CalcSLPoints();
   double tp_pts = EnforceStopDistance(sl_pts * InpRRRatio);
   double lot = ComputeLot(sl_pts);
   if(lot<=0) { if(InpVerboseLog) Print("Skip: lot=0"); return; }

   double p=Pt(), price, sl, tp;
   bool ok=false;
   if(dir>0)
   {
      price=Ask();
      sl = price - sl_pts*p;
      tp = price + tp_pts*p;
      ok = trade.Buy(lot,_Symbol,0.0, NormalizeDouble(sl,_Digits), NormalizeDouble(tp,_Digits), "MHV2");
   }
   else
   {
      price=Bid();
      sl = price + sl_pts*p;
      tp = price - tp_pts*p;
      ok = trade.Sell(lot,_Symbol,0.0, NormalizeDouble(sl,_Digits), NormalizeDouble(tp,_Digits), "MHV2");
   }

   if(ok)
   {
      g_last_entry_time = TimeCurrent();
      JournalEntry(dir, lot, trade.ResultPrice(), (int)SpreadPts(), label, (long)trade.ResultOrder());
      if(InpVerboseLog)
         Print("OPEN ",(dir>0?"BUY":"SELL")," lot=",DoubleToString(lot,2),
               " SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits));
   }
   else if(InpVerboseLog)
      Print("OPEN FAILED ret=", trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
}

void ManagePositions()
{
   double p=Pt(), bid=Bid(), ask=Ask();
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double cur = (type==POSITION_TYPE_BUY ? bid : ask);
      double profPts = (type==POSITION_TYPE_BUY ? (cur-open)/p : (open-cur)/p);
      double newSL = sl;

      if(InpUseBreakEven && profPts>=InpBETriggerPoints)
      {
         double be = (type==POSITION_TYPE_BUY ? open+InpBEOffsetPoints*p : open-InpBEOffsetPoints*p);
         if(type==POSITION_TYPE_BUY  && (sl==0||be>sl)) newSL=be;
         if(type==POSITION_TYPE_SELL && (sl==0||be<sl)) newSL=be;
      }
      if(InpUseTrailing && profPts>=InpTrailStartPoints)
      {
         double tr = (type==POSITION_TYPE_BUY ? cur-InpTrailDistancePoints*p : cur+InpTrailDistancePoints*p);
         if(type==POSITION_TYPE_BUY  && tr>newSL)               newSL=tr;
         if(type==POSITION_TYPE_SELL && (newSL==0||tr<newSL))   newSL=tr;
      }
      if(newSL!=sl && newSL!=0)
      {
         double mind = StopsLevelPts()*p;
         bool okd = (type==POSITION_TYPE_BUY ? (cur-newSL)>=mind : (newSL-cur)>=mind);
         if(okd) trade.PositionModify(t, NormalizeDouble(newSL,_Digits), tp);
      }
   }
}

void UpdateDisplay()
{
   double atrp=GetATRPoints();
   int htf=HTFTrend();
   string s =
      "=== MicroHunter V2 ===\n" +
      "Symbol      : " + _Symbol + "\n" +
      "Bid/Ask     : " + DoubleToString(Bid(),_Digits) + " / " + DoubleToString(Ask(),_Digits) + "\n" +
      "Spread (pt) : " + IntegerToString(SpreadPts()) + " (max "+IntegerToString(InpMaxSpreadPoints)+")\n" +
      "ATR (pt)    : " + (atrp<0?"n/a":DoubleToString(atrp,0)) + " (min "+IntegerToString(InpMinATRPoints)+")\n" +
      "HTF Trend   : " + (htf>0?"UP":(htf<0?"DOWN":"FLAT")) + "\n" +
      "Ticks/sec   : " + IntegerToString(g_ticks_per_sec) + "\n" +
      "Pos         : " + IntegerToString(CountMyPositions()) + "/" + IntegerToString(InpMaxPositions) + "\n" +
      "Signal      : " + g_last_signal + "\n" +
      "Trigger     : " + g_last_trigger + "\n" +
      "ConsecLoss  : " + IntegerToString(g_consec_losses) + "/" + IntegerToString(InpMaxConsecLosses) + "\n" +
      "--- Stats ---\n" +
      "Trades      : " + IntegerToString(g_total_trades) + "\n" +
      "W/L         : " + IntegerToString(g_wins) + " / " + IntegerToString(g_losses) + "\n" +
      "WinRate     : " + (g_total_trades>0?DoubleToString(100.0*g_wins/g_total_trades,1):"0.0") + "%\n" +
      "PF          : " + (g_gross_loss>0?DoubleToString(g_gross_profit/g_gross_loss,2):"-") + "\n";
   Comment(s);
}

int OnInit()
{
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   ConfigureFilling();

   g_ema_fast = iMA(_Symbol, InpEntryTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow = iMA(_Symbol, InpEntryTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_atr      = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   g_htf_ema  = iMA(_Symbol, InpHTFTimeframe, InpHTFEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_ema_fast==INVALID_HANDLE||g_ema_slow==INVALID_HANDLE||g_atr==INVALID_HANDLE||g_htf_ema==INVALID_HANDLE)
     { Print("Indicator init failed"); return INIT_FAILED; }

   g_prev_bid = Bid();
   g_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("MicroHunter V2 init | ",_Symbol," digits=",_Digits," bal=$",DoubleToString(g_daily_start_balance,2));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_ema_fast!=INVALID_HANDLE) IndicatorRelease(g_ema_fast);
   if(g_ema_slow!=INVALID_HANDLE) IndicatorRelease(g_ema_slow);
   if(g_atr!=INVALID_HANDLE)      IndicatorRelease(g_atr);
   if(g_htf_ema!=INVALID_HANDLE)  IndicatorRelease(g_htf_ema);
   Comment("");
   Print("MicroHunter V2 deinit | Trades=",g_total_trades," W=",g_wins," L=",g_losses);
}

void OnTick()
{
   g_tick_count++;
   datetime now=TimeCurrent();
   if(now!=g_last_sec){ g_ticks_per_sec=g_ticks_this_sec; g_ticks_this_sec=0; g_last_sec=now; }
   g_ticks_this_sec++;

   ManagePositions();

   int sig = GetSignal();
   g_last_signal = (sig>0?"BUY":(sig<0?"SELL":"WAIT"));

   string reason;
   if(FiltersPass(reason))
   {
      if(sig>0)      { g_last_trigger="BUY_NOW";  OpenTrade(+1,"BUY_NOW"); }
      else if(sig<0) { g_last_trigger="SELL_NOW"; OpenTrade(-1,"SELL_NOW"); }
      else             g_last_trigger="WAIT(no_signal)";
   }
   else g_last_trigger = "WAIT("+reason+")";

   UpdateDisplay();
   g_prev_bid = Bid();
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal=trans.deal; if(deal==0) return;
   datetime to=TimeCurrent()+60, from=to - 7*24*60*60;
   if(!HistorySelect(from,to)) return;
   if(HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) return;
   long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
   if(entry==DEAL_ENTRY_OUT||entry==DEAL_ENTRY_INOUT||entry==DEAL_ENTRY_OUT_BY)
   {
      double net = HistoryDealGetDouble(deal,DEAL_PROFIT)
                 + HistoryDealGetDouble(deal,DEAL_SWAP)
                 + HistoryDealGetDouble(deal,DEAL_COMMISSION);
      double lot=HistoryDealGetDouble(deal,DEAL_VOLUME);
      double price=HistoryDealGetDouble(deal,DEAL_PRICE);
      long dtype=HistoryDealGetInteger(deal,DEAL_TYPE);
      string closed=(dtype==DEAL_TYPE_SELL?"BUY":"SELL");
      g_total_trades++;
      if(net>=0) { g_wins++; g_gross_profit+=net; g_consec_losses=0; }
      else       { g_losses++; g_gross_loss+=(-net); g_consec_losses++; }
      JournalExit(deal, closed, lot, price, (int)SpreadPts(), net);
      if(InpVerboseLog) Print("EXIT ",closed," net=",DoubleToString(net,2)," consec=",g_consec_losses);
   }
}
//+------------------------------------------------------------------+
