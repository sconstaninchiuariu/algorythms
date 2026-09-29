//+------------------------------------------------------------------+
//|                                              LiquidityAlgo.mq5   |
//|  Port of the "Liquidity Algo v2" Pine Script strategy to MQL5.   |
//|                                                                    |
//|  Ported for backtesting depth only: MetaTrader 5's Strategy       |
//|  Tester typically keeps far more M1 history per symbol than       |
//|  TradingView's free/basic intraday forex feeds, which is the      |
//|  whole reason for this port (see chat: TradingView capped M1      |
//|  history to ~10 days for this symbol/plan).                       |
//|                                                                    |
//|  Everything VISUAL from the Pine version (POI lines, the CE       |
//|  marker, the checklist/info/stats tables, alerts) is intentionally|
//|  NOT ported — none of that affects trading logic, and MT5's own   |
//|  Strategy Tester report (Results / Graph / Report tabs) already   |
//|  gives you the equity curve, win rate, profit factor, drawdown,   |
//|  and trade list that those Pine tables were approximating.        |
//|                                                                    |
//|  The TRADING LOGIC below mirrors the final, validated Pine        |
//|  version bar-for-bar:                                             |
//|    1. A liquidity level (PDH/PDL, PWH/PWL,                        |
//|       EQH/EQL) is crossed for the first time this period -> the   |
//|       sweep arms (state 1 = bearish setup, state 2 = bullish).    |
//|    2. The CE (cambio estructural) is the swing that STARTED the  |
//|       final leg into the liquidity: the low the last push up      |
//|       began from (short) / the high the last push down began from |
//|       (long). A pullback counts as a leg start only if it is at   |
//|       least CeLegPct % of the leg that followed AND CeMinAtr x    |
//|       ATR14. It moves only when a candle CLOSES beyond the current |
//|       extreme (wicks beyond it are annulled) and the new push's   |
//|       own starting swing is more recent (see CeRef).              |
//|    3. Price closing back through the CE level confirms the break |
//|       -> a PENDING entry (state 3/4): SL/TP are already frozen to |
//|       the reaction's real wick extreme, and the order fires the   |
//|       moment London or New York is next open (bounded by the same |
//|       MssMaxBars-from-sweep deadline used for the earlier hunt).  |
//|    4. Position size comes from the tiered risk ladder (1.00% up   |
//|       to 1.55%, one step per consecutive loss, reset to 1.00% on  |
//|       a win) applied to FixedCapital, divided by the real stop    |
//|       distance in price.                                          |
//+------------------------------------------------------------------+
#property copyright "Liquidity Algo"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//======================================================================
// INPUTS
//======================================================================

input group "=== Market Sessions (broker/server time) ==="
input int    AsiaOpenHour     = 0;
input int    AsiaCloseHour    = 8;
input int    LondonOpenHour   = 9;
input int    LondonCloseHour  = 11;
input int    NYOpenHour       = 14;
input int    NYCloseHour      = 16;
input int    NYCloseMinute    = 30;
// If your broker's server time isn't UTC+2 (what the Pine version assumed,
// matching typical FXCM/OANDA chart time), set the real offset here so the
// session windows above land on the same real-world hours. E.g. if your
// server is UTC+3, set ServerUtcOffsetHours = 3 - 2 = 1.
input int    ServerUtcOffsetHours = 0;

input group "=== Liquidity Levels ==="
input bool   UsePDHL       = true;
input bool   UsePWHL       = true;
input bool   UseEQL        = true;
input double SweepBuffer   = 0.0002;   // SL padding beyond the sweep wick

input group "=== Equal Highs / Lows ==="
input double EqlTolerance      = 0.0005;
input int    EqlPivotStrength  = 10;     // bars each side, like Pine's sw_len
input int    EqlLookbackPivots = 5;
input ENUM_TIMEFRAMES EqlRefTF = PERIOD_M15;

input group "=== Structure (CE) ==="
input double CeLegPct      = 25.0; // CE: min pullback, % of the final leg that followed it
input double CeDispAtr     = 0.75; // CE: a displacement candle (body >= this x ATR) that made the extreme may use its own wick
input int    CeContBars    = 8;    // CE: a swing is "established" once this many candles old ...
input double CeContAtr     = 2.0;  // ... and separated from now by a pullback of this many ATR (wick beyond it = retest, annulled)
input double CeMinAtr      = 1.0;  // CE: min pullback, x ATR(14) of M1 (Wilder, like Pine ta.atr)
input int    CeScanBars    = 60;   // CE: how far back from the extreme the leg start is searched
input int    MssMaxBars    = 150;  // whole-cycle deadline (sweep -> break -> session), in M1 bars

input group "=== Risk Management ==="
input double RRRatio        = 2.0;
input double MaxSL          = 0.0050;
input double MinSL          = 0.0003;
input bool   CapSLToMax     = true;
input int    MaxTradesPerDay     = 4;
input int    MaxTradesPerSession = 2;   // London and NY each, independently
input double FixedCapital   = 100000;   // non-compounded risk base

input group "=== Tiered Risk (% of FixedCapital, one step per loss) ==="
input double Risk1 = 1.00;
input double Risk2 = 1.11;
input double Risk3 = 1.22;
input double Risk4 = 1.33;
input double Risk5 = 1.44;
input double Risk6 = 1.55;

input group "=== Misc ==="
input ulong  MagicNumber = 20260902;

//======================================================================
// STATE (persists across ticks, mirrors Pine's `var`)
//======================================================================

// 0 = IDLE | 1 = BEAR_SWEPT (hunting bearish CE) | 2 = BULL_SWEPT (hunting bullish CE)
// 3 = PENDING SHORT (CE broken, waiting for session) | 4 = PENDING LONG
int      state          = 0;
datetime sweepBarTime    = 0;
datetime mssBarTime      = 0;

// The session the CURRENT cycle armed in, captured once at the sweep. Used
// to abandon the cycle the instant that specific session ends instead of
// letting it wait across the gap into the next one.
bool     cycSessAsia = false, cycSessLondon = false, cycSessNy = false;

double   sweepHi = 0, sweepLo = 0;           // wick extreme since the sweep (stop anchor)
double   mssRefBear = 0, mssRefBull = 0;     // the CE level itself
datetime mssRefBarTime = 0;                  // which M1 bar the CE level currently sits on
double   ceExtHi = 0, ceExtLo = 0;           // extreme the CE is measured from (deepest wick of the swing)
datetime ceExtHiT = 0, ceExtLoT = 0;         // candle that printed it
double   atrM1 = 0; int atrCount = 0; double trSum = 0;  // Wilder ATR(14) on M1
double   activeSweepPx = 0;

int      attempt = 1;

int      lastDay = -1;
int      tradesToday = 0;
int      lonSessionTrades = 0;
int      nySessionTrades = 0;

bool     prevInLondon = false;
bool     prevInNy = false;

// Structural levels + their "already swept this period" flags, mirroring
// pdh_swept / pwh_swept / eqh_swept in the Pine version.
double   pdh = 0, pdl = 0;           bool pdhSwept = false, pdlSwept = false;
double   pwh = 0, pwl = 0;           bool pwhSwept = false, pwlSwept = false;
double   lastEqh = 0, lastEql = 0;   bool eqhSwept = false, eqlSwept = false;
bool     haveEqh = false, haveEql = false;


// Equal-highs/lows pivot history (price only; that's all Pine's swh_hist/
// swl_hist tracked too).
double   swhHist[];
double   swlHist[];

datetime lastSeenFormingBar = 0;  // shift-0 (still forming) M1 bar's open time
datetime lastProcessedM1Bar = 0;  // shift-1 (last CLOSED) M1 bar we've already run

//======================================================================
// UTILITIES
//======================================================================

// Fetch M1 candle data as a time series (shift 0 = most recently CLOSED M1
// bar being processed this cycle, shift 1 = the one before it, ...),
// matching the way the Pine version reads close/close[1]/close[2].
struct M1Bar { double o,h,l,c; datetime t; };

bool GetM1(int shift, M1Bar &out)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, shift, 1, r) != 1) return false;
   out.o = r[0].open; out.h = r[0].high; out.l = r[0].low; out.c = r[0].close; out.t = r[0].time;
   return true;
  }

int HourOf(datetime t)  { MqlDateTime s; TimeToStruct(t, s); int h = s.hour + ServerUtcOffsetHours; if(h<0) h+=24; if(h>=24) h-=24; return h; }
int MinuteOf(datetime t){ MqlDateTime s; TimeToStruct(t, s); return s.min; }
int DayOf(datetime t)   { MqlDateTime s; TimeToStruct(t, s); return s.year*10000 + s.mon*100 + s.day; }

bool InLondon(datetime t)
  {
   int h = HourOf(t);
   return h >= LondonOpenHour && h < LondonCloseHour;
  }

bool InNy(datetime t)
  {
   int h = HourOf(t), m = MinuteOf(t);
   bool closed = (h > NYCloseHour) || (h == NYCloseHour && m >= NYCloseMinute);
   return h >= NYOpenHour && !closed;
  }

bool InAsia(datetime t)
  {
   int h = HourOf(t);
   if(AsiaOpenHour <= AsiaCloseHour) return h >= AsiaOpenHour && h < AsiaCloseHour;
   return h >= AsiaOpenHour || h < AsiaCloseHour; // wraps past midnight
  }

//======================================================================
// STRUCTURAL LEVELS: PDH/PDL, PWH/PWL, EQH/EQL
//======================================================================

void UpdatePdhPdl()
  {
   // Previous COMPLETED daily bar's high/low. Reset the "swept" flag once
   // per new day (like Pine's is_new_day gate).
   static int lastPdhDay = -1;
   MqlDateTime s; TimeToStruct(TimeCurrent(), s);
   int today = s.year*10000 + s.mon*100 + s.day;
   if(today != lastPdhDay)
     {
      lastPdhDay = today;
      pdh = iHigh(_Symbol, PERIOD_D1, 1);
      pdl = iLow(_Symbol, PERIOD_D1, 1);
      pdhSwept = false; pdlSwept = false;
     }
  }

void UpdatePwhPwl()
  {
   static int lastPwhWeek = -1;
   MqlDateTime s; TimeToStruct(TimeCurrent(), s);
   // ISO-ish week id: year*100 + week-of-year approximation via day_of_year/7
   int weekId = s.year*100 + (s.day_of_year/7);
   if(weekId != lastPwhWeek)
     {
      lastPwhWeek = weekId;
      pwh = iHigh(_Symbol, PERIOD_W1, 1);
      pwl = iLow(_Symbol, PERIOD_W1, 1);
      pwhSwept = false; pwlSwept = false;
     }
  }


// Equal highs/lows: simple pivot-high/pivot-low check on EqlRefTF, grouped
// by EqlTolerance, mirroring the Pine version's swh_hist/swl_hist logic.
bool IsPivotHigh(int shift, double &val)
  {
   double h = iHigh(_Symbol, EqlRefTF, shift);
   for(int i=1;i<=EqlPivotStrength;i++)
     {
      if(iHigh(_Symbol, EqlRefTF, shift-i) >= h) return false;
      if(iHigh(_Symbol, EqlRefTF, shift+i) >= h) return false;
     }
   val = h;
   return true;
  }
bool IsPivotLow(int shift, double &val)
  {
   double l = iLow(_Symbol, EqlRefTF, shift);
   for(int i=1;i<=EqlPivotStrength;i++)
     {
      if(iLow(_Symbol, EqlRefTF, shift-i) <= l) return false;
      if(iLow(_Symbol, EqlRefTF, shift+i) <= l) return false;
     }
   val = l;
   return true;
  }

void UpdateEqlOnNewRefBar()
  {
   if(!UseEQL) return;
   static datetime lastRefBar = 0;
   datetime refT = iTime(_Symbol, EqlRefTF, 0);
   if(refT == lastRefBar) return;
   lastRefBar = refT;

   double v;
   if(IsPivotHigh(EqlPivotStrength, v))
     {
      for(int i=0;i<ArraySize(swhHist);i++)
         if(MathAbs(v - swhHist[i]) <= EqlTolerance) { lastEqh = v; haveEqh = true; eqhSwept = false; break; }
      int n = ArraySize(swhHist);
      if(n >= EqlLookbackPivots) { for(int i=0;i<n-1;i++) swhHist[i]=swhHist[i+1]; ArrayResize(swhHist, n-1); }
      ArrayResize(swhHist, ArraySize(swhHist)+1);
      swhHist[ArraySize(swhHist)-1] = v;
     }
   if(IsPivotLow(EqlPivotStrength, v))
     {
      for(int i=0;i<ArraySize(swlHist);i++)
         if(MathAbs(v - swlHist[i]) <= EqlTolerance) { lastEql = v; haveEql = true; eqlSwept = false; break; }
      int n = ArraySize(swlHist);
      if(n >= EqlLookbackPivots) { for(int i=0;i<n-1;i++) swlHist[i]=swlHist[i+1]; ArrayResize(swlHist, n-1); }
      ArrayResize(swlHist, ArraySize(swlHist)+1);
      swlHist[ArraySize(swlHist)-1] = v;
     }
  }

//======================================================================
// CE REFERENCE — mirrors Pine's f_ce_ref exactly.
//======================================================================
// Walking back from the extreme (shift eShift; 1 = the bar being processed),
// the running low (short setup) / high (long setup) is the candidate; it
// becomes the CE as soon as an older candle stands far enough beyond it:
//   pullback >= max(CeLegPct % of the leg that followed, CeMinAtr x ATR14).
// Returns 1 = found, 0 = no pullback qualified (level = deepest point of the
// window), -1 = no data.
int CeRef(bool isBear, int eShift, double &level, datetime &lvlTime)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(_Symbol, PERIOD_M1, 0, eShift + CeScanBars + 1, r);
   if(got <= eShift + 3) return -1;
   double ext = isBear ? r[eShift].high : r[eShift].low;
   // The search starts at the candle BEFORE the extreme (its own opposite wick
   // is part of the reversal) - except a DISPLACEMENT candle in the push
   // direction (body >= CeDispAtr x ATR): it is the move itself, so its own
   // opposite wick is the start of the leg.
   bool own = (isBear ? r[eShift].close > r[eShift].open : r[eShift].close < r[eShift].open)
              && MathAbs(r[eShift].close - r[eShift].open) >= CeDispAtr * atrM1;
   int  mIdx = own ? eShift : eShift + 1;
   double m   = isBear ? r[mIdx].low : r[mIdx].high;
   datetime mt = r[mIdx].time;
   // A swing needs a real reaction: at least one candle in the pullback must
   // close in its direction (bearish for the dip that forms a short's CE low,
   // bullish for the bounce that forms a long's CE high).
   bool rev = own ? false : (isBear ? (r[mIdx].close < r[mIdx].open) : (r[mIdx].close > r[mIdx].open));
   int found = 0;
   for(int i = mIdx + 1; i < got; i++)
     {
      rev = rev || (isBear ? (r[i].close < r[i].open) : (r[i].close > r[i].open));
      double thr = MathMax(MathAbs(ext - m) * CeLegPct / 100.0, CeMinAtr * atrM1);
      double cm  = isBear ? r[i].high - m : m - r[i].low;
      if(cm > 0 && cm >= thr && rev)
        {
         found = 1;
         // The candle that closes the pullback is part of the base: its own
         // wick counts if it went deeper.
         if(isBear ? r[i].low < m : r[i].high > m) { m = isBear ? r[i].low : r[i].high; mt = r[i].time; }
         break;
        }
      if(isBear ? r[i].low < m : r[i].high > m)
        {
         m = isBear ? r[i].low : r[i].high; mt = r[i].time;
         rev = isBear ? (r[i].close < r[i].open) : (r[i].close > r[i].open);
        }
     }
   level = m; lvlTime = mt;
   return found;
  }

// Is the swing at `level` (printed on levelT) an established structure: at
// least CeContBars candles old and separated from the processed bar (shift 1)
// by a pullback of at least CeContAtr x ATR? rising: the level is a high.
// Same definition as Pine's f_swing_sig.
bool SwingSig(bool rising, double level, datetime levelT)
  {
   int sh = iBarShift(_Symbol, PERIOD_M1, levelT, false);
   int span = sh - 1;
   if(sh < 0 || span < CeContBars) return false;
   int n = MathMin(span - 1, 495);
   if(n < 1) return false;
   MqlRates q[];
   ArraySetAsSeries(q, true);
   if(CopyRates(_Symbol, PERIOD_M1, 2, n, q) != n) return false;
   double depth = 0;
   for(int k = 0; k < n; k++)
     {
      double d = rising ? level - q[k].low : q[k].high - level;
      if(d > depth) depth = d;
     }
   return depth >= CeContAtr * atrM1;
  }

// Wilder ATR(14) of M1, updated once per processed bar (Pine ta.atr).
void UpdateAtr(const M1Bar &bar)
  {
   double tr = bar.h - bar.l;
   M1Bar p;
   if(GetM1(2, p)) tr = MathMax(tr, MathMax(MathAbs(bar.h - p.c), MathAbs(bar.l - p.c)));
   if(atrCount < 14) { trSum += tr; atrCount++; atrM1 = trSum / atrCount; }
   else atrM1 = (atrM1 * 13.0 + tr) / 14.0;
  }

//======================================================================
// POSITION SIZING (tiered risk ladder)
//======================================================================

double RiskForAttempt(int a)
  {
   switch(a)
     {
      case 1: return Risk1/100.0;
      case 2: return Risk2/100.0;
      case 3: return Risk3/100.0;
      case 4: return Risk4/100.0;
      case 5: return Risk5/100.0;
      default: return Risk6/100.0;
     }
  }

double CalcLots(double slDistancePrice)
  {
   if(slDistancePrice <= 0) return 0;
   double riskAmount = FixedCapital * RiskForAttempt(attempt);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return 0;
   double lots = riskAmount / (slDistancePrice / tickSize * tickValue);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots/lotStep)*lotStep;
   if(lots < minLot) lots = 0; // too small to size correctly -> skip, mirrors qty>0 guard
   if(lots > maxLot) lots = maxLot;
   return lots;
  }

// After a position closes, roll the attempt counter: win -> back to 1,
// loss -> one step up (capped at 6). Mirrors the Pine was_in_trade block.
void UpdateAttemptFromLastDeal()
  {
   if(!HistorySelect(TimeCurrent()-86400*3, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   if(total == 0) return;
   ulong lastDealTicket = 0; datetime lastDealTime = 0;
   for(int i=0;i<total;i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      datetime dt = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      if(dt > lastDealTime) { lastDealTime = dt; lastDealTicket = ticket; }
     }
   static datetime handledUpTo = 0;
   if(lastDealTicket == 0 || lastDealTime <= handledUpTo) return;
   handledUpTo = lastDealTime;
   double profit = HistoryDealGetDouble(lastDealTicket, DEAL_PROFIT)
                  + HistoryDealGetDouble(lastDealTicket, DEAL_SWAP)
                  + HistoryDealGetDouble(lastDealTicket, DEAL_COMMISSION);
   attempt = (profit > 0) ? 1 : MathMin(attempt+1, 6);
  }

//======================================================================
// SWEEP DETECTION — first bar price crosses a level this period.
//======================================================================


bool AnyHighSweep(const M1Bar &bar, double &leveOut)
  {
   if(UsePDHL && pdh>0 && !pdhSwept && bar.h >= pdh) { pdhSwept=true; leveOut=pdh; return true; }
   if(UsePWHL && pwh>0 && !pwhSwept && bar.h >= pwh) { pwhSwept=true; leveOut=pwh; return true; }
   if(UseEQL && haveEqh && !eqhSwept && bar.h >= lastEqh) { eqhSwept=true; leveOut=lastEqh; return true; }
   return false;
  }
bool AnyLowSweep(const M1Bar &bar, double &leveOut)
  {
   if(UsePDHL && pdl>0 && !pdlSwept && bar.l <= pdl) { pdlSwept=true; leveOut=pdl; return true; }
   if(UsePWHL && pwl>0 && !pwlSwept && bar.l <= pwl) { pwlSwept=true; leveOut=pwl; return true; }
   if(UseEQL && haveEql && !eqlSwept && bar.l <= lastEql) { eqlSwept=true; leveOut=lastEql; return true; }
   return false;
  }

//======================================================================
// MAIN M1 BAR PROCESSOR — the whole state machine, one call per new
// CLOSED M1 candle, mirroring Pine's default (non-calc_on_every_tick)
// once-per-bar execution.
//======================================================================

void ProcessNewM1Bar(const M1Bar &bar)
  {
   // --- daily/session trade counters ---
   int today = DayOf(bar.t);
   if(today != lastDay) { lastDay = today; tradesToday = 0; }
   UpdateAtr(bar);

   bool inLondonNow = InLondon(bar.t);
   bool inNyNow     = InNy(bar.t);
   bool inAsiaNow   = InAsia(bar.t);
   if(inLondonNow && !prevInLondon) lonSessionTrades = 0;
   if(inNyNow && !prevInNy) nySessionTrades = 0;
   prevInLondon = inLondonNow;
   prevInNy = inNyNow;

   UpdatePdhPdl();
   UpdatePwhPwl();
   UpdateEqlOnNewRefBar();
   UpdateAttemptFromLastDeal();

   bool canTrade = (tradesToday < MaxTradesPerDay) && !HasOwnPosition();
   bool canTradeEntry = canTrade && ((inLondonNow && lonSessionTrades < MaxTradesPerSession) ||
                                      (inNyNow     && nySessionTrades < MaxTradesPerSession));

   // The whole cycle - sweep, CE wait, entry - must start and finish inside
   // the SAME session (Asia/London/NY). A sweep can only arm while some
   // session is actually open; carrying an armed cycle across a session
   // boundary (e.g. sweep in Asia, break/entry attempted once London opens)
   // breaks the statistical premise sessions are meant to provide.
   bool inAnySession = inAsiaNow || inLondonNow || inNyNow;

   // --- SWEEP: arm the state machine the instant a level is crossed ---
   double lvl;
   if(state == 0 && canTrade && inAnySession)
     {
      if(AnyHighSweep(bar, lvl))
        {
         state = 1;
         sweepBarTime = bar.t;
         cycSessAsia = inAsiaNow; cycSessLondon = inLondonNow; cycSessNy = inNyNow;
         sweepHi = bar.h;
         ceExtHi = bar.h; ceExtHiT = bar.t;
         double lv = 0; datetime lt = bar.t;
         mssRefBear = (CeRef(true, 1, lv, lt) >= 0) ? lv : bar.l;
         mssRefBarTime = lt;
         activeSweepPx = lvl;
        }
      else if(AnyLowSweep(bar, lvl))
        {
         state = 2;
         sweepBarTime = bar.t;
         cycSessAsia = inAsiaNow; cycSessLondon = inLondonNow; cycSessNy = inNyNow;
         sweepLo = bar.l;
         ceExtLo = bar.l; ceExtLoT = bar.t;
         double lv = 0; datetime lt = bar.t;
         mssRefBull = (CeRef(false, 1, lv, lt) >= 0) ? lv : bar.h;
         mssRefBarTime = lt;
         activeSweepPx = lvl;
        }
     }

   // --- whole-cycle deadline (covers both the sweep->break hunt and the
   //     pending-entry wait for a session, same as the Pine version) ---
   if(state != 0 && BarsBetween(sweepBarTime, bar.t) > MssMaxBars)
     {
      state = 0; activeSweepPx = 0;
      return;
     }

   // The session that armed this cycle just ended - abandon it instead of
   // carrying the wait into the next session. A break confirmed in Asia,
   // still waiting on canTradeEntry once London opens, is exactly the
   // cross-session carryover this prevents.
   if(state != 0 && !((cycSessAsia && inAsiaNow) || (cycSessLondon && inLondonNow) || (cycSessNy && inNyNow)))
     {
      state = 0; activeSweepPx = 0;
      return;
     }

   // --- CE relocation while waiting (states 1/2) ---
   bool bearMss = false, bullMss = false;
   // Break first, against the CE formed by the previous bars (a close, not
   // a wick); only if there is no break does this bar extend the move. The
   // CE moves only on a NEW extreme, and only to a MORE RECENT qualifying
   // leg start - same rule as Pine.
   if(state == 1)
     {
      if(bar.t > sweepBarTime && bar.c < mssRefBear) bearMss = true;
      if(!bearMss)
        {
         if(bar.h > sweepHi) sweepHi = bar.h;
         // CLOSE RULE: the extreme moves only when a candle CLOSES beyond it;
         // a wick beyond it that closes back inside is annulled.
         if(bar.c > ceExtHi)
           {
            ceExtHi = bar.h; ceExtHiT = bar.t;
            double lv = 0; datetime lt = 0;
            if(CeRef(true, 1, lv, lt) == 1 && lt > mssRefBarTime) { mssRefBear = lv; mssRefBarTime = lt; }
           }
         else if(bar.h > ceExtHi && !SwingSig(true, ceExtHi, ceExtHiT))
           { ceExtHi = bar.h; ceExtHiT = bar.t; }   // wick in a swing still forming: the level is the deepest wick
        }
     }
   else if(state == 2)
     {
      if(bar.t > sweepBarTime && bar.c > mssRefBull) bullMss = true;
      if(!bullMss)
        {
         if(bar.l < sweepLo) sweepLo = bar.l;
         if(bar.c < ceExtLo)
           {
            ceExtLo = bar.l; ceExtLoT = bar.t;
            double lv = 0; datetime lt = 0;
            if(CeRef(false, 1, lv, lt) == 1 && lt > mssRefBarTime) { mssRefBull = lv; mssRefBarTime = lt; }
           }
         else if(bar.l < ceExtLo && !SwingSig(false, ceExtLo, ceExtLoT))
           { ceExtLo = bar.l; ceExtLoT = bar.t; }
        }
     }

   if(bearMss) { state = 3; mssBarTime = bar.t; }
   if(bullMss) { state = 4; mssBarTime = bar.t; }

   // --- PENDING ENTRY: fires the moment London/NY is open, sl/tp already
   //     anchored to the frozen reaction extreme ---
   if(state == 3 || state == 4)
     {
      if(canTradeEntry)
        {
         bool isShort = (state == 3);
         double slStruct = isShort ? (sweepHi + SweepBuffer) : (sweepLo - SweepBuffer);
         double slPrice  = isShort
                            ? (CapSLToMax ? MathMin(slStruct, bar.c + MaxSL) : slStruct)
                            : (CapSLToMax ? MathMax(slStruct, bar.c - MaxSL) : slStruct);
         double slDist   = isShort ? (slPrice - bar.c) : (bar.c - slPrice);
         double tpPrice  = isShort ? (bar.c - slDist*RRRatio) : (bar.c + slDist*RRRatio);
         double lots     = CalcLots(slDist);

         bool valid = (slDist >= MinSL) && (slDist <= MaxSL) && (lots > 0);
         if(valid)
           {
            bool ok;
            if(isShort) ok = trade.Sell(lots, _Symbol, 0, slPrice, tpPrice, "LiqShort");
            else        ok = trade.Buy(lots, _Symbol, 0, slPrice, tpPrice, "LiqLong");
            if(ok)
              {
               tradesToday++;
               if(inLondonNow) lonSessionTrades++;
               if(inNyNow)     nySessionTrades++;
              }
            state = 0; activeSweepPx = 0;
           }
        }
      // Not yet in London/NY: stays parked in state 3/4 only until the
      // ARMING session itself ends (checked above) or the MssMaxBars
      // deadline hits - never carries into a later session.
     }
  }

//======================================================================
// Helpers used above
//======================================================================

bool HasOwnPosition()
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
         return true;
     }
   return false;
  }

int BarsBetween(datetime a, datetime b)
  {
   if(a == 0) return 0;
   return (int)((b - a) / 60); // M1 bars = whole minutes apart
  }

//======================================================================
// EA LIFECYCLE
//======================================================================

int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   ArrayResize(swhHist, 0);
   ArrayResize(swlHist, 0);
   lastSeenFormingBar = 0;
   lastProcessedM1Bar = 0;
   // Seed the Wilder ATR from the last 14 closed M1 bars so the CE's ATR
   // floor matches Pine's ta.atr from the first processed bar.
   for(int i = 15; i >= 1; i--)
     {
      M1Bar b;
      if(GetM1(i, b)) UpdateAtr(b);
     }
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) {}

void OnTick()
  {
   // Detect a new M1 bar by watching the still-FORMING bar's own open time
   // (shift 0) change — that only happens once a new minute has actually
   // started, meaning the PREVIOUS bar (now at shift 1) just closed. This is
   // what makes the EA evaluate once per closed M1 bar regardless of tick
   // volume, mirroring Pine's default (non-calc_on_every_tick) execution.
   datetime formingBar = iTime(_Symbol, PERIOD_M1, 0);
   if(formingBar == 0 || formingBar == lastSeenFormingBar) return;
   lastSeenFormingBar = formingBar;

   M1Bar bar;
   if(!GetM1(1, bar)) return;      // the bar that just closed
   if(bar.t == lastProcessedM1Bar) return;
   lastProcessedM1Bar = bar.t;

   ProcessNewM1Bar(bar);
  }
//+------------------------------------------------------------------+
