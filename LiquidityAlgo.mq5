//+------------------------------------------------------------------+
//|                                              LiquidityAlgo.mq5   |
//|  MQL5 port of the "Liquidity Algo" Pine Script v6 strategy       |
//|  (eurusd_smc_v2.pine, the version tested on TradingView).        |
//|                                                                  |
//|  Only the TRADING DECISIONS are ported (no drawings, tables or   |
//|  alerts). Every rule below follows the Pine code in the same     |
//|  order, bar by bar, on CLOSED M1 bars:                           |
//|                                                                  |
//|   1. Zones: PDH/PDL, PWH/PWL, EQH/EQL and the 1H/4H/D/W/MN       |
//|      imbalances. Each list is built in its own timeframe (like   |
//|      Pine's request.security contexts) and imported once the     |
//|      completing candle has closed; the M1 bar then consumes      |
//|      every zone price traded BEYOND (LiqPenTicks).               |
//|   2. A zone consumed while a session is open arms the setup      |
//|      (state 1 = bearish, 2 = bullish); an imbalance touch can    |
//|      override a live cycle of the opposite side.                 |
//|   3. CE = the swing that started the final leg into the          |
//|      liquidity (CeRef); it moves only when a candle CLOSES       |
//|      beyond the extreme. A close through it = structure break.   |
//|   4. Default mode (Pine use_fvg_entry = false): the break is the |
//|      entry, fired while London/NY is open. The imbalance-retest  |
//|      mode of Pine is NOT ported.                                 |
//|   5. Second chance, tiered risk ladder, per-session/day caps,    |
//|      SL at the reaction extreme, TP = SL x RR.                   |
//|                                                                  |
//|  Not compiled or run by the author: see the validation protocol  |
//|  (LogParity events) to compare against the TradingView run.      |
//+------------------------------------------------------------------+
#property copyright "Liquidity Algo"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//======================================================================
// ENUMS
//======================================================================
enum ENUM_SRV_CLOCK
  {
   SRV_NYCLOSE_USDST = 0,   // server = New York + 7h (GMT+2 winter / GMT+3 summer, US DST)
   SRV_EU_DST        = 1,   // GMT+2 winter / GMT+3 summer, EU DST
   SRV_FIXED         = 2    // fixed offset (ServerFixedUtcOffsetH)
  };

enum ENUM_DAY_TZ
  {
   DAYTZ_NEW_YORK   = 0,    // exchange day of the TradingView symbol (assumed New York)
   DAYTZ_UTC        = 1,
   DAYTZ_UTC_PLUS_2 = 2,
   DAYTZ_SERVER     = 3
  };

enum ENUM_LOT_ROUND
  {
   LOT_NEAREST = 0,         // risk stays equal on average (closest to Pine's continuous qty)
   LOT_FLOOR   = 1          // never risk more than the ladder
  };

//======================================================================
// INPUTS (names / defaults mirror the Pine inputs)
//======================================================================
input group "=== Server clock ==="
input ENUM_SRV_CLOCK ServerClockMode = SRV_NYCLOSE_USDST;
input int            ServerFixedUtcOffsetH = 2;           // only for SRV_FIXED
input ENUM_DAY_TZ    PineDayTz = DAYTZ_NEW_YORK;          // day used by "max trades per day"

input group "=== Market Sessions (Pine clock = fixed UTC+2) ==="
input int    AsiaOpenHour     = 0;
input int    AsiaCloseHour    = 8;
input int    LondonOpenHour   = 9;
input int    LondonCloseHour  = 11;
input int    NYOpenHour       = 14;
input int    NYCloseHour      = 16;
input int    NYCloseMinute    = 30;

input group "=== Liquidity Levels ==="
input bool   UsePDHL       = true;
input bool   UsePWHL       = true;
input bool   UseEQL        = true;
input int    LiqPenTicks   = 1;        // ticks beyond a level to count as swept (0 = a touch counts)
input double SweepBuffer   = 0.0;      // SL padding beyond the reaction extreme
input bool   ScaleThr      = false;    // scale price thresholds by tick/0.00001 (non-FX symbols)

input group "=== Equal Highs / Lows ==="
input double EqlTolerance      = 0.0005;
input int    EqlPivotStrength  = 10;               // reference-TF candles each side
input int    EqlLookbackPivots = 5;
input ENUM_TIMEFRAMES EqlRefTF = PERIOD_H1;        // H1, H4, D1, W1 or MN1
input int    EqAgeDays         = 14;               // EQH/EQL older than this are dropped (0 = never)
input int    EqReplayBars      = 6000;             // reference-TF bars replayed at start

input group "=== HTF Imbalances ==="
input bool   UseHtf1H      = true;
input bool   UseHtf4H      = true;
input bool   UseHtfD       = true;
input bool   UseHtfW       = true;
input bool   UseHtfM       = false;
input double HtfFvgMin     = 0.0003;   // min gap size
input bool   UseHtfImbEntry = true;    // an imbalance touch arms the cycle
input bool   UseHtfFilter  = false;    // require an active HTF imbalance on the trade side
input double MergeTol      = 0.0005;   // stack link tolerance (outermost-gap logic)
input int    Age1HDays     = 14;
input int    Age4HDays     = 45;

input group "=== Structure (CE) ==="
input double CeLegPct      = 25.0;
input double CeDispAtr     = 0.75;
input int    CeContBars    = 8;
input double CeContAtr     = 2.0;
input double CeLegCapAtr   = 1.25;
input int    CePivBars     = 5;
input int    CeRunBars     = 3;
input double CeMinAtr      = 1.0;
input int    CeScanBars    = 60;
input int    MssMaxBars    = 150;      // whole-cycle deadline after the sweep, in M1 bars

input group "=== Risk Management ==="
input double RRRatio        = 2.0;
input double MaxSL          = 0.0050;
input double MinSL          = 0.0003;
input bool   CapSLToMax     = true;
input bool   SecondChance   = true;
input int    MaxTradesPerDay     = 4;
input int    MaxTradesPerSession = 2;   // London and NY each, independently
input double FixedCapital   = 100000;   // non-compounded risk base
input ENUM_LOT_ROUND LotRounding = LOT_NEAREST;

input group "=== Tiered Risk (% of FixedCapital, one step per loss) ==="
input double Risk1 = 1.00;
input double Risk2 = 1.11;
input double Risk3 = 1.22;
input double Risk4 = 1.33;
input double Risk5 = 1.44;
input double Risk6 = 1.55;

input group "=== Chart drawing (visual tester / live chart) ==="
input bool   ShowZones     = true;     // white lines for the live zones (levels, equal highs/lows, imbalances)
input int    ZonesPerSide  = 3;        // nearest zones drawn above / below price (0 = all)
input bool   ShowSwept     = true;     // zones taken in the last 24h as grey dotted segments

input group "=== Misc ==="
input ulong  MagicNumber = 20260902;
input bool   LogParity   = false;       // print EVT| lines to diff against TradingView

//======================================================================
// SMALL TYPES
//======================================================================
struct M1Bar { double o,h,l,c; datetime t; };

// One side (bear or bull) of an imbalance list: near edge, far edge, origin
// (open of the middle candle), creation (close of the 3rd candle).
struct GapSide
  {
   double   nr[];
   double   fr[];
   datetime org[];
   datetime cre[];
  };

// Equal-high / equal-low list: price, pivot candle open, creation.
struct LvList
  {
   double   px[];
   datetime org[];
   datetime cre[];
  };

struct HtfTf
  {
   ENUM_TIMEFRAMES tf;
   bool     use;
   int      cap;
   int      ageDays;
   long     legSec;
   GapSide  cB;      // context (higher-timeframe) lists
   GapSide  cU;
   GapSide  B;       // chart lists (consumed at M1 resolution)
   GapSide  U;
   datetime up;      // import watermark (creation time of the newest imported zone)
   datetime fedOpen; // open of the last HTF bar fed to the context
   MqlRates m1;      // the candle before the one being fed  (Pine [1])
   MqlRates m2;      // two candles before                    (Pine [2])
   int      nFed;
   bool     tB;      // a bearish (supply) imbalance was liquidated this bar
   bool     tU;
  };

//======================================================================
// STATE (persists across bars, mirrors Pine's `var`)
//======================================================================
// 0 = IDLE | 1 = BEAR_SWEPT (hunting bearish CE) | 2 = BULL_SWEPT
// 3 = PENDING SHORT (CE broken) | 4 = PENDING LONG
int      state          = 0;
long     g_barIdx       = 0;      // Pine bar_index (counts processed M1 bars)
long     sweepBarIdx    = 0;
bool     cycSessAsia = false, cycSessLondon = false, cycSessNy = false;

double   sweepHi = 0, sweepLo = 0;           // reaction extreme (stop anchor)
double   mssRefBear = 0, mssRefBull = 0;     // the CE level
datetime mssRefBarTime = 0;                  // M1 bar the CE level sits on
double   ceExtHi = 0, ceExtLo = 0;           // extreme the CE is measured from
datetime ceExtHiT = 0, ceExtLoT = 0;
bool     chanceUsed    = true;
bool     slJustHit     = false;              // a trade closed at a loss on this bar
bool     slWasShort    = false;
datetime lastClosedEntryTime = 0;            // entry time of that trade

double   atrM1 = 0;       // Wilder ATR(14) of M1
int      atrCount = 0;
double   trSum = 0;
double   g_prevClose = 0;
bool     g_havePrevClose = false;

int      attempt = 1;
int      tradesToday = 0;
long     lastDayKey = -1;
int      lonSessionTrades = 0;
int      nySessionTrades = 0;
bool     prevInLondon = false;
bool     prevInNy = false;

// derived constants
double   g_tick = 0.00001;
double   g_pen = 0;
double   g_thr = 1.0;
double   g_sweepBuf = 0, g_maxSL = 0, g_minSL = 0, g_eqlTol = 0, g_htfFvgMin = 0, g_mergeTol = 0;

// levels
double   pdh = 0, pdl = 0, pwh = 0, pwl = 0;
bool     havePd = false, havePw = false;
datetime g_pdOpen = 0, g_pwOpen = 0;
datetime pdSince = 0, pwSince = 0;
bool     pdhSwept = false, pdlSwept = false, pwhSwept = false, pwlSwept = false;

// HTF imbalances
HtfTf    g_h[5];

// EQH / EQL
ENUM_TIMEFRAMES g_eqTf = PERIOD_H1;
LvList   g_cxH, g_cxL;       // context lists
LvList   g_chH, g_chL;       // chart lists
double   g_swH[];             // last confirmed pivot highs
double   g_swL[];             // last confirmed pivot lows
MqlRates g_ring[];           // last 2*sw+1 reference candles (chronological)
datetime g_eqFedOpen = 0;
datetime g_upEQ = 0;

// trades bookkeeping
bool     g_prevHasPos = false;
bool     g_needPoll   = false;
int      g_expectClose = 0;   // orders sent whose closing deal has not been seen yet
int      g_dealScan   = 0;

// drawing
bool     g_draw = false;
datetime g_pdhT = 0, g_pdlT = 0, g_pwhT = 0, g_pwlT = 0;   // where each level was printed
double   g_swPx[];            // zones consumed recently: price, start, end
datetime g_swT1[];
datetime g_swT2[];
string   g_zoneSig = "";
string   g_liqNote = "";

bool     g_inited = false;
datetime lastSeenFormingBar = 0;
datetime lastProcessedM1Bar = 0;

//======================================================================
// LOG
//======================================================================
void Ev(const string s)
  {
   if(LogParity) Print("EVT|", s);
  }

//======================================================================
// CALENDAR / TIME MODEL
//======================================================================
datetime MkDate(const int y, const int m, const int d, const int hh, const int mm)
  {
   MqlDateTime s;
   s.year = y; s.mon = m; s.day = d; s.hour = hh; s.min = mm; s.sec = 0;
   s.day_of_week = 0; s.day_of_year = 0;
   return StructToTime(s);
  }

// day-of-month of the n-th Sunday of a month
int NthSundayDay(const int y, const int m, const int n)
  {
   MqlDateTime s;
   TimeToStruct(MkDate(y, m, 1, 0, 0), s);
   int first = 1 + ((7 - s.day_of_week) % 7);
   return first + 7 * (n - 1);
  }

int LastSundayDay(const int y, const int m)
  {
   int ny = y, nm = m + 1;
   if(nm > 12) { nm = 1; ny++; }
   datetime last = MkDate(ny, nm, 1, 0, 0) - 86400;
   MqlDateTime s;
   TimeToStruct(last, s);
   return s.day - s.day_of_week;
  }

// New York local clock -> are we in US daylight time?
bool UsDstLocal(const datetime nyLocal)
  {
   MqlDateTime s;
   TimeToStruct(nyLocal, s);
   datetime st = MkDate(s.year, 3, NthSundayDay(s.year, 3, 2), 3, 0);
   datetime en = MkDate(s.year, 11, NthSundayDay(s.year, 11, 1), 2, 0);
   return (nyLocal >= st && nyLocal < en);
  }

datetime ServerToUtc(const datetime ts)
  {
   if(ServerClockMode == SRV_FIXED)
      return ts - ServerFixedUtcOffsetH * 3600;
   if(ServerClockMode == SRV_NYCLOSE_USDST)
     {
      datetime ny = ts - 7 * 3600;
      return ny + (UsDstLocal(ny) ? 4 : 5) * 3600;
     }
   MqlDateTime s;
   TimeToStruct(ts, s);
   datetime st = MkDate(s.year, 3, LastSundayDay(s.year, 3), 3, 0);
   datetime en = MkDate(s.year, 10, LastSundayDay(s.year, 10), 4, 0);
   bool dst = (ts >= st && ts < en);
   return ts - (dst ? 3 : 2) * 3600;
  }

// The clock Pine's session logic uses: UTC+2, fixed all year.
datetime PineT(const datetime ts)
  {
   return ServerToUtc(ts) + 2 * 3600;
  }

// New York local time from UTC (exact US DST instants)
datetime UtcToNy(const datetime utc)
  {
   MqlDateTime s;
   TimeToStruct(utc, s);
   datetime st = MkDate(s.year, 3, NthSundayDay(s.year, 3, 2), 7, 0);   // 02:00 EST = 07:00 UTC
   datetime en = MkDate(s.year, 11, NthSundayDay(s.year, 11, 1), 6, 0); // 02:00 EDT = 06:00 UTC
   bool dst = (utc >= st && utc < en);
   return utc - (dst ? 4 : 5) * 3600;
  }

long DateKey(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return (long)s.year * 10000 + s.mon * 100 + s.day;
  }

long DayKeyOf(const datetime ts)
  {
   if(PineDayTz == DAYTZ_SERVER)     return DateKey(ts);
   datetime utc = ServerToUtc(ts);
   if(PineDayTz == DAYTZ_UTC)        return DateKey(utc);
   if(PineDayTz == DAYTZ_UTC_PLUS_2) return DateKey(utc + 2 * 3600);
   return DateKey(UtcToNy(utc));
  }

bool InLondonP(const int hh)
  {
   return hh >= LondonOpenHour && hh < LondonCloseHour;
  }

bool InNyP(const int hh, const int mm)
  {
   bool closed = (hh > NYCloseHour) || (hh == NYCloseHour && mm >= NYCloseMinute);
   return hh >= NYOpenHour && !closed;
  }

bool InAsiaP(const int hh)
  {
   if(AsiaOpenHour <= AsiaCloseHour) return hh >= AsiaOpenHour && hh < AsiaCloseHour;
   return hh >= AsiaOpenHour || hh < AsiaCloseHour;
  }

// Port of Pine f_sess_key: FX-day stamp * 10 + bucket (1 Asia, 3 London, 5 NY);
// the time between sessions belongs to the NEXT session.
long SessKey(const datetime ts)
  {
   datetime p = PineT(ts);
   MqlDateTime s;
   TimeToStruct(p, s);
   int hh = s.hour;
   int mins = hh * 60 + s.min;
   long d = (long)s.year * 10000 + s.mon * 100 + s.day;
   int b;
   if(InAsiaP(hh))                                     b = 1;
   else if(mins < LondonCloseHour * 60)                b = 3;
   else if(mins < NYCloseHour * 60 + NYCloseMinute)    b = 5;
   else                                                b = 6;
   if(b == 6)
     {
      MqlDateTime s2;
      TimeToStruct(p + 86400, s2);
      d = (long)s2.year * 10000 + s2.mon * 100 + s2.day;
      b = 1;
     }
   return d * 10 + b;
  }

//======================================================================
// M1 ACCESS + ATR
//======================================================================
bool GetM1(const int shift, M1Bar &out)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, shift, 1, r) != 1) return false;
   out.o = r[0].open; out.h = r[0].high; out.l = r[0].low; out.c = r[0].close; out.t = r[0].time;
   return true;
  }

// Wilder ATR(14), exactly Pine ta.atr: first TR = high-low, SMA seed over the
// first 14 TRs, then RMA.
void AtrStep(const double h, const double l, const double c)
  {
   double tr = h - l;
   if(g_havePrevClose)
      tr = MathMax(tr, MathMax(MathAbs(h - g_prevClose), MathAbs(l - g_prevClose)));
   if(atrCount < 14) { trSum += tr; atrCount++; atrM1 = trSum / atrCount; }
   else atrM1 = (atrM1 * 13.0 + tr) / 14.0;
   g_prevClose = c;
   g_havePrevClose = true;
  }

//======================================================================
// LIST HELPERS
//======================================================================
int GsN(const GapSide &g) { return ArraySize(g.nr); }

void GsRemove(GapSide &g, const int idx)
  {
   int n = ArraySize(g.nr);
   if(idx < 0 || idx >= n) return;
   for(int i = idx; i < n - 1; i++)
     {
      g.nr[i] = g.nr[i + 1];
      g.fr[i] = g.fr[i + 1];
      g.org[i] = g.org[i + 1];
      g.cre[i] = g.cre[i + 1];
     }
   ArrayResize(g.nr, n - 1);
   ArrayResize(g.fr, n - 1);
   ArrayResize(g.org, n - 1);
   ArrayResize(g.cre, n - 1);
  }

void GsPush(GapSide &g, const double n_, const double f_, const datetime o_, const datetime c_, const int cap)
  {
   int k = ArraySize(g.nr);
   ArrayResize(g.nr, k + 1);
   ArrayResize(g.fr, k + 1);
   ArrayResize(g.org, k + 1);
   ArrayResize(g.cre, k + 1);
   g.nr[k] = n_; g.fr[k] = f_; g.org[k] = o_; g.cre[k] = c_;
   if(k + 1 > cap) GsRemove(g, 0);
  }

void GsClear(GapSide &g)
  {
   ArrayResize(g.nr, 0);
   ArrayResize(g.fr, 0);
   ArrayResize(g.org, 0);
   ArrayResize(g.cre, 0);
  }

void SwpPush(const double px, const datetime t1, const datetime t2)
  {
   if(!g_draw || !ShowSwept) return;
   int k = ArraySize(g_swPx);
   ArrayResize(g_swPx, k + 1);
   ArrayResize(g_swT1, k + 1);
   ArrayResize(g_swT2, k + 1);
   g_swPx[k] = px; g_swT1[k] = t1; g_swT2[k] = t2;
  }

void SwpPrune(const datetime nowT)
  {
   int n = ArraySize(g_swPx);
   int w = 0;
   for(int i = 0; i < n; i++)
     {
      if(g_swT2[i] < nowT - 86400) continue;
      g_swPx[w] = g_swPx[i]; g_swT1[w] = g_swT1[i]; g_swT2[w] = g_swT2[i];
      w++;
     }
   if(w != n)
     {
      ArrayResize(g_swPx, w);
      ArrayResize(g_swT1, w);
      ArrayResize(g_swT2, w);
     }
  }

int LlN(const LvList &l) { return ArraySize(l.px); }

void LlRemove(LvList &l, const int idx)
  {
   int n = ArraySize(l.px);
   if(idx < 0 || idx >= n) return;
   for(int i = idx; i < n - 1; i++)
     {
      l.px[i] = l.px[i + 1];
      l.org[i] = l.org[i + 1];
      l.cre[i] = l.cre[i + 1];
     }
   ArrayResize(l.px, n - 1);
   ArrayResize(l.org, n - 1);
   ArrayResize(l.cre, n - 1);
  }

void LlPush(LvList &l, const double p_, const datetime o_, const datetime c_, const int cap)
  {
   int k = ArraySize(l.px);
   ArrayResize(l.px, k + 1);
   ArrayResize(l.org, k + 1);
   ArrayResize(l.cre, k + 1);
   l.px[k] = p_; l.org[k] = o_; l.cre[k] = c_;
   if(k + 1 > cap) LlRemove(l, 0);
  }

void LlClear(LvList &l)
  {
   ArrayResize(l.px, 0);
   ArrayResize(l.org, 0);
   ArrayResize(l.cre, 0);
  }

// Nominal close of a higher-timeframe candle opened at `open`.
datetime HtfClose(const ENUM_TIMEFRAMES tf, const datetime open)
  {
   if(tf == PERIOD_MN1)
     {
      MqlDateTime s;
      TimeToStruct(open, s);
      int y = s.year, m = s.mon + 1;
      if(m > 12) { m = 1; y++; }
      return MkDate(y, m, 1, 0, 0);
     }
   if(tf == PERIOD_W1) return open + 7 * 86400;
   return open + PeriodSeconds(tf);
  }

// Pine f_age_ok: a zone older than `days` is gone (0 = never).
bool AgeOk(const datetime org, const int days, const datetime nowT)
  {
   if(days <= 0 || org == 0) return true;
   return (nowT - org) <= (long)days * 86400;
  }

//======================================================================
// HTF IMBALANCES  (Pine f_ctx_gaps / f_ctx_import / f_expire / f_gap_cross)
//======================================================================
// Feed ONE closed higher-timeframe candle into the context lists.
void HtfCtxFeedBar(HtfTf &h, const MqlRates &c3)
  {
   datetime c3Close = HtfClose(h.tf, c3.time);
   // gaps touched by this candle (that existed before it) are gone
   for(int i = GsN(h.cB) - 1; i >= 0; i--)
      if(c3.time >= h.cB.cre[i] && c3.high >= h.cB.nr[i] + g_pen) GsRemove(h.cB, i);
   for(int i = GsN(h.cU) - 1; i >= 0; i--)
      if(c3.time >= h.cU.cre[i] && c3.low <= h.cU.nr[i] - g_pen) GsRemove(h.cU, i);
   // 3-candle rule: candle 1 = m2, middle = m1, candle 3 = c3
   if(h.nFed >= 2)
     {
      if(h.m2.low > c3.high && (h.m2.low - c3.high) >= g_htfFvgMin)
         GsPush(h.cB, c3.high, h.m2.low, h.m1.time, c3Close, h.cap);
      if(h.m2.high < c3.low && (c3.low - h.m2.high) >= g_htfFvgMin)
         GsPush(h.cU, c3.low, h.m2.high, h.m1.time, c3Close, h.cap);
     }
   h.m2 = h.m1;
   h.m1 = c3;
   h.nFed++;
  }

// Deliver every candle of tf whose close is <= the end of the processed
// minute (Pine imports a zone when cre <= time_close of the chart bar), in
// chronological order. A candle closed over a weekend is delivered on the
// first bar that can see it.
void HtfDeliver(HtfTf &h, const datetime tB)
  {
   datetime ot1 = iTime(_Symbol, h.tf, 1);          // newest COMPLETED candle (0 = forming)
   if(ot1 == 0 || ot1 <= h.fedOpen) return;
   datetime lim = tB + 60;
   int first = 1;
   while(first < 400)
     {
      datetime o = iTime(_Symbol, h.tf, first);
      if(o == 0 || o <= h.fedOpen) return;
      if(HtfClose(h.tf, o) <= lim) break;
      first++;
     }
   int newN = 0;
   while(newN < 400)
     {
      datetime o = iTime(_Symbol, h.tf, first + newN);
      if(o == 0 || o <= h.fedOpen) break;
      newN++;
     }
   if(newN == 0) return;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   if(CopyRates(_Symbol, h.tf, first, newN, r) != newN) return;
   bool asc = (r[0].time <= r[newN - 1].time);
   for(int k = 0; k < newN; k++)
     {
      int idx = asc ? k : (newN - 1 - k);
      if(r[idx].time <= h.fedOpen) continue;
      HtfCtxFeedBar(h, r[idx]);
      h.fedOpen = r[idx].time;
     }
  }

// Import zones that came into existence after `up` (their 3rd candle closed).
void HtfImport(HtfTf &h, const datetime tB)
  {
   datetime lim = tB + 60;
   datetime mxB = h.up, mxU = h.up;
   for(int i = 0; i < GsN(h.cB); i++)
     {
      datetime c = h.cB.cre[i];
      if(c > h.up && c <= lim)
        {
         GsPush(h.B, h.cB.nr[i], h.cB.fr[i], h.cB.org[i], c, h.cap);
         if(c > mxB) mxB = c;
        }
     }
   for(int i = 0; i < GsN(h.cU); i++)
     {
      datetime c = h.cU.cre[i];
      if(c > h.up && c <= lim)
        {
         GsPush(h.U, h.cU.nr[i], h.cU.fr[i], h.cU.org[i], c, h.cap);
         if(c > mxU) mxU = c;
        }
     }
   h.up = (mxB > mxU) ? mxB : mxU;
  }

// Oldest zones past their age limit are removed (org ascends with creation).
void GsExpire(GapSide &g, const int days, const datetime nowT)
  {
   if(days <= 0) return;
   while(GsN(g) > 0 && !AgeOk(g.org[0], days, nowT))
      GsRemove(g, 0);
  }

// Pine f_recompute_outer: a gap is "outer" when it is not linked to the gap
// before it in the farthest-from-price-first order.
void RecomputeOuter(const GapSide &g, const bool isSupply, const long legSec, bool &outer[])
  {
   int n = GsN(g);
   ArrayResize(outer, n);
   if(n == 0) return;
   int idx[];
   ArrayResize(idx, n);
   for(int i = 0; i < n; i++) idx[i] = i;
   // stable insertion sort by near edge: supply descending, demand ascending
   for(int a = 1; a < n; a++)
     {
      int key = idx[a];
      double kv = g.nr[key];
      int b = a - 1;
      while(b >= 0 && (isSupply ? (g.nr[idx[b]] < kv) : (g.nr[idx[b]] > kv)))
        {
         idx[b + 1] = idx[b];
         b--;
        }
      idx[b + 1] = key;
     }
   double   curNear = 0;
   datetime curOrg = 0;
   bool     have = false;
   for(int k = 0; k < n; k++)
     {
      int i = idx[k];
      double e = g.nr[i];
      double f = g.fr[i];
      datetime o = g.org[i];
      bool out = true;
      if(have)
        {
         bool linked = (isSupply ? (curNear <= f + g_mergeTol) : (curNear >= f - g_mergeTol))
                       || (MathAbs((double)(curOrg - o)) <= (double)legSec);
         out = !linked;
        }
      outer[i] = out;
      curNear = e;
      curOrg = o;
      have = true;
     }
  }

// Pine f_gap_cross: every gap price traded beyond (after it existed) is
// removed; only a hit on an OUTER gap counts as a liquidation.
bool HtfCross(GapSide &g, const bool isSupply, const long legSec, const datetime bt, const double H, const double L)
  {
   int n = GsN(g);
   if(n == 0) return false;
   bool hit[];
   ArrayResize(hit, n);
   bool any = false;
   for(int i = 0; i < n; i++)
     {
      hit[i] = (bt >= g.cre[i]) && (isSupply ? (H >= g.nr[i] + g_pen) : (L <= g.nr[i] - g_pen));
      if(hit[i]) any = true;
     }
   if(!any) return false;
   bool outer[];
   RecomputeOuter(g, isSupply, legSec, outer);
   bool touch = false;
   for(int i = 0; i < n; i++)
      if(hit[i] && outer[i]) { touch = true; SwpPush(g.nr[i], g.cre[i], bt); }
   for(int i = n - 1; i >= 0; i--)
      if(hit[i]) GsRemove(g, i);
   return touch;
  }

void HtfStep(HtfTf &h, const datetime tB, const double H, const double L)
  {
   h.tB = false;
   h.tU = false;
   if(!h.use) return;
   HtfDeliver(h, tB);
   HtfImport(h, tB);
   datetime nowT = tB + 60;
   GsExpire(h.B, h.ageDays, nowT);
   GsExpire(h.U, h.ageDays, nowT);
   h.tB = HtfCross(h.B, true,  h.legSec, tB, H, L);
   h.tU = HtfCross(h.U, false, h.legSec, tB, H, L);
  }

// Rebuild the context from history before the first processed bar.
void HtfReplay(HtfTf &h, const datetime tB)
  {
   if(!h.use) return;
   datetime lim = tB + 60;
   datetime from;
   if(h.tf == PERIOD_H1)       from = (datetime)(tB - (long)(Age1HDays + 30) * 86400);
   else if(h.tf == PERIOD_H4)  from = (datetime)(tB - (long)(Age4HDays + 60) * 86400);
   else if(h.tf == PERIOD_D1)  from = (datetime)(tB - (long)900 * 86400);
   else if(h.tf == PERIOD_W1)  from = (datetime)(tB - (long)300 * 7 * 86400);
   else                        from = (datetime)(tB - (long)120 * 31 * 86400);
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(_Symbol, h.tf, from, lim, r);
   if(got <= 0) return;
   bool asc = (r[0].time <= r[got - 1].time);
   for(int k = 0; k < got; k++)
     {
      int idx = asc ? k : (got - 1 - k);
      if(HtfClose(h.tf, r[idx].time) > lim) continue;
      HtfCtxFeedBar(h, r[idx]);
      h.fedOpen = r[idx].time;
     }
  }

//======================================================================
// EQH / EQL  (Pine f_ctx_eq / f_eq_import / f_eqh_cross)
//======================================================================
void SwPush(double &arr[], const double v)
  {
   int n = ArraySize(arr);
   if(n >= EqlLookbackPivots)
     {
      for(int i = 0; i < n - 1; i++) arr[i] = arr[i + 1];
      ArrayResize(arr, n - 1);
      n = n - 1;
     }
   ArrayResize(arr, n + 1);
   arr[n] = v;
  }

// A confirmed pivot of the reference timeframe: equal to a recent pivot
// within EqlTolerance -> it becomes a live equal level (deduplicated).
void EqPivot(LvList &ctx, double &sw[], const double v, const datetime org, const datetime cre)
  {
   int sz = ArraySize(sw);
   for(int j = 0; j < sz; j++)
     {
      if(MathAbs(v - sw[j]) <= g_eqlTol)
        {
         bool dup = false;
         for(int q = 0; q < LlN(ctx); q++)
            if(MathAbs(v - ctx.px[q]) <= g_eqlTol) dup = true;
         if(!dup) LlPush(ctx, v, org, cre, 100);
         break;
        }
     }
   SwPush(sw, v);
  }

void EqFeedBar(const MqlRates &c)
  {
   datetime cre = HtfClose(g_eqTf, c.time);
   // levels touched by this candle (that existed before it) are gone
   for(int i = LlN(g_cxH) - 1; i >= 0; i--)
      if(c.time >= g_cxH.cre[i] && c.high >= g_cxH.px[i] + g_pen) LlRemove(g_cxH, i);
   for(int i = LlN(g_cxL) - 1; i >= 0; i--)
      if(c.time >= g_cxL.cre[i] && c.low <= g_cxL.px[i] - g_pen) LlRemove(g_cxL, i);
   // ring of the last 2*sw+1 candles
   int need = 2 * EqlPivotStrength + 1;
   int n = ArraySize(g_ring);
   if(n >= need)
     {
      for(int i = 0; i < n - 1; i++) g_ring[i] = g_ring[i + 1];
      ArrayResize(g_ring, n - 1);
      n = n - 1;
     }
   ArrayResize(g_ring, n + 1);
   g_ring[n] = c;
   n = n + 1;
   if(n >= need)
     {
      int cIdx = n - 1 - EqlPivotStrength;
      double ch = g_ring[cIdx].high;
      double cl = g_ring[cIdx].low;
      bool okh = true, okl = true;
      for(int k = 1; k <= EqlPivotStrength; k++)
        {
         if(g_ring[cIdx + k].high >= ch || g_ring[cIdx - k].high >= ch) okh = false;
         if(g_ring[cIdx + k].low  <= cl || g_ring[cIdx - k].low  <= cl) okl = false;
        }
      if(okh) EqPivot(g_cxH, g_swH, ch, g_ring[cIdx].time, cre);
      if(okl) EqPivot(g_cxL, g_swL, cl, g_ring[cIdx].time, cre);
     }
  }

void EqDeliver(const datetime tB)
  {
   datetime ot1 = iTime(_Symbol, g_eqTf, 1);
   if(ot1 == 0 || ot1 <= g_eqFedOpen) return;
   datetime lim = tB + 60;
   int first = 1;
   while(first < 400)
     {
      datetime o = iTime(_Symbol, g_eqTf, first);
      if(o == 0 || o <= g_eqFedOpen) return;
      if(HtfClose(g_eqTf, o) <= lim) break;
      first++;
     }
   int newN = 0;
   while(newN < 400)
     {
      datetime o = iTime(_Symbol, g_eqTf, first + newN);
      if(o == 0 || o <= g_eqFedOpen) break;
      newN++;
     }
   if(newN == 0) return;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   if(CopyRates(_Symbol, g_eqTf, first, newN, r) != newN) return;
   bool asc = (r[0].time <= r[newN - 1].time);
   for(int k = 0; k < newN; k++)
     {
      int idx = asc ? k : (newN - 1 - k);
      if(r[idx].time <= g_eqFedOpen) continue;
      EqFeedBar(r[idx]);
      g_eqFedOpen = r[idx].time;
     }
  }

void EqReplay(const datetime tB)
  {
   datetime lim = tB + 60;
   datetime from = (datetime)(tB - (long)EqReplayBars * PeriodSeconds(g_eqTf));
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(_Symbol, g_eqTf, from, lim, r);
   if(got <= 0) return;
   bool asc = (r[0].time <= r[got - 1].time);
   for(int k = 0; k < got; k++)
     {
      int idx = asc ? k : (got - 1 - k);
      if(HtfClose(g_eqTf, r[idx].time) > lim) continue;
      EqFeedBar(r[idx]);
      g_eqFedOpen = r[idx].time;
     }
  }

void EqImport(const datetime tB)
  {
   datetime lim = tB + 60;
   datetime mxH = g_upEQ, mxL = g_upEQ;
   for(int i = 0; i < LlN(g_cxH); i++)
     {
      datetime c = g_cxH.cre[i];
      if(c > g_upEQ && c <= lim)
        {
         LlPush(g_chH, g_cxH.px[i], g_cxH.org[i], c, 100);
         if(c > mxH) mxH = c;
        }
     }
   for(int i = 0; i < LlN(g_cxL); i++)
     {
      datetime c = g_cxL.cre[i];
      if(c > g_upEQ && c <= lim)
        {
         LlPush(g_chL, g_cxL.px[i], g_cxL.org[i], c, 100);
         if(c > mxL) mxL = c;
        }
     }
   g_upEQ = (mxH > mxL) ? mxH : mxL;
  }

void LlExpire(LvList &l, const int days, const datetime nowT)
  {
   if(days <= 0) return;
   while(LlN(l) > 0 && !AgeOk(l.org[0], days, nowT))
      LlRemove(l, 0);
  }

// Every equal level price traded beyond (after it existed) is consumed.
bool EqCross(LvList &l, const bool isHigh, const datetime bt, const double H, const double L)
  {
   bool touched = false;
   for(int i = LlN(l) - 1; i >= 0; i--)
     {
      bool hit = (bt >= l.cre[i]) && (isHigh ? (H >= l.px[i] + g_pen) : (L <= l.px[i] - g_pen));
      if(hit)
        {
         touched = true;
         SwpPush(l.px[i], l.org[i], bt);
         LlRemove(l, i);
        }
     }
   return touched;
  }

//======================================================================
// PREVIOUS DAY / WEEK  (Pine PDH/PDL/PWH/PWL)
//======================================================================
// Time of the highest high / lowest low of tf inside [from, to): where a
// previous-day / week level was actually printed (line start). Falls back to
// `from` when the history is not available.
datetime ExtremeTime(const ENUM_TIMEFRAMES tf, const bool isHigh, const datetime from, const datetime to)
  {
   int sFrom = iBarShift(_Symbol, tf, from, false);
   int sTo   = iBarShift(_Symbol, tf, to - 1, false);
   if(sFrom < 0 || sTo < 0 || sFrom < sTo) return from;
   int cnt = sFrom - sTo + 1;
   int idx = isHigh ? iHighest(_Symbol, tf, MODE_HIGH, cnt, sTo) : iLowest(_Symbol, tf, MODE_LOW, cnt, sTo);
   if(idx < 0) return from;
   datetime t = iTime(_Symbol, tf, idx);
   return (t > 0) ? t : from;
  }

void LvPeriods(const datetime tB)
  {
   int kd = iBarShift(_Symbol, PERIOD_D1, tB, false);
   if(kd >= 0)
     {
      datetime po = iTime(_Symbol, PERIOD_D1, kd + 1);
      double   ph = iHigh(_Symbol, PERIOD_D1, kd + 1);
      double   pl = iLow(_Symbol, PERIOD_D1, kd + 1);
      if(po > 0 && ph > 0 && pl > 0 && po != g_pdOpen)
        {
         g_pdOpen = po;
         pdh = ph; pdl = pl;
         pdSince = po + 86400;
         g_pdhT = ExtremeTime(PERIOD_M1, true,  po, po + 86400);
         g_pdlT = ExtremeTime(PERIOD_M1, false, po, po + 86400);
         havePd = true;
         pdhSwept = false; pdlSwept = false;
         Ev(StringFormat("LVL|PD|%s|%.5f|%.5f", TimeToString(po), ph, pl));
        }
     }
   int kw = iBarShift(_Symbol, PERIOD_W1, tB, false);
   if(kw >= 0)
     {
      datetime po = iTime(_Symbol, PERIOD_W1, kw + 1);
      double   ph = iHigh(_Symbol, PERIOD_W1, kw + 1);
      double   pl = iLow(_Symbol, PERIOD_W1, kw + 1);
      if(po > 0 && ph > 0 && pl > 0 && po != g_pwOpen)
        {
         g_pwOpen = po;
         pwh = ph; pwl = pl;
         pwSince = po + 7 * 86400;
         g_pwhT = ExtremeTime(PERIOD_H1, true,  po, po + 7 * 86400);
         g_pwlT = ExtremeTime(PERIOD_H1, false, po, po + 7 * 86400);
         havePw = true;
         pwhSwept = false; pwlSwept = false;
         Ev(StringFormat("LVL|PW|%s|%.5f|%.5f", TimeToString(po), ph, pl));
        }
     }
  }

bool LvHit(const bool isHigh, const double lvl, const datetime since, const datetime bt, const double H, const double L)
  {
   return (bt >= since) && (isHigh ? (H >= lvl + g_pen) : (L <= lvl - g_pen));
  }

//======================================================================
// CE REFERENCE (Pine f_ce_ref / f_swing_sig)
//======================================================================
// Walking back from the extreme (shift eShift; 1 = the bar being processed).
// Returns 1 = found, 0 = no pullback qualified (level = deepest point of the
// window), -1 = no data.
int CeRef(const bool isBear, const int eShift, double &level, datetime &lvlTime)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(_Symbol, PERIOD_M1, 0, eShift + CeScanBars + 1, r);
   if(got <= eShift + 3) return -1;
   double ext = isBear ? r[eShift].high : r[eShift].low;
   bool own = (isBear ? r[eShift].close > r[eShift].open : r[eShift].close < r[eShift].open)
              && MathAbs(r[eShift].close - r[eShift].open) >= CeDispAtr * atrM1;
   if(own)
     {
      int pivEnd = MathMin(eShift + CePivBars, got - 2);
      for(int jx = eShift + 1; jx <= pivEnd; jx++)
        {
         bool piv = isBear ? (r[jx].low < r[jx + 1].low && r[jx].low < r[jx - 1].low)
                           : (r[jx].high > r[jx + 1].high && r[jx].high > r[jx - 1].high);
         if(piv)
           {
            level = isBear ? r[jx].low : r[jx].high;
            lvlTime = r[jx].time;
            return 1;
           }
        }
     }
   if(own)
     {
      int kx = eShift + 1;
      while(kx < got - 1 && (isBear ? r[kx].close > r[kx].open : r[kx].close < r[kx].open)) kx++;
      if(kx - eShift >= CeRunBars && kx < got - 1)
        {
         int kk = kx;
         if(isBear ? r[kx - 1].low < r[kx].low : r[kx - 1].high > r[kx].high) kk = kx - 1;
         level = isBear ? r[kk].low : r[kk].high;
         lvlTime = r[kk].time;
         return 1;
        }
     }
   int    mIdx = own ? eShift : eShift + 1;
   double m    = isBear ? r[mIdx].low : r[mIdx].high;
   datetime mt = r[mIdx].time;
   bool rev = own ? false : (isBear ? (r[mIdx].close < r[mIdx].open) : (r[mIdx].close > r[mIdx].open));
   int found = 0;
   for(int i = mIdx + 1; i < got; i++)
     {
      rev = rev || (isBear ? (r[i].close < r[i].open) : (r[i].close > r[i].open));
      double thr = MathMax(CeMinAtr * atrM1, MathMin(MathAbs(ext - m) * CeLegPct / 100.0, CeLegCapAtr * atrM1));
      double cm  = isBear ? r[i].high - m : m - r[i].low;
      if(cm > 0 && cm >= thr && rev)
        {
         found = 1;
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
// least CeContBars candles old and separated from the processed bar by a
// pullback of at least CeContAtr x ATR?  (Pine f_swing_sig)
bool SwingSig(const bool rising, const double level, const datetime levelT)
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

//======================================================================
// TRADES: ladder, closed-trade polling, sizing
//======================================================================
double RiskForAttempt(const int a)
  {
   switch(a)
     {
      case 1: return Risk1 / 100.0;
      case 2: return Risk2 / 100.0;
      case 3: return Risk3 / 100.0;
      case 4: return Risk4 / 100.0;
      case 5: return Risk5 / 100.0;
      default: return Risk6 / 100.0;
     }
  }

bool HasOwnPosition()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
         return true;
     }
   return false;
  }

// Pine: `strategy.closedtrades` grew on this bar -> roll the ladder (win ->
// back to 1, loss/zero -> one step up) and remember a stop-out for the second
// chance. Only deals that closed INSIDE the processed bar count.
void PollClosedTrades(const M1Bar &bar)
  {
   slJustHit = false;
   bool hasPos = HasOwnPosition();
   if(g_prevHasPos && !hasPos) g_needPoll = true;
   // a trade can open AND close inside one bar: never seen as a position
   if(g_expectClose > 0 && !hasPos) g_needPoll = true;
   g_prevHasPos = hasPos;
   if(!g_needPoll) return;
   if(!HistorySelect(0, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   bool beyond = false;
   for(int i = g_dealScan; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)MagicNumber || HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol)
        { g_dealScan = i + 1; continue; }
      long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
        {
         // an entry deal in the future of this bar must not be skipped over
         if((datetime)HistoryDealGetInteger(tk, DEAL_TIME) >= bar.t + 60) { beyond = true; break; }
         g_dealScan = i + 1;
         continue;
        }
      datetime dt = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      if(dt >= bar.t + 60) { beyond = true; break; }
      g_dealScan = i + 1;
      double profit = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
      long pid = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      datetime entryT = 0;
      for(int j = 0; j < i; j++)
        {
         ulong tj = HistoryDealGetTicket(j);
         if(tj == 0) continue;
         if(HistoryDealGetInteger(tj, DEAL_POSITION_ID) != pid) continue;
         if(HistoryDealGetInteger(tj, DEAL_ENTRY) == DEAL_ENTRY_IN)
           {
            profit += HistoryDealGetDouble(tj, DEAL_COMMISSION) + HistoryDealGetDouble(tj, DEAL_FEE);
            entryT = (datetime)HistoryDealGetInteger(tj, DEAL_TIME);
           }
        }
      if(g_expectClose > 0) g_expectClose--;
      attempt = (profit > 0) ? 1 : MathMin(attempt + 1, 6);
      slJustHit = (profit < 0);
      slWasShort = (HistoryDealGetInteger(tk, DEAL_TYPE) == DEAL_TYPE_BUY);   // a buy closes a short
      lastClosedEntryTime = entryT;
      Ev(StringFormat("EXIT|%s|profit=%.2f|attempt=%d", TimeToString(dt), profit, attempt));
     }
   if(!beyond) g_needPoll = false;
  }

double CalcLots(const double slDistancePrice)
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
   if(lotStep <= 0) lotStep = 0.01;
   if(LotRounding == LOT_NEAREST) lots = MathFloor(lots / lotStep + 0.5) * lotStep;
   else                           lots = MathFloor(lots / lotStep + 1e-9) * lotStep;
   if(lots < minLot) return 0;
   if(lots > maxLot) lots = maxLot;
   return lots;
  }

//======================================================================
// CYCLE ARMING (Pine arming blocks, second chance)
//======================================================================
void ArmBear(const M1Bar &bar, const bool inAsiaNow, const bool inLondonNow, const bool inNyNow)
  {
   state = 1;
   sweepBarIdx = g_barIdx;
   cycSessAsia = inAsiaNow; cycSessLondon = inLondonNow; cycSessNy = inNyNow;
   chanceUsed = false;
   sweepHi = bar.h;
   ceExtHi = bar.h; ceExtHiT = bar.t;
   double lv = 0; datetime lt = bar.t;
   if(CeRef(true, 1, lv, lt) >= 0) { mssRefBear = lv; mssRefBarTime = lt; }
   else                            { mssRefBear = bar.l; mssRefBarTime = bar.t; }
   Ev(StringFormat("ARM|BEAR|%s|hi=%.5f|ce=%.5f", TimeToString(bar.t), sweepHi, mssRefBear));
  }

void ArmBull(const M1Bar &bar, const bool inAsiaNow, const bool inLondonNow, const bool inNyNow)
  {
   state = 2;
   sweepBarIdx = g_barIdx;
   cycSessAsia = inAsiaNow; cycSessLondon = inLondonNow; cycSessNy = inNyNow;
   chanceUsed = false;
   sweepLo = bar.l;
   ceExtLo = bar.l; ceExtLoT = bar.t;
   double lv = 0; datetime lt = bar.t;
   if(CeRef(false, 1, lv, lt) >= 0) { mssRefBull = lv; mssRefBarTime = lt; }
   else                             { mssRefBull = bar.h; mssRefBarTime = bar.t; }
   Ev(StringFormat("ARM|BULL|%s|lo=%.5f|ce=%.5f", TimeToString(bar.t), sweepLo, mssRefBull));
  }

//======================================================================
// MAIN M1 BAR PROCESSOR - same order as the Pine script
//======================================================================
void InitStateOnFirstBar(const M1Bar &bar)
  {
   g_inited = true;
   for(int i = 0; i < 5; i++) HtfReplay(g_h[i], bar.t);
   if(UseEQL) EqReplay(bar.t);
  }

//======================================================================
// CHART DRAWING (visual tester / live chart only; never affects trading)
//======================================================================
void DrawLine(const string name, const datetime t1, const datetime t2, const double px, const color col,
              const ENUM_LINE_STYLE st, const bool ray)
  {
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, px, t2, px)) return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, st);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, ray);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
  }

void AddLive(double &px[], datetime &t1[], const double p, const datetime t)
  {
   int k = ArraySize(px);
   ArrayResize(px, k + 1);
   ArrayResize(t1, k + 1);
   px[k] = p;
   t1[k] = t;
  }

void AddGapLines(const HtfTf &h, double &px[], datetime &t1[])
  {
   if(!h.use) return;
   bool outerB[];
   bool outerU[];
   RecomputeOuter(h.B, true,  h.legSec, outerB);
   RecomputeOuter(h.U, false, h.legSec, outerU);
   for(int i = 0; i < GsN(h.B); i++) if(outerB[i]) AddLive(px, t1, h.B.nr[i], h.B.cre[i]);
   for(int i = 0; i < GsN(h.U); i++) if(outerU[i]) AddLive(px, t1, h.U.nr[i], h.U.cre[i]);
  }

// White ray for every live zone (nearest ZonesPerSide above and below price),
// grey dotted segment for zones consumed in the last 24h. The objects are
// rebuilt only when the selection changes.
void DrawZones(const M1Bar &bar)
  {
   SwpPrune(bar.t);
   double   px[];
   datetime t1[];
   if(UsePDHL && havePd)
     {
      if(!pdhSwept) AddLive(px, t1, pdh, g_pdhT);
      if(!pdlSwept) AddLive(px, t1, pdl, g_pdlT);
     }
   if(UsePWHL && havePw)
     {
      if(!pwhSwept) AddLive(px, t1, pwh, g_pwhT);
      if(!pwlSwept) AddLive(px, t1, pwl, g_pwlT);
     }
   if(UseEQL)
     {
      for(int i = 0; i < LlN(g_chH); i++) AddLive(px, t1, g_chH.px[i], g_chH.org[i]);
      for(int i = 0; i < LlN(g_chL); i++) AddLive(px, t1, g_chL.px[i], g_chL.org[i]);
     }
   for(int i = 0; i < 5; i++) AddGapLines(g_h[i], px, t1);

   // nearest ZonesPerSide on each side of price
   int n = ArraySize(px);
   int order[];
   ArrayResize(order, n);
   for(int i = 0; i < n; i++) order[i] = i;
   for(int a = 1; a < n; a++)
     {
      int key = order[a];
      double kd = MathAbs(px[key] - bar.c);
      int b = a - 1;
      while(b >= 0 && MathAbs(px[order[b]] - bar.c) > kd) { order[b + 1] = order[b]; b--; }
      order[b + 1] = key;
     }
   int nUp = 0, nDn = 0;
   bool pick[];
   ArrayResize(pick, n);
   for(int k = 0; k < n; k++)
     {
      int i = order[k];
      bool up = (px[i] >= bar.c);
      bool ok = true;
      if(ZonesPerSide > 0)
        {
         if(up) { nUp++; ok = (nUp <= ZonesPerSide); }
         else   { nDn++; ok = (nDn <= ZonesPerSide); }
        }
      pick[i] = ok;
     }

   string sig = "";
   for(int i = 0; i < n; i++)
      if(pick[i]) sig += DoubleToString(px[i], 5) + "@" + IntegerToString((long)t1[i]) + ";";
   if(ShowSwept)
      for(int i = 0; i < ArraySize(g_swPx); i++)
         sig += "s" + DoubleToString(g_swPx[i], 5) + "@" + IntegerToString((long)g_swT1[i]) + "-" + IntegerToString((long)g_swT2[i]) + ";";
   if(sig == g_zoneSig) return;
   g_zoneSig = sig;

   ObjectsDeleteAll(0, "LA_");
   int idx = 0;
   for(int i = 0; i < n; i++)
     {
      if(!pick[i]) continue;
      datetime a = (t1[i] > 0) ? t1[i] : bar.t;
      datetime b = (a < bar.t) ? bar.t : a + 60;
      DrawLine("LA_Z" + IntegerToString(idx), a, b, px[i], clrWhite, STYLE_SOLID, true);
      idx++;
     }
   if(ShowSwept)
      for(int i = 0; i < ArraySize(g_swPx); i++)
        {
         datetime a = (g_swT1[i] > 0) ? g_swT1[i] : g_swT2[i] - 60;
         datetime b = (g_swT2[i] > a) ? g_swT2[i] : a + 60;
         DrawLine("LA_S" + IntegerToString(i), a, b, g_swPx[i], clrDimGray, STYLE_DOT, false);
        }
  }

void ShowStatus(const M1Bar &bar)
  {
   string st = "IDLE";
   if(state == 1) st = "SWEPT UP - waiting for the bearish CE " + DoubleToString(mssRefBear, 5);
   if(state == 2) st = "SWEPT DOWN - waiting for the bullish CE " + DoubleToString(mssRefBull, 5);
   if(state == 3) st = "CE BROKEN - SHORT pending (needs London/NY)";
   if(state == 4) st = "CE BROKEN - LONG pending (needs London/NY)";
   Comment("LiquidityAlgo | ", st,
           "\nTrades today ", tradesToday, "/", MaxTradesPerDay, "  London ", lonSessionTrades, "/", MaxTradesPerSession,
           "  NY ", nySessionTrades, "/", MaxTradesPerSession, "  risk step ", attempt,
           "\nLast liquidity: ", g_liqNote);
  }

void ProcessNewM1Bar(const M1Bar &bar)
  {
   g_barIdx++;
   if(!g_inited) InitStateOnFirstBar(bar);
   AtrStep(bar.h, bar.l, bar.c);

   // ---- clock, day and session flags (Pine: hour(time,"UTC+2")) ----
   datetime pt = PineT(bar.t);
   MqlDateTime ps;
   TimeToStruct(pt, ps);
   bool inLondonNow = InLondonP(ps.hour);
   bool inNyNow     = InNyP(ps.hour, ps.min);
   bool inAsiaNow   = InAsiaP(ps.hour);
   bool inAnySession = inAsiaNow || inLondonNow || inNyNow;

   long dk = DayKeyOf(bar.t);
   if(dk != lastDayKey) { lastDayKey = dk; tradesToday = 0; }
   if(inLondonNow && !prevInLondon) lonSessionTrades = 0;
   if(inNyNow && !prevInNy) nySessionTrades = 0;
   prevInLondon = inLondonNow;
   prevInNy = inNyNow;

   PollClosedTrades(bar);

   bool canTrade = (tradesToday < MaxTradesPerDay) && !HasOwnPosition();
   bool canTradeEntry = canTrade && ((inLondonNow && lonSessionTrades < MaxTradesPerSession) ||
                                      (inNyNow     && nySessionTrades < MaxTradesPerSession));

   // ---- zones: HTF imbalances -> previous day/week -> equal levels ----
   for(int i = 0; i < 5; i++) HtfStep(g_h[i], bar.t, bar.h, bar.l);
   bool touchBearHtf = false, touchBullHtf = false, htfBear = false, htfBull = false;
   for(int i = 0; i < 5; i++)
     {
      if(!g_h[i].use) continue;
      if(g_h[i].tB) touchBearHtf = true;
      if(g_h[i].tU) touchBullHtf = true;
      if(GsN(g_h[i].B) > 0) htfBear = true;
      if(GsN(g_h[i].U) > 0) htfBull = true;
     }

   LvPeriods(bar.t);

   bool eqhLiq = false, eqlLiq = false;
   if(UseEQL)
     {
      EqDeliver(bar.t);
      EqImport(bar.t);
      datetime nowT = bar.t + 60;
      LlExpire(g_chH, EqAgeDays, nowT);
      LlExpire(g_chL, EqAgeDays, nowT);
      eqhLiq = EqCross(g_chH, true,  bar.t, bar.h, bar.l);
      eqlLiq = EqCross(g_chL, false, bar.t, bar.h, bar.l);
     }

   bool pdhLiq = false, pdlLiq = false, pwhLiq = false, pwlLiq = false;
   if(havePd && !pdhSwept && LvHit(true,  pdh, pdSince, bar.t, bar.h, bar.l)) { pdhSwept = true; pdhLiq = true; }
   if(havePd && !pdlSwept && LvHit(false, pdl, pdSince, bar.t, bar.h, bar.l)) { pdlSwept = true; pdlLiq = true; }
   if(havePw && !pwhSwept && LvHit(true,  pwh, pwSince, bar.t, bar.h, bar.l)) { pwhSwept = true; pwhLiq = true; }
   if(havePw && !pwlSwept && LvHit(false, pwl, pwSince, bar.t, bar.h, bar.l)) { pwlSwept = true; pwlLiq = true; }

   if(pdhLiq) SwpPush(pdh, g_pdhT, bar.t);
   if(pdlLiq) SwpPush(pdl, g_pdlT, bar.t);
   if(pwhLiq) SwpPush(pwh, g_pwhT, bar.t);
   if(pwlLiq) SwpPush(pwl, g_pwlT, bar.t);

   bool hsImb = UseHtfImbEntry && touchBearHtf;
   bool lsImb = UseHtfImbEntry && touchBullHtf;
   bool hs = (UsePDHL && pdhLiq) || (UsePWHL && pwhLiq) || (UseEQL && eqhLiq) || hsImb;
   bool ls = (UsePDHL && pdlLiq) || (UsePWHL && pwlLiq) || (UseEQL && eqlLiq) || lsImb;
   bool okBear = !UseHtfFilter || htfBear;
   bool okBull = !UseHtfFilter || htfBull;
   bool anyHs = hs && okBear && canTrade && inAnySession;
   bool anyLs = ls && okBull && canTrade && inAnySession;
   bool hsImbGated = hsImb && okBear && canTrade;
   bool lsImbGated = lsImb && okBull && canTrade;
   if(hs || ls)
      Ev(StringFormat("LIQ|%s|pdh=%d pdl=%d pwh=%d pwl=%d eqh=%d eql=%d imbB=%d imbU=%d", TimeToString(bar.t),
                      (int)pdhLiq, (int)pdlLiq, (int)pwhLiq, (int)pwlLiq, (int)eqhLiq, (int)eqlLiq, (int)touchBearHtf, (int)touchBullHtf));

   // ---- second chance: a stop-out in the entry's own session re-arms once ----
   bool stoppedOut = SecondChance && slJustHit && lastClosedEntryTime > 0 && SessKey(lastClosedEntryTime) == SessKey(bar.t);
   bool sameCycSess = (cycSessAsia && inAsiaNow) || (cycSessLondon && inLondonNow) || (cycSessNy && inNyNow);
   bool chanceOk = (state == 0) && !chanceUsed && canTrade && sameCycSess;
   if(chanceOk && stoppedOut && slWasShort)
     {
      chanceUsed = true;
      state = 1;
      sweepBarIdx = g_barIdx;
      sweepHi = bar.h;
      ceExtHi = bar.h; ceExtHiT = bar.t;
      double lv = 0; datetime lt = bar.t;
      if(CeRef(true, 1, lv, lt) >= 0) { mssRefBear = lv; mssRefBarTime = lt; }
      else                            { mssRefBear = bar.l; mssRefBarTime = bar.t; }
      if(mssRefBear >= bar.c) state = 0;     // already broken: nothing left to wait for
      Ev(StringFormat("CHANCE|BEAR|%s|state=%d", TimeToString(bar.t), state));
     }
   if(chanceOk && stoppedOut && !slWasShort)
     {
      chanceUsed = true;
      state = 2;
      sweepBarIdx = g_barIdx;
      sweepLo = bar.l;
      ceExtLo = bar.l; ceExtLoT = bar.t;
      double lv = 0; datetime lt = bar.t;
      if(CeRef(false, 1, lv, lt) >= 0) { mssRefBull = lv; mssRefBarTime = lt; }
      else                             { mssRefBull = bar.h; mssRefBarTime = bar.t; }
      if(mssRefBull <= bar.c) state = 0;
      Ev(StringFormat("CHANCE|BULL|%s|state=%d", TimeToString(bar.t), state));
     }

   // ---- arming (sequential ifs: an imbalance touch can flip a live cycle) ----
   if((state == 0 && anyHs) || (state == 2 && hsImbGated))
      ArmBear(bar, inAsiaNow, inLondonNow, inNyNow);
   if((state == 0 && anyLs) || (state == 1 && lsImbGated))
      ArmBull(bar, inAsiaNow, inLondonNow, inNyNow);

   // ---- what happened to this liquidity (shown on the chart) ----
   if(g_draw && (hs || ls))
     {
      string src = "";
      if(pdhLiq || pdlLiq) src += " PD";
      if(pwhLiq || pwlLiq) src += " PW";
      if(eqhLiq || eqlLiq) src += " EQ";
      if(touchBearHtf || touchBullHtf) src += " IMB";
      string why;
      if(sweepBarIdx == g_barIdx && state != 0) why = "ARMED";
      else if(!canTrade)                       why = "not armed: position open or day cap";
      else if(!inAnySession)                   why = "not armed: outside Asia/London/NY";
      else if((hs && !okBear) || (ls && !okBull)) why = "not armed: HTF filter";
      else                                     why = "ignored: a cycle is already active";
      string tstr = TimeToString(bar.t);
      g_liqNote = tstr + (hs ? " UP" : " DN") + src + " -> " + why;
     }

   // ---- early deadline for the structure hunt, session carry-over ----
   if((state == 1 || state == 2) && (g_barIdx - sweepBarIdx) > MssMaxBars)
      state = 0;
   if(state != 0 && !((cycSessAsia && inAsiaNow) || (cycSessLondon && inLondonNow) || (cycSessNy && inNyNow)))
      state = 0;

   // ---- structure break (a CLOSE, on a later candle than the sweep) ----
   bool bearMss = (state == 1) && (g_barIdx > sweepBarIdx) && (bar.c < mssRefBear);
   bool bullMss = (state == 2) && (g_barIdx > sweepBarIdx) && (bar.c > mssRefBull);

   // ---- CE relocation: only when a candle CLOSES beyond the extreme ----
   if(state == 1 && !bearMss)
     {
      if(bar.h > sweepHi) sweepHi = bar.h;
      if(bar.c > ceExtHi)
        {
         ceExtHi = bar.h; ceExtHiT = bar.t;
         double lv = 0; datetime lt = 0;
         if(CeRef(true, 1, lv, lt) == 1 && lt > mssRefBarTime) { mssRefBear = lv; mssRefBarTime = lt; }
        }
      else if(bar.h > ceExtHi && !SwingSig(true, ceExtHi, ceExtHiT))
        { ceExtHi = bar.h; ceExtHiT = bar.t; }
     }
   if(state == 2 && !bullMss)
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

   if(bearMss) { state = 3; Ev(StringFormat("MSS|BEAR|%s|ce=%.5f|close=%.5f", TimeToString(bar.t), mssRefBear, bar.c)); }
   if(bullMss) { state = 4; Ev(StringFormat("MSS|BULL|%s|ce=%.5f|close=%.5f", TimeToString(bar.t), mssRefBull, bar.c)); }

   // ---- entry: the break is the entry, while London/NY is open ----
   bool shortSig = (state == 3) && canTradeEntry;
   bool longSig  = (state == 4) && canTradeEntry;
   if(shortSig || longSig)
     {
      bool isShort = shortSig;
      double slStruct = isShort ? (sweepHi + g_sweepBuf) : (sweepLo - g_sweepBuf);
      double slPrice  = isShort ? (CapSLToMax ? MathMin(slStruct, bar.c + g_maxSL) : slStruct)
                                : (CapSLToMax ? MathMax(slStruct, bar.c - g_maxSL) : slStruct);
      double slDist   = isShort ? (slPrice - bar.c) : (bar.c - slPrice);
      double tpPrice  = isShort ? (bar.c - (slPrice - bar.c) * RRRatio) : (bar.c + (bar.c - slPrice) * RRRatio);
      bool valid = (slDist >= g_minSL) && (slDist <= g_maxSL) && (slDist > 0);
      if(valid)
        {
         double lots = CalcLots(slDist);
         bool ok = false;
         if(lots <= 0)
            Print("LiquidityAlgo: signal ", isShort ? "SHORT" : "LONG", " at ", TimeToString(bar.t),
                  " skipped: lot size is 0 (below the minimum lot or no tick value)");
         if(lots > 0)
           {
            int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
            double slN = NormalizeDouble(slPrice, dg);
            double tpN = NormalizeDouble(tpPrice, dg);
            if(isShort) ok = trade.Sell(lots, _Symbol, 0, slN, tpN, "LiqShort");
            else        ok = trade.Buy(lots, _Symbol, 0, slN, tpN, "LiqLong");
            if(!ok)
               Print("LiquidityAlgo: ORDER REJECTED ", isShort ? "SHORT" : "LONG", " at ", TimeToString(bar.t),
                     " lots=", DoubleToString(lots, 2), " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
           }
         Ev(StringFormat("ENTRY|%s|%s|close=%.5f|sl=%.5f|tp=%.5f|lots=%.2f|attempt=%d|ok=%d", TimeToString(bar.t),
                         isShort ? "SHORT" : "LONG", bar.c, slPrice, tpPrice, lots, attempt, (int)ok));
         if(ok) g_expectClose++;
         // counters follow the signal, like Pine's strategy.entry bookkeeping
         tradesToday++;
         if(inLondonNow) lonSessionTrades++;
         if(inNyNow)     nySessionTrades++;
         state = 0;
        }
     }

   // ---- late deadline for a break still waiting for a session ----
   if((state == 3 || state == 4) && (g_barIdx - sweepBarIdx) > MssMaxBars)
      state = 0;

   // drawing is throttled: nothing in it feeds back into the decisions
   if(g_draw && (g_barIdx % 3) == 1)
     {
      DrawZones(bar);
      ShowStatus(bar);
     }
  }

//======================================================================
// EA LIFECYCLE
//======================================================================
void InitHtf(const int i, const ENUM_TIMEFRAMES tf, const bool use, const int cap, const int ageDays, const long legSec)
  {
   g_h[i].tf = tf;
   g_h[i].use = use;
   g_h[i].cap = cap;
   g_h[i].ageDays = ageDays;
   g_h[i].legSec = legSec;
   GsClear(g_h[i].cB); GsClear(g_h[i].cU); GsClear(g_h[i].B); GsClear(g_h[i].U);
   g_h[i].up = 0;
   g_h[i].fedOpen = 0;
   g_h[i].nFed = 0;
   g_h[i].tB = false;
   g_h[i].tU = false;
  }

int OnInit()
  {
   if(EqlRefTF != PERIOD_H1 && EqlRefTF != PERIOD_H4 && EqlRefTF != PERIOD_D1 && EqlRefTF != PERIOD_W1 && EqlRefTF != PERIOD_MN1)
     {
      Print("EqlRefTF must be H1, H4, D1, W1 or MN1");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(EqlPivotStrength < 2 || EqlPivotStrength > 50 || EqlLookbackPivots < 2 || EqlLookbackPivots > 20 || MssMaxBars < 5)
     {
      Print("Invalid EQ / MSS parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(_Period != PERIOD_M1)
      Print("LiquidityAlgo is designed for the M1 chart / M1 tester model.");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_draw = ShowZones && (MQLInfoInteger(MQL_VISUAL_MODE) != 0 || MQLInfoInteger(MQL_TESTER) == 0);
   g_zoneSig = "";
   g_liqNote = "none yet";
   ArrayResize(g_swPx, 0); ArrayResize(g_swT1, 0); ArrayResize(g_swT2, 0);

   g_tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tick <= 0) g_tick = _Point;
   g_pen = (LiqPenTicks > 0) ? (LiqPenTicks - 0.01) * g_tick : 0.0;
   g_thr = ScaleThr ? g_tick / 0.00001 : 1.0;
   g_sweepBuf  = SweepBuffer * g_thr;
   g_maxSL     = MaxSL * g_thr;
   g_minSL     = MinSL * g_thr;
   g_eqlTol    = EqlTolerance * g_thr;
   g_htfFvgMin = HtfFvgMin * g_thr;
   g_mergeTol  = MergeTol * g_thr;

   InitHtf(0, PERIOD_H1,  UseHtf1H, 200, Age1HDays, (long)3 * 3600);
   InitHtf(1, PERIOD_H4,  UseHtf4H, 200, Age4HDays, (long)3 * 14400);
   InitHtf(2, PERIOD_D1,  UseHtfD,  60,  0,         (long)4 * 86400);
   InitHtf(3, PERIOD_W1,  UseHtfW,  60,  0,         (long)3 * 604800);
   InitHtf(4, PERIOD_MN1, UseHtfM,  24,  0,         (long)3 * 2678400);

   g_eqTf = EqlRefTF;
   LlClear(g_cxH); LlClear(g_cxL); LlClear(g_chH); LlClear(g_chL);
   ArrayResize(g_swH, 0); ArrayResize(g_swL, 0); ArrayResize(g_ring, 0);
   g_eqFedOpen = 0; g_upEQ = 0;

   state = 0; g_barIdx = 0; attempt = 1; chanceUsed = true;
   g_inited = false; g_prevHasPos = false; g_needPoll = false; g_dealScan = 0; g_expectClose = 0;
   lastSeenFormingBar = 0;
   lastProcessedM1Bar = 0;
   atrCount = 0; trSum = 0; atrM1 = 0; g_havePrevClose = false;

   // Chronological ATR warm-up from closed M1 history.
   MqlRates w[];
   ArraySetAsSeries(w, false);
   int got = CopyRates(_Symbol, PERIOD_M1, 1, 1500, w);
   if(got > 20)
     {
      bool asc = (w[0].time <= w[got - 1].time);
      for(int k = 0; k < got; k++)
        {
         int idx = asc ? k : (got - 1 - k);
         AtrStep(w[idx].high, w[idx].low, w[idx].close);
        }
      lastProcessedM1Bar = asc ? w[got - 1].time : w[0].time;
     }

   if(LogParity)
     {
      datetime t0 = TimeCurrent();
      PrintFormat("EVT|INIT|server=%s|utc=%s|pine=%s|day=%I64d|pen=%.8f|thr=%.4f", TimeToString(t0), TimeToString(ServerToUtc(t0)),
                  TimeToString(PineT(t0)), DayKeyOf(t0), g_pen, g_thr);
     }
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_draw)
     {
      ObjectsDeleteAll(0, "LA_");
      Comment("");
     }
  }

void OnTick()
  {
   // A new M1 bar is detected when the still-forming bar's open time changes:
   // the previous bar (shift 1) has just closed. One evaluation per closed bar,
   // like Pine's order_bar.
   datetime formingBar = iTime(_Symbol, PERIOD_M1, 0);
   if(formingBar == 0 || formingBar == lastSeenFormingBar) return;
   lastSeenFormingBar = formingBar;

   M1Bar bar;
   if(!GetM1(1, bar)) return;
   if(bar.t == lastProcessedM1Bar) return;
   lastProcessedM1Bar = bar.t;

   ProcessNewM1Bar(bar);
  }
//+------------------------------------------------------------------+
