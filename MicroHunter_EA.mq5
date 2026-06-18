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
input int      InpTimerSeconds     = 10;       // Timer Interval (seconds)
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

//+------------------------------------------------------------------+
//| MARKET STATE STRUCTURE (Self-Learning Core)                       |
//+------------------------------------------------------------------+
struct MarketState
  {
   int               trendDirection; // +1 buy, -1 sell
   double            rsi;            // RSI(14) value
   double            atr;            // ATR(14) value
   double            emaDist;        // price distance from mid EMA (normalized)
   int               sessionHour;    // hour of entry
   double            spread;         // spread at entry time
  };

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade            trade;
CPositionInfo     posInfo;
CAccountInfo      accInfo;
CSymbolInfo       symInfo;

int               handleFastEMA;
int               handleMidEMA;
int               handleSlowEMA;
int               handleRSI;
int               handleATR;

MarketState       FailedStates[];
MarketState       SuccessStates[];
int               failedCount = 0;
int               successCount = 0;

double            peakProfit[];      // track peak profit per position ticket
ulong             trackedTickets[];  // position tickets being tracked
MarketState       entryStates[];     // entry-time MarketState snapshot per tracked position

datetime          lastTradeTime = 0;
ulong             lastProcessedDeal = 0; // dedupe guard for CheckClosedDeals

//+------------------------------------------------------------------+
//| Expert initialization                                             |
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
     {
      Print("ERROR: Failed to create indicator handles");
      return(INIT_FAILED);
     }

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
         " | Timer: ", InpTimerSeconds, "s");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
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
//| Timer event — CORE 10-SECOND LOOP                                 |
//+------------------------------------------------------------------+
void OnTimer()
  {
   symInfo.Refresh();

   CheckClosedDeals();
   ManageOpenPositions();

   if(CountMyPositions() < InpMaxPositions)
      EvaluateEntry();
  }

//+------------------------------------------------------------------+
//| Also process on each tick for tighter trailing                    |
//+------------------------------------------------------------------+
void OnTick()
  {
   symInfo.Refresh();
   ManageOpenPositions();
  }

//+------------------------------------------------------------------+
//| COUNT POSITIONS WITH OUR MAGIC NUMBER                             |
//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == 777555)
            count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| GET INDICATOR VALUES                                              |
//+------------------------------------------------------------------+
bool GetIndicators(double &fastEMA, double &midEMA, double &slowEMA,
                   double &rsi, double &atr)
  {
   double bufFast[2], bufMid[2], bufSlow[2], bufRSI[2], bufATR[2];

   if(CopyBuffer(handleFastEMA, 0, 0, 2, bufFast) < 2) return false;
   if(CopyBuffer(handleMidEMA,  0, 0, 2, bufMid)  < 2) return false;
   if(CopyBuffer(handleSlowEMA, 0, 0, 2, bufSlow) < 2) return false;
   if(CopyBuffer(handleRSI,     0, 0, 2, bufRSI)  < 2) return false;
   if(CopyBuffer(handleATR,     0, 0, 2, bufATR)  < 2) return false;

   fastEMA = bufFast[1];
   midEMA  = bufMid[1];
   slowEMA = bufSlow[1];
   rsi     = bufRSI[1];
   atr     = bufATR[1];

   return true;
  }

//+------------------------------------------------------------------+
//| DETERMINE TREND DIRECTION                                         |
//+------------------------------------------------------------------+
int GetTrendDirection(double fastEMA, double midEMA, double slowEMA)
  {
   // Bullish: Fast > Mid > Slow (aligned uptrend)
   if(fastEMA > midEMA && midEMA > slowEMA)
      return +1;

   // Bearish: Fast < Mid < Slow (aligned downtrend)
   if(fastEMA < midEMA && midEMA < slowEMA)
      return -1;

   return 0; // No clear trend — do not trade
  }

//+------------------------------------------------------------------+
//| CAPTURE CURRENT MARKET STATE                                      |
//+------------------------------------------------------------------+
MarketState CaptureState(int direction, double rsi, double atr,
                         double price, double midEMA)
  {
   MarketState state;
   state.trendDirection = direction;
   state.rsi            = rsi;
   state.atr            = atr;
   state.emaDist        = (midEMA != 0) ? (price - midEMA) / midEMA * 10000.0 : 0;
   state.sessionHour    = TimeHour(TimeCurrent());
   state.spread         = symInfo.Spread() * symInfo.Point();
   return state;
  }

//+------------------------------------------------------------------+
//| EUCLIDEAN DISTANCE BETWEEN TWO STATES (normalized)                |
//+------------------------------------------------------------------+
double StateDistance(const MarketState &a, const MarketState &b)
  {
   double d = 0;

   // Direction mismatch = maximum distance
   if(a.trendDirection != b.trendDirection)
      return 1.0;

   // RSI: normalized to 0-100 range
   double dRSI = (a.rsi - b.rsi) / 100.0;
   d += dRSI * dRSI;

   // ATR: normalized by average
   double avgATR = (a.atr + b.atr) / 2.0;
   double dATR = (avgATR > 0) ? (a.atr - b.atr) / avgATR : 0;
   d += dATR * dATR;

   // EMA distance: already in pips-like units
   double dEMA = (a.emaDist - b.emaDist) / 100.0;
   d += dEMA * dEMA;

   // Session hour: normalized to 24h
   double dHour = (double)(a.sessionHour - b.sessionHour) / 24.0;
   d += dHour * dHour;

   // Result: 0 = identical, 1 = max different
   return MathSqrt(d / 4.0); // 4 components
  }

//+------------------------------------------------------------------+
//| SIMILARITY = 1 - distance                                         |
//+------------------------------------------------------------------+
double StateSimilarity(const MarketState &a, const MarketState &b)
  {
   return 1.0 - StateDistance(a, b);
  }

//+------------------------------------------------------------------+
//| CHECK IF CURRENT STATE MATCHES ANY FAILED STATE                   |
//+------------------------------------------------------------------+
bool IsFailedStateMatch(const MarketState &current)
  {
   if(!InpEnableLearning) return false;

   for(int i = 0; i < failedCount; i++)
     {
      double sim = StateSimilarity(current, FailedStates[i]);
      if(sim >= InpMatchThreshold)
        {
         Print("BLOCKED: Current state matches Failed State #", i,
               " (similarity: ", DoubleToString(sim * 100, 1), "%)");
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| CHECK IF CURRENT STATE MATCHES A SUCCESSFUL STATE                 |
//+------------------------------------------------------------------+
bool IsSuccessStateMatch(const MarketState &current)
  {
   if(!InpEnableLearning) return false;

   for(int i = 0; i < successCount; i++)
     {
      if(StateSimilarity(current, SuccessStates[i]) >= InpMatchThreshold)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| RECORD A TRADE OUTCOME STATE                                      |
//+------------------------------------------------------------------+
void RecordState(MarketState &state, bool isSuccess)
  {
   if(isSuccess)
     {
      if(successCount >= InpMaxStates)
        {
         // Remove oldest, shift array
         for(int i = 0; i < successCount - 1; i++)
            SuccessStates[i] = SuccessStates[i + 1];
         successCount--;
        }
      ArrayResize(SuccessStates, successCount + 1);
      SuccessStates[successCount] = state;
      successCount++;
      Print("STATE RECORDED: Success #", successCount, " RSI=", DoubleToString(state.rsi, 1),
            " ATR=", DoubleToString(state.atr, 6));
     }
   else
     {
      if(failedCount >= InpMaxStates)
        {
         for(int i = 0; i < failedCount - 1; i++)
            FailedStates[i] = FailedStates[i + 1];
         failedCount--;
        }
      ArrayResize(FailedStates, failedCount + 1);
      FailedStates[failedCount] = state;
      failedCount++;
      Print("STATE RECORDED: Failed #", failedCount, " RSI=", DoubleToString(state.rsi, 1),
            " ATR=", DoubleToString(state.atr, 6));
     }
  }

//+------------------------------------------------------------------+
//| CALCULATE DYNAMIC LOT SIZE                                        |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
  {
   double balance   = accInfo.Balance();
   double riskMoney = balance * InpRiskPercent / 100.0;

   // Cap at max risk
   double maxRisk   = balance * InpMaxRiskPercent / 100.0;
   if(riskMoney > maxRisk) riskMoney = maxRisk;

   double tickValue = symInfo.TickValue();
   double tickSize  = symInfo.TickSize();

   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0)
      return symInfo.LotsMin();

   double lotSize = riskMoney / (slPoints / tickSize * tickValue);

   // Normalize to broker limits
   double minLot  = symInfo.LotsMin();
   double maxLot  = symInfo.LotsMax();
   double lotStep = symInfo.LotsStep();

   lotSize = MathMax(minLot, lotSize);
   lotSize = MathMin(maxLot, lotSize);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;

   // Final safety: ensure margin is available
   double margin = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lotSize, symInfo.Ask(), margin))
      return minLot;

   if(margin > accInfo.FreeMargin() * 0.8)
      lotSize = minLot;

   return NormalizeDouble(lotSize, 2);
  }

//+------------------------------------------------------------------+
//| CALCULATE STOP LOSS IN POINTS                                     |
//+------------------------------------------------------------------+
double CalculateSLPoints(double atr)
  {
   double slPrice = atr * InpATRMultiplier;
   double maxSL   = InpMaxSLPips * symInfo.Point() * 10; // convert pips to price

   if(slPrice > maxSL)
      slPrice = maxSL;

   // Minimum SL must cover spread + buffer
   double minSL = symInfo.Spread() * symInfo.Point() * 2.0;
   if(slPrice < minSL)
      slPrice = minSL;

   return slPrice;
  }

//+------------------------------------------------------------------+
//| SESSION FILTER                                                    |
//+------------------------------------------------------------------+
bool IsWithinSession()
  {
   int hour = TimeHour(TimeCurrent());
   if(InpSessionStartHour <= InpSessionEndHour)
      return (hour >= InpSessionStartHour && hour < InpSessionEndHour);
   else
      return (hour >= InpSessionStartHour || hour < InpSessionEndHour);
  }

//+------------------------------------------------------------------+
//| SPREAD CHECK                                                      |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   double spreadPips = symInfo.Spread() * symInfo.Point() / (symInfo.Point() * 10);
   return (spreadPips <= InpMaxSpreadPips);
  }

//+------------------------------------------------------------------+
//| EVALUATE ENTRY — CORE DECISION LOGIC                              |
//+------------------------------------------------------------------+
void EvaluateEntry()
  {
   if(!IsWithinSession()) return;
   if(!IsSpreadAcceptable())
     {
      // Spread too wide — skip silently
      return;
     }

   // Minimum 10-second gap between trades
   if(TimeCurrent() - lastTradeTime < InpTimerSeconds)
      return;

   double fastEMA, midEMA, slowEMA, rsi, atr;
   if(!GetIndicators(fastEMA, midEMA, slowEMA, rsi, atr))
      return;

   int trend = GetTrendDirection(fastEMA, midEMA, slowEMA);
   if(trend == 0) return; // No aligned trend

   // RSI confirmation filter
   if(trend == +1 && rsi > 75) return; // Overbought — don't buy
   if(trend == -1 && rsi < 25) return; // Oversold — don't sell

   double price = (trend == +1) ? symInfo.Ask() : symInfo.Bid();

   // Capture current market state
   MarketState currentState = CaptureState(trend, rsi, atr, price, midEMA);

   // SELF-LEARNING FILTER: Block if matches a failed pattern
   if(IsFailedStateMatch(currentState))
      return;

   // High-confidence boost: log when state matches a known winner
   bool highConfidence = IsSuccessStateMatch(currentState);
   if(highConfidence)
      Print("HIGH-CONFIDENCE: Current state matches a known successful pattern");

   // Calculate SL and TP
   double slPoints = CalculateSLPoints(atr);
   double tpPoints = slPoints * InpRRRatio;
   double lotSize  = CalculateLotSize(slPoints);

   double sl, tp;

   if(trend == +1) // BUY
     {
      sl = symInfo.Ask() - slPoints;
      tp = symInfo.Ask() + tpPoints;

      sl = NormalizeDouble(sl, symInfo.Digits());
      tp = NormalizeDouble(tp, symInfo.Digits());

      if(trade.Buy(lotSize, _Symbol, symInfo.Ask(), sl, tp, "MicroHunter BUY"))
        {
         lastTradeTime = TimeCurrent();
         TrackNewPosition(currentState);
         Print("BUY opened | Lot=", lotSize, " SL=", sl, " TP=", tp,
               " RSI=", DoubleToString(rsi, 1), " ATR=", DoubleToString(atr, 6));
        }
      else
         Print("BUY FAILED: ", trade.ResultRetcodeDescription());
     }
   else // SELL
     {
      sl = symInfo.Bid() + slPoints;
      tp = symInfo.Bid() - tpPoints;

      sl = NormalizeDouble(sl, symInfo.Digits());
      tp = NormalizeDouble(tp, symInfo.Digits());

      if(trade.Sell(lotSize, _Symbol, symInfo.Bid(), sl, tp, "MicroHunter SELL"))
        {
         lastTradeTime = TimeCurrent();
         TrackNewPosition(currentState);
         Print("SELL opened | Lot=", lotSize, " SL=", sl, " TP=", tp,
               " RSI=", DoubleToString(rsi, 1), " ATR=", DoubleToString(atr, 6));
        }
      else
         Print("SELL FAILED: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| TRACK POSITION FOR TRAILING + STORE ENTRY STATE                   |
//+------------------------------------------------------------------+
void TrackPosition(ulong ticket, const MarketState &entryState)
  {
   int size = ArraySize(trackedTickets);
   ArrayResize(trackedTickets, size + 1);
   ArrayResize(peakProfit, size + 1);
   ArrayResize(entryStates, size + 1);
   trackedTickets[size] = ticket;
   peakProfit[size]     = 0;
   entryStates[size]    = entryState;
  }

//+------------------------------------------------------------------+
//| TRACK NEW POSITION — resolve the position ticket from result      |
//+------------------------------------------------------------------+
void TrackNewPosition(const MarketState &entryState)
  {
   // Resolve position ticket from the deal that opened it
   ulong dealTicket = trade.ResultDeal();
   ulong positionId = 0;

   if(dealTicket != 0 && HistoryDealSelect(dealTicket))
      positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   if(positionId == 0)
     {
      // Fallback: latest position on this symbol with our magic
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(posInfo.SelectByIndex(i) &&
            posInfo.Symbol() == _Symbol &&
            posInfo.Magic() == 777555)
           {
            positionId = posInfo.Ticket();
            break;
           }
        }
     }

   if(positionId != 0)
      TrackPosition(positionId, entryState);
  }

//+------------------------------------------------------------------+
//| TRACK POSITION WITHOUT ENTRY STATE (recovery / orphan)            |
//+------------------------------------------------------------------+
void TrackPositionOrphan(ulong ticket)
  {
   MarketState empty;
   empty.trendDirection = 0;
   empty.rsi = 0; empty.atr = 0; empty.emaDist = 0;
   empty.sessionHour = -1; empty.spread = 0;
   TrackPosition(ticket, empty);
  }

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITIONS — BREAKEVEN + RATCHET TRAILING              |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != 777555) continue;

      double openPrice  = posInfo.PriceOpen();
      double currentSL  = posInfo.StopLoss();
      double currentTP  = posInfo.PriceCurrent();
      double profit     = posInfo.Profit();
      double spread     = symInfo.Spread() * symInfo.Point();
      ulong  ticket     = posInfo.Ticket();

      // Find peak profit index
      int idx = -1;
      for(int j = 0; j < ArraySize(trackedTickets); j++)
        {
         if(trackedTickets[j] == ticket) { idx = j; break; }
        }

      if(idx < 0)
        {
         TrackPositionOrphan(ticket);
         idx = ArraySize(trackedTickets) - 1;
        }

      // Update peak profit
      if(profit > peakProfit[idx])
         peakProfit[idx] = profit;

      bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);
      double currentPrice = isBuy ? symInfo.Bid() : symInfo.Ask();

      // === BREAKEVEN TRIGGER ===
      double beTrigger = spread * InpBEMultiplier;
      double priceDiff = isBuy ? (currentPrice - openPrice) : (openPrice - currentPrice);

      if(priceDiff >= beTrigger)
        {
         double beLevel;
         if(isBuy)
            beLevel = openPrice + spread + symInfo.Point();
         else
            beLevel = openPrice - spread - symInfo.Point();

         beLevel = NormalizeDouble(beLevel, symInfo.Digits());

         // Only move SL forward, never backward
         if(isBuy && (currentSL < beLevel || currentSL == 0))
           {
            if(trade.PositionModify(ticket, beLevel, posInfo.TakeProfit()))
               Print("BREAKEVEN set for BUY #", ticket, " SL -> ", beLevel);
           }
         else if(!isBuy && (currentSL > beLevel || currentSL == 0))
           {
            if(trade.PositionModify(ticket, beLevel, posInfo.TakeProfit()))
               Print("BREAKEVEN set for SELL #", ticket, " SL -> ", beLevel);
           }
        }

      // === RATCHET TRAILING STOP (Lock 70% of peak profit) ===
      if(peakProfit[idx] > 0 && profit > 0)
        {
         double lockPips   = priceDiff * (InpTrailLockPct / 100.0);
         double trailLevel;

         if(isBuy)
            trailLevel = openPrice + lockPips;
         else
            trailLevel = openPrice - lockPips;

         trailLevel = NormalizeDouble(trailLevel, symInfo.Digits());

         // Ratchet: only move forward
         if(isBuy && trailLevel > currentSL && trailLevel > openPrice)
           {
            if(trade.PositionModify(ticket, trailLevel, posInfo.TakeProfit()))
               Print("TRAIL LOCK BUY #", ticket, " SL -> ", trailLevel,
                     " (locked ", DoubleToString(InpTrailLockPct, 0), "% of peak)");
           }
         else if(!isBuy && (trailLevel < currentSL || currentSL == 0) && trailLevel < openPrice)
           {
            if(trade.PositionModify(ticket, trailLevel, posInfo.TakeProfit()))
               Print("TRAIL LOCK SELL #", ticket, " SL -> ", trailLevel,
                     " (locked ", DoubleToString(InpTrailLockPct, 0), "% of peak)");
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| CHECK RECENTLY CLOSED DEALS — LEARN FROM OUTCOMES                 |
//+------------------------------------------------------------------+
void CheckClosedDeals()
  {
   if(!InpEnableLearning) return;

   datetime from = TimeCurrent() - InpTimerSeconds * 3; // check last few cycles
   datetime to   = TimeCurrent();

   if(!HistorySelect(from, to)) return;

   int totalDeals = HistoryDealsTotal();
   ulong maxDealSeen = lastProcessedDeal;

   for(int i = 0; i < totalDeals; i++) // oldest -> newest
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      // DEDUPE: skip deals already processed
      if(dealTicket <= lastProcessedDeal) continue;

      if(dealTicket > maxDealSeen) maxDealSeen = dealTicket;

      // Only our EA's deals
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != 777555) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;

      // Only closing deals (DEAL_ENTRY_OUT)
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double dealComm   = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double dealSwap   = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double netResult  = dealProfit + dealComm + dealSwap;

      ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

      // Find the stored ENTRY-TIME state for this position
      int idx = -1;
      for(int j = 0; j < ArraySize(trackedTickets); j++)
        {
         if(trackedTickets[j] == posId) { idx = j; break; }
        }

      // Only record if we have the actual entry state (not an orphan with sessionHour=-1)
      if(idx >= 0 && entryStates[idx].sessionHour >= 0)
        {
         if(netResult < 0)
            RecordState(entryStates[idx], false); // LOSS -> failed state
         else if(netResult > 0)
            RecordState(entryStates[idx], true);  // WIN -> success state
        }

      // Remove from tracking
      if(idx >= 0)
        {
         int n = ArraySize(trackedTickets);
         for(int k = idx; k < n - 1; k++)
           {
            trackedTickets[k] = trackedTickets[k + 1];
            peakProfit[k]     = peakProfit[k + 1];
            entryStates[k]    = entryStates[k + 1];
           }
         ArrayResize(trackedTickets, n - 1);
         ArrayResize(peakProfit, n - 1);
         ArrayResize(entryStates, n - 1);
        }
     }

   lastProcessedDeal = maxDealSeen;
  }

//+------------------------------------------------------------------+
//| SAVE LEARNED STATES TO FILE                                       |
//+------------------------------------------------------------------+
void SaveStatesToFile()
  {
   int fileHandle = FileOpen("MicroHunter_States.bin", FILE_WRITE | FILE_BIN);
   if(fileHandle == INVALID_HANDLE)
     {
      Print("WARNING: Cannot save states to file");
      return;
     }

   // Write failed states
   FileWriteInteger(fileHandle, failedCount);
   for(int i = 0; i < failedCount; i++)
     {
      FileWriteInteger(fileHandle, FailedStates[i].trendDirection);
      FileWriteDouble(fileHandle, FailedStates[i].rsi);
      FileWriteDouble(fileHandle, FailedStates[i].atr);
      FileWriteDouble(fileHandle, FailedStates[i].emaDist);
      FileWriteInteger(fileHandle, FailedStates[i].sessionHour);
      FileWriteDouble(fileHandle, FailedStates[i].spread);
     }

   // Write success states
   FileWriteInteger(fileHandle, successCount);
   for(int i = 0; i < successCount; i++)
     {
      FileWriteInteger(fileHandle, SuccessStates[i].trendDirection);
      FileWriteDouble(fileHandle, SuccessStates[i].rsi);
      FileWriteDouble(fileHandle, SuccessStates[i].atr);
      FileWriteDouble(fileHandle, SuccessStates[i].emaDist);
      FileWriteInteger(fileHandle, SuccessStates[i].sessionHour);
      FileWriteDouble(fileHandle, SuccessStates[i].spread);
     }

   FileClose(fileHandle);
   Print("States saved: Failed=", failedCount, " Success=", successCount);
  }

//+------------------------------------------------------------------+
//| LOAD LEARNED STATES FROM FILE                                     |
//+------------------------------------------------------------------+
void LoadStatesFromFile()
  {
   if(!FileIsExist("MicroHunter_States.bin"))
     {
      Print("No previous states file found — starting fresh");
      return;
     }

   int fileHandle = FileOpen("MicroHunter_States.bin", FILE_READ | FILE_BIN);
   if(fileHandle == INVALID_HANDLE) return;

   bool corrupted = false;

   // Read failed states header
   if(FileIsEnding(fileHandle)) { FileClose(fileHandle); return; }
   failedCount = FileReadInteger(fileHandle);
   if(failedCount < 0 || failedCount > InpMaxStates)
     {
      Print("WARNING: failedCount out of range (", failedCount, ") — resetting");
      failedCount = 0; corrupted = true;
     }
   ArrayResize(FailedStates, failedCount);

   for(int i = 0; i < failedCount && !corrupted; i++)
     {
      if(FileIsEnding(fileHandle)) { failedCount = i; corrupted = true; break; }
      FailedStates[i].trendDirection = FileReadInteger(fileHandle);
      FailedStates[i].rsi            = FileReadDouble(fileHandle);
      FailedStates[i].atr            = FileReadDouble(fileHandle);
      FailedStates[i].emaDist        = FileReadDouble(fileHandle);
      FailedStates[i].sessionHour    = FileReadInteger(fileHandle);
      FailedStates[i].spread         = FileReadDouble(fileHandle);
     }

   // Read success states header
   if(corrupted || FileIsEnding(fileHandle))
     {
      successCount = 0;
      ArrayResize(SuccessStates, 0);
      FileClose(fileHandle);
      Print("States loaded (truncated): Failed=", failedCount, " Success=0");
      return;
     }

   successCount = FileReadInteger(fileHandle);
   if(successCount < 0 || successCount > InpMaxStates)
     {
      Print("WARNING: successCount out of range (", successCount, ") — resetting");
      successCount = 0;
     }
   ArrayResize(SuccessStates, successCount);

   for(int i = 0; i < successCount; i++)
     {
      if(FileIsEnding(fileHandle)) { successCount = i; ArrayResize(SuccessStates, i); break; }
      SuccessStates[i].trendDirection = FileReadInteger(fileHandle);
      SuccessStates[i].rsi            = FileReadDouble(fileHandle);
      SuccessStates[i].atr            = FileReadDouble(fileHandle);
      SuccessStates[i].emaDist        = FileReadDouble(fileHandle);
      SuccessStates[i].sessionHour    = FileReadInteger(fileHandle);
      SuccessStates[i].spread         = FileReadDouble(fileHandle);
     }

   FileClose(fileHandle);
   Print("States loaded: Failed=", failedCount, " Success=", successCount);
  }

//+------------------------------------------------------------------+
//| UTILITY: Extract hour from datetime                               |
//+------------------------------------------------------------------+
int TimeHour(datetime time)
  {
   MqlDateTime dt;
   TimeToStruct(time, dt);
   return dt.hour;
  }
//+------------------------------------------------------------------+
