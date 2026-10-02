#!/usr/bin/env python3
"""Independent reference of the Pine strategy decisions (series semantics,
bar_index offsets) for differential testing of the MQL5 port on synthetic data.
Usage: pine_ref.py data.csv [start_bar_offset]  -> prints EVT lines like the EA."""
import sys, datetime as dtm
from zoneinfo import ZoneInfo

# ---------------- inputs (Pine defaults) ----------------
PEN = (1 - 0.01) * 0.00001
SWEEP_BUF = 0.0
MAX_SL, MIN_SL, RR, CAP_SL = 0.0050, 0.0003, 2.0, True
HTF_MIN, MERGE_TOL = 0.0003, 0.0005
EQ_TOL, SW_LEN, EQ_LOOK, EQ_AGE = 0.0005, 10, 5, 14
AGE_1H, AGE_4H = 14, 45
USE = {'1h': True, '4h': True, 'd': True, 'w': True, 'm': False}
CE_LEG_PCT, CE_MIN_ATR, CE_CAP, SCAN, CONT_BARS, CONT_ATR, DISP, PIV, RUN = 25.0, 1.0, 1.25, 60, 8, 2.0, 0.75, 5, 3
MSS_MAX = 150
MAX_DAY, SESS_MAX = 4, 2
ASIA = (0, 8); LON = (9, 11); NY_OPEN = 14; NY_CLOSE = (16, 30)
SECOND_CHANCE = True
USE_PDHL = USE_PWHL = USE_EQL = USE_IMB_ENTRY = True

rows = [l.strip().split(',') for l in open(sys.argv[1])]
T = [int(r[0]) for r in rows]; O = [float(r[1]) for r in rows]; H = [float(r[2]) for r in rows]
L = [float(r[3]) for r in rows]; C = [float(r[4]) for r in rows]
N = len(T)
NY = ZoneInfo('America/New_York'); UTC = ZoneInfo('UTC')

def ts_fmt(t):
    d = dtm.datetime(1970, 1, 1) + dtm.timedelta(seconds=t)
    return d.strftime('%Y.%m.%d %H:%M')

def server_to_utc(ts):
    # server = New York + 7h, always
    ny_naive = dtm.datetime(1970, 1, 1) + dtm.timedelta(seconds=ts - 7 * 3600)
    ny = ny_naive.replace(tzinfo=NY)
    return int(ny.astimezone(UTC).replace(tzinfo=None).timestamp() - dtm.datetime(1970, 1, 1).timestamp()) if False else \
        int((ny.astimezone(UTC).replace(tzinfo=None) - dtm.datetime(1970, 1, 1)).total_seconds())

def pine_clock(ts):
    return server_to_utc(ts) + 2 * 3600

def hm(p):
    d = dtm.datetime(1970, 1, 1) + dtm.timedelta(seconds=p)
    return d.hour, d.minute, d.year * 10000 + d.month * 100 + d.day

def sess_key(ts):
    p = pine_clock(ts); hh, mm, dkey = hm(p); mins = hh * 60 + mm
    asia = (ASIA[0] <= hh < ASIA[1]) if ASIA[0] <= ASIA[1] else (hh >= ASIA[0] or hh < ASIA[1])
    b = 1 if asia else (3 if mins < LON[1] * 60 else (5 if mins < NY_CLOSE[0] * 60 + NY_CLOSE[1] else 6))
    if b == 6:
        _, _, dkey = hm(p + 86400); b = 1
    return dkey * 10 + b

def day_key(ts):
    utc = server_to_utc(ts)
    d = (dtm.datetime(1970, 1, 1) + dtm.timedelta(seconds=utc)).replace(tzinfo=UTC).astimezone(NY)
    return d.year * 10000 + d.month * 100 + d.day

# ---------------- higher-timeframe series ----------------
def key_of(tf, t):
    days = t // 86400
    if tf == 'h1': return t // 3600
    if tf == 'h4': return t // 14400
    if tf == 'd': return days
    if tf == 'w':
        dow = (days + 4) % 7
        return days - dow
    d = dtm.datetime(1970, 1, 1) + dtm.timedelta(seconds=t)
    return d.year * 12 + d.month

def open_of(tf, k):
    if tf == 'h1': return k * 3600
    if tf == 'h4': return k * 14400
    if tf in ('d', 'w'): return k * 86400
    y, m = divmod(k, 12)
    if m == 0: y -= 1; m = 12
    return int((dtm.datetime(y, m, 1) - dtm.datetime(1970, 1, 1)).total_seconds())

def close_of(tf, o):
    if tf == 'h1': return o + 3600
    if tf == 'h4': return o + 14400
    if tf == 'd': return o + 86400
    if tf == 'w': return o + 7 * 86400
    d = dtm.datetime(1970, 1, 1) + dtm.timedelta(seconds=o)
    y, m = d.year, d.month + 1
    if m > 12: y += 1; m = 1
    return int((dtm.datetime(y, m, 1) - dtm.datetime(1970, 1, 1)).total_seconds())

def build(tf):
    bars = []; last = None
    for i in range(N):
        k = key_of(tf, T[i])
        if k != last:
            bars.append([open_of(tf, k), O[i], H[i], L[i], C[i]]); last = k
        else:
            b = bars[-1]; b[2] = max(b[2], H[i]); b[3] = min(b[3], L[i]); b[4] = C[i]
    return bars

SER = {tf: build(tf) for tf in ('h1', 'h4', 'd', 'w', 'm')}

# ---- gap contexts: snapshot after every HTF bar (Pine f_ctx_gaps) ----
LEG = {'h1': 3 * 3600, 'h4': 3 * 14400, 'd': 4 * 86400, 'w': 3 * 604800, 'm': 3 * 2678400}
CAP = {'h1': 200, 'h4': 200, 'd': 60, 'w': 60, 'm': 24}
def ctx_gaps(tf):
    bars = SER[tf]; cB = []; cU = []; snaps = []
    for j, b in enumerate(bars):
        t, o, h, l, c = b
        cl = close_of(tf, t)
        cB = [g for g in cB if not (t >= g[3] and h >= g[0] + PEN)]
        cU = [g for g in cU if not (t >= g[3] and l <= g[0] - PEN)]
        if j >= 2:
            m2 = bars[j - 2]; m1 = bars[j - 1]
            if m2[3] > h and (m2[3] - h) >= HTF_MIN:
                cB.append((h, m2[3], m1[0], cl))
                if len(cB) > CAP[tf]: cB.pop(0)
            if m2[2] < l and (l - m2[2]) >= HTF_MIN:
                cU.append((l, m2[2], m1[0], cl))
                if len(cU) > CAP[tf]: cU.pop(0)
        snaps.append((list(cB), list(cU), cl))
    return snaps
GAP_SNAPS = {tf: ctx_gaps(tf) for tf in ('h1', 'h4', 'd', 'w', 'm')}

# ---- EQ context (Pine f_ctx_eq) on H1 ----
def ctx_eq(tf):
    bars = SER[tf]; hp = []; lp = []; swh = []; swl = []; snaps = []
    for j, b in enumerate(bars):
        t, o, h, l, c = b; cl = close_of(tf, t)
        hp = [e for e in hp if not (t >= e[2] and h >= e[0] + PEN)]
        lp = [e for e in lp if not (t >= e[2] and l <= e[0] - PEN)]
        if j >= 2 * SW_LEN:
            ch = bars[j - SW_LEN][2]; cl_ = bars[j - SW_LEN][3]; org = bars[j - SW_LEN][0]
            okh = okl = True
            for k in range(1, SW_LEN + 1):
                if bars[j - SW_LEN + k][2] >= ch or bars[j - SW_LEN - k][2] >= ch: okh = False
                if bars[j - SW_LEN + k][3] <= cl_ or bars[j - SW_LEN - k][3] <= cl_: okl = False
            if okh:
                for s in swh:
                    if abs(ch - s) <= EQ_TOL:
                        if not any(abs(ch - e[0]) <= EQ_TOL for e in hp):
                            hp.append((ch, org, cl))
                            if len(hp) > 100: hp.pop(0)
                        break
                if len(swh) >= EQ_LOOK: swh.pop(0)
                swh.append(ch)
            if okl:
                for s in swl:
                    if abs(cl_ - s) <= EQ_TOL:
                        if not any(abs(cl_ - e[0]) <= EQ_TOL for e in lp):
                            lp.append((cl_, org, cl))
                            if len(lp) > 100: lp.pop(0)
                        break
                if len(swl) >= EQ_LOOK: swl.pop(0)
                swl.append(cl_)
        snaps.append((list(hp), list(lp), cl))
    return snaps
EQ_SNAPS = ctx_eq('h1')

# ---------------- chart-side state ----------------
def latest_delivered(snaps, lim, idx_hint):
    # latest HTF bar whose close <= lim
    while idx_hint + 1 < len(snaps) and snaps[idx_hint + 1][2] <= lim: idx_hint += 1
    return idx_hint

class Gaps:
    def __init__(self, tf, age):
        self.tf = tf; self.age = age; self.B = []; self.U = []; self.up = 0; self.idx = -1; self.tB = False; self.tU = False
    def step(self, t, h, l):
        lim = t + 60
        self.idx = latest_delivered(GAP_SNAPS[self.tf], lim, self.idx)
        self.tB = self.tU = False
        if self.idx >= 0:
            cB, cU, _ = GAP_SNAPS[self.tf][self.idx]
            mxB = mxU = self.up
            for g in cB:
                if g[3] > self.up and g[3] <= lim:
                    self.B.append(g); mxB = max(mxB, g[3])
                    if len(self.B) > CAP[self.tf]: self.B.pop(0)
            for g in cU:
                if g[3] > self.up and g[3] <= lim:
                    self.U.append(g); mxU = max(mxU, g[3])
                    if len(self.U) > CAP[self.tf]: self.U.pop(0)
            self.up = max(mxB, mxU)
        if self.age > 0:
            for lst in (self.B, self.U):
                while lst and (lim - lst[0][2]) > self.age * 86400: lst.pop(0)
        self.tB = self.cross(self.B, True, t, h, l)
        self.tU = self.cross(self.U, False, t, h, l)
    def cross(self, lst, supply, t, h, l):
        n = len(lst)
        hits = [i for i in range(n) if t >= lst[i][3] and ((h >= lst[i][0] + PEN) if supply else (l <= lst[i][0] - PEN))]
        if not hits: return False
        idx = sorted(range(n), key=lambda i: (-lst[i][0] if supply else lst[i][0]))
        outer = [True] * n; cur = None
        for i in idx:
            e, f, o, _ = lst[i]
            if cur is not None:
                ce, co = cur
                linked = (ce <= f + MERGE_TOL if supply else ce >= f - MERGE_TOL) or abs(co - o) <= LEG[self.tf]
                outer[i] = not linked
            cur = (e, o)
        touch = any(outer[i] for i in hits)
        for i in sorted(hits, reverse=True): lst.pop(i)
        return touch

GAPS = {k: Gaps(k, a) for k, a in (('h1', AGE_1H), ('h4', AGE_4H), ('d', 0), ('w', 0), ('m', 0))}
USEMAP = {'h1': USE['1h'], 'h4': USE['4h'], 'd': USE['d'], 'w': USE['w'], 'm': USE['m']}

eqH = []; eqL = []; eq_idx = -1; eq_up = 0
pd_idx_d = 0; pd_idx_w = 0
pdh = pdl = pwh = pwl = None; pd_open = pw_open = None; pd_since = pw_since = 0
pdh_sw = pdl_sw = pwh_sw = pwl_sw = False

# ---------------- ATR / CE ----------------
atr_hist = []; atr_val = None; atr_sum = 0.0; atr_n = 0
def atr_step(i):
    global atr_val, atr_sum, atr_n
    tr = H[i] - L[i] if i == 0 else max(H[i] - L[i], abs(H[i] - C[i - 1]), abs(L[i] - C[i - 1]))
    if atr_n < 14:
        atr_sum += tr; atr_n += 1
        atr_val = atr_sum / 14 if atr_n == 14 else None
    else:
        atr_val = (atr_val * 13 + tr) / 14
def nzatr(): return atr_val if atr_val is not None else 0.0

def ce_ref(i, short, e_off):
    res = None; res_bar = None; found = False
    lim = min(SCAN, 495 - e_off)
    hi = lambda k: H[i - k]; lo = lambda k: L[i - k]; cl = lambda k: C[i - k]; op = lambda k: O[i - k]
    if e_off >= 0 and lim >= 3:
        ext = hi(e_off) if short else lo(e_off)
        own = ((cl(e_off) > op(e_off)) if short else (cl(e_off) < op(e_off))) and abs(cl(e_off) - op(e_off)) >= DISP * nzatr()
        if own:
            for j in range(e_off + 1, e_off + min(PIV, lim - 1) + 1):
                piv = (lo(j) < lo(j + 1) and lo(j) < lo(j - 1)) if short else (hi(j) > hi(j + 1) and hi(j) > hi(j - 1))
                if piv:
                    found = True; res = lo(j) if short else hi(j); res_bar = i - j; break
            if not found:
                k = e_off + 1
                while k < e_off + lim and ((cl(k) > op(k)) if short else (cl(k) < op(k))): k += 1
                if k - e_off >= RUN and k < e_off + lim:
                    kk = k
                    if (lo(k - 1) < lo(k)) if short else (hi(k - 1) > hi(k)): kk = k - 1
                    found = True; res = lo(kk) if short else hi(kk); res_bar = i - kk
        if not found:
            m_i = e_off if own else e_off + 1
            m = lo(m_i) if short else hi(m_i)
            rev = False if own else ((cl(m_i) < op(m_i)) if short else (cl(m_i) > op(m_i)))
            for k in range(m_i + 1, e_off + lim + 1):
                rev = rev or ((cl(k) < op(k)) if short else (cl(k) > op(k)))
                thr = max(CE_MIN_ATR * nzatr(), min(abs(ext - m) * CE_LEG_PCT / 100.0, CE_CAP * nzatr()))
                cm = (hi(k) - m) if short else (m - lo(k))
                if cm > 0 and cm >= thr and rev:
                    found = True
                    if (lo(k) < m) if short else (hi(k) > m):
                        m = lo(k) if short else hi(k); m_i = k
                    break
                if (lo(k) < m) if short else (hi(k) > m):
                    m = lo(k) if short else hi(k); m_i = k
                    rev = (cl(k) < op(k)) if short else (cl(k) > op(k))
            res = m; res_bar = i - m_i
    return res, res_bar, found

def swing_sig(i, level, level_bar, rising):
    n = min(i - level_bar - 1, 495); depth = 0.0
    if n >= 1:
        for k in range(1, n + 1):
            d = (level - L[i - k]) if rising else (H[i - k] - level)
            if d >= depth: depth = d
    return (i - level_bar >= CONT_BARS) and (depth >= CONT_ATR * nzatr())

# ---------------- state ----------------
state = 0; sweep_bar = 0
cyc_asia = cyc_lon = cyc_ny = False
sweep_hi = sweep_lo = None; ce_ext_hi = ce_ext_lo = None; ce_ext_hi_bar = ce_ext_lo_bar = None
mss_bear = mss_bull = None; mss_bar = None; chance_used = True
attempt = 1; trades_today = 0; last_day = None; lon_tr = ny_tr = 0; prev_lon = prev_ny = False
pend = None; pos = None; closed = 0; last_closed_entry_t = None; last_closed_profit = None; last_closed_short = None
out = []

def ev(s): out.append('EVT|' + s)

RISK = [None, 0.01, 0.0111, 0.0122, 0.0133, 0.0144, 0.0155]
def run():
    global state, sweep_bar, cyc_asia, cyc_lon, cyc_ny, sweep_hi, sweep_lo, ce_ext_hi, ce_ext_lo, ce_ext_hi_bar, ce_ext_lo_bar
    global mss_bear, mss_bull, mss_bar, chance_used, attempt, trades_today, last_day, lon_tr, ny_tr, prev_lon, prev_ny, pend, pos, closed
    global last_closed_entry_t, last_closed_profit, last_closed_short
    global pdh, pdl, pwh, pwl, pd_open, pw_open, pd_since, pw_since, pdh_sw, pdl_sw, pwh_sw, pwl_sw, eqH, eqL, eq_idx, eq_up
    for i in range(N):
        t = T[i]; h, l, c = H[i], L[i], C[i]
        # ---- broker: fill pending at open, SL/TP inside the bar ----
        closed_now = False
        if pend:
            pos = dict(short=pend['short'], lots=pend['lots'], entry=O[i], sl=pend['sl'], tp=pend['tp'], t=t); pend = None
        if pos:
            hs = h >= pos['sl'] if pos['short'] else l <= pos['sl']
            ht = l <= pos['tp'] if pos['short'] else h >= pos['tp']
            if hs or ht:
                ex = pos['sl'] if hs else pos['tp']
                pr = ((pos['entry'] - ex) if pos['short'] else (ex - pos['entry'])) * pos['lots'] * 100000
                closed += 1; closed_now = True
                last_closed_entry_t = pos['t']; last_closed_profit = pr; last_closed_short = pos['short']
                pos = None
        atr_step(i)
        if closed_now:
            attempt = 1 if last_closed_profit > 0 else min(attempt + 1, 6)
            ev('EXIT|%s|profit=%.2f|attempt=%d' % (ts_fmt(t), last_closed_profit, attempt))
        p = pine_clock(t); hh, mm, _ = hm(p)
        in_lon = LON[0] <= hh < LON[1]
        ny_closed = hh > NY_CLOSE[0] or (hh == NY_CLOSE[0] and mm >= NY_CLOSE[1])
        in_ny = hh >= NY_OPEN and not ny_closed
        in_asia = (ASIA[0] <= hh < ASIA[1]) if ASIA[0] <= ASIA[1] else (hh >= ASIA[0] or hh < ASIA[1])
        in_any = in_asia or in_lon or in_ny
        dk = day_key(t)
        if dk != last_day: trades_today = 0; last_day = dk
        if in_lon and not prev_lon: lon_tr = 0
        if in_ny and not prev_ny: ny_tr = 0
        prev_lon, prev_ny = in_lon, in_ny
        can_trade = trades_today < MAX_DAY and pos is None
        can_entry = can_trade and ((in_lon and lon_tr < SESS_MAX) or (in_ny and ny_tr < SESS_MAX))

        # ---- HTF imbalances ----
        tB_any = tU_any = False
        for k, g in GAPS.items():
            if not USEMAP[k]: continue
            g.step(t, h, l)
            tB_any |= g.tB; tU_any |= g.tU
        # ---- PD / PW ----
        sd = SER['d']
        k_d = pd_idx_d_f(sd, t)
        if k_d is not None and k_d >= 1:
            po = sd[k_d - 1][0]
            if po != pd_open:
                pd_open = po; pdh = sd[k_d - 1][2]; pdl = sd[k_d - 1][3]; pd_since = po + 86400; pdh_sw = pdl_sw = False
                ev('LVL|PD|%s|%.5f|%.5f' % (ts_fmt(po), pdh, pdl))
        sw_ = SER['w']; k_w = pd_idx_d_f(sw_, t)
        if k_w is not None and k_w >= 1:
            po = sw_[k_w - 1][0]
            if po != pw_open:
                pw_open = po; pwh = sw_[k_w - 1][2]; pwl = sw_[k_w - 1][3]; pw_since = po + 7 * 86400; pwh_sw = pwl_sw = False
                ev('LVL|PW|%s|%.5f|%.5f' % (ts_fmt(po), pwh, pwl))
        # ---- EQ ----
        eqh_liq = eql_liq = False
        if USE_EQL:
            lim = t + 60
            eq_idx = latest_delivered(EQ_SNAPS, lim, eq_idx)
            if eq_idx >= 0:
                hp, lp, _ = EQ_SNAPS[eq_idx]; mxh = mxl = eq_up
                for e in hp:
                    if e[2] > eq_up and e[2] <= lim: eqH.append(e); mxh = max(mxh, e[2]); eqH = eqH[-100:]
                for e in lp:
                    if e[2] > eq_up and e[2] <= lim: eqL.append(e); mxl = max(mxl, e[2]); eqL = eqL[-100:]
                eq_up = max(mxh, mxl)
            if EQ_AGE > 0:
                while eqH and (t + 60 - eqH[0][1]) > EQ_AGE * 86400: eqH.pop(0)
                while eqL and (t + 60 - eqL[0][1]) > EQ_AGE * 86400: eqL.pop(0)
            for e in list(eqH):
                if t >= e[2] and h >= e[0] + PEN: eqH.remove(e); eqh_liq = True
            for e in list(eqL):
                if t >= e[2] and l <= e[0] - PEN: eqL.remove(e); eql_liq = True
        pdh_l = pdl_l = pwh_l = pwl_l = False
        if pdh is not None and not pdh_sw and t >= pd_since and h >= pdh + PEN: pdh_sw = pdh_l = True
        if pdl is not None and not pdl_sw and t >= pd_since and l <= pdl - PEN: pdl_sw = pdl_l = True
        if pwh is not None and not pwh_sw and t >= pw_since and h >= pwh + PEN: pwh_sw = pwh_l = True
        if pwl is not None and not pwl_sw and t >= pw_since and l <= pwl - PEN: pwl_sw = pwl_l = True
        hs_imb = USE_IMB_ENTRY and tB_any; ls_imb = USE_IMB_ENTRY and tU_any
        hs = (USE_PDHL and pdh_l) or (USE_PWHL and pwh_l) or (USE_EQL and eqh_liq) or hs_imb
        ls = (USE_PDHL and pdl_l) or (USE_PWHL and pwl_l) or (USE_EQL and eql_liq) or ls_imb
        any_hs = hs and can_trade and in_any; any_ls = ls and can_trade and in_any
        hs_imb_g = hs_imb and can_trade; ls_imb_g = ls_imb and can_trade
        if hs or ls:
            ev('LIQ|%s|pdh=%d pdl=%d pwh=%d pwl=%d eqh=%d eql=%d imbB=%d imbU=%d' % (ts_fmt(t), pdh_l, pdl_l, pwh_l, pwl_l, eqh_liq, eql_liq, tB_any, tU_any))
        # ---- second chance ----
        stopped = SECOND_CHANCE and closed_now and last_closed_profit < 0 and sess_key(last_closed_entry_t) == sess_key(t)
        same_cyc = (cyc_asia and in_asia) or (cyc_lon and in_lon) or (cyc_ny and in_ny)
        chance_ok = state == 0 and not chance_used and can_trade and same_cyc
        if chance_ok and stopped and last_closed_short:
            chance_used = True; state = 1; sweep_bar = i; sweep_hi = h; ce_ext_hi = h; ce_ext_hi_bar = i
            rc, rb, _ = ce_ref(i, True, 0); mss_bear = l if rc is None else rc; mss_bar = i if rb is None else rb
            if mss_bear >= c: state = 0
            ev('CHANCE|BEAR|%s|state=%d' % (ts_fmt(t), state))
        if chance_ok and stopped and not last_closed_short:
            chance_used = True; state = 2; sweep_bar = i; sweep_lo = l; ce_ext_lo = l; ce_ext_lo_bar = i
            rc, rb, _ = ce_ref(i, False, 0); mss_bull = h if rc is None else rc; mss_bar = i if rb is None else rb
            if mss_bull <= c: state = 0
            ev('CHANCE|BULL|%s|state=%d' % (ts_fmt(t), state))
        # ---- arming ----
        if (state == 0 and any_hs) or (state == 2 and hs_imb_g):
            state = 1; sweep_bar = i; cyc_asia, cyc_lon, cyc_ny = in_asia, in_lon, in_ny; chance_used = False
            sweep_hi = h; ce_ext_hi = h; ce_ext_hi_bar = i
            rc, rb, _ = ce_ref(i, True, 0); mss_bear = l if rc is None else rc; mss_bar = i if rb is None else rb
            ev('ARM|BEAR|%s|hi=%.5f|ce=%.5f' % (ts_fmt(t), sweep_hi, mss_bear))
        if (state == 0 and any_ls) or (state == 1 and ls_imb_g):
            state = 2; sweep_bar = i; cyc_asia, cyc_lon, cyc_ny = in_asia, in_lon, in_ny; chance_used = False
            sweep_lo = l; ce_ext_lo = l; ce_ext_lo_bar = i
            rc, rb, _ = ce_ref(i, False, 0); mss_bull = h if rc is None else rc; mss_bar = i if rb is None else rb
            ev('ARM|BULL|%s|lo=%.5f|ce=%.5f' % (ts_fmt(t), sweep_lo, mss_bull))
        if state in (1, 2) and (i - sweep_bar) > MSS_MAX: state = 0
        if state != 0 and not ((cyc_asia and in_asia) or (cyc_lon and in_lon) or (cyc_ny and in_ny)): state = 0
        bear_mss = state == 1 and i > sweep_bar and mss_bear is not None and c < mss_bear
        bull_mss = state == 2 and i > sweep_bar and mss_bull is not None and c > mss_bull
        if state == 1 and not bear_mss:
            if h > sweep_hi: sweep_hi = h
            if c > ce_ext_hi:
                ce_ext_hi = h; ce_ext_hi_bar = i
                rc, rb, ok = ce_ref(i, True, 0)
                if ok and (mss_bar is None or rb > mss_bar): mss_bear = rc; mss_bar = rb
            elif h > ce_ext_hi and not swing_sig(i, ce_ext_hi, ce_ext_hi_bar, True):
                ce_ext_hi = h; ce_ext_hi_bar = i
        if state == 2 and not bull_mss:
            if l < sweep_lo: sweep_lo = l
            if c < ce_ext_lo:
                ce_ext_lo = l; ce_ext_lo_bar = i
                rc, rb, ok = ce_ref(i, False, 0)
                if ok and (mss_bar is None or rb > mss_bar): mss_bull = rc; mss_bar = rb
            elif l < ce_ext_lo and not swing_sig(i, ce_ext_lo, ce_ext_lo_bar, False):
                ce_ext_lo = l; ce_ext_lo_bar = i
        if bear_mss: state = 3; ev('MSS|BEAR|%s|ce=%.5f|close=%.5f' % (ts_fmt(t), mss_bear, c))
        if bull_mss: state = 4; ev('MSS|BULL|%s|ce=%.5f|close=%.5f' % (ts_fmt(t), mss_bull, c))
        short_sig = state == 3 and can_entry; long_sig = state == 4 and can_entry
        if short_sig or long_sig:
            sh = short_sig
            st = sweep_hi + SWEEP_BUF if sh else sweep_lo - SWEEP_BUF
            slp = (min(st, c + MAX_SL) if CAP_SL else st) if sh else (max(st, c - MAX_SL) if CAP_SL else st)
            sd_ = (slp - c) if sh else (c - slp)
            tp = (c - (slp - c) * RR) if sh else (c + (c - slp) * RR)
            if sd_ >= MIN_SL and sd_ <= MAX_SL and sd_ > 0:
                qty = 100000 * RISK[attempt] / sd_ / 100000
                pend = dict(short=sh, lots=round(qty, 2), sl=round(slp, 5), tp=round(tp, 5))
                ev('ENTRY|%s|%s|close=%.5f|sl=%.5f|tp=%.5f' % (ts_fmt(t), 'SHORT' if sh else 'LONG', c, slp, tp))
                trades_today += 1
                if in_lon: lon_tr += 1
                if in_ny: ny_tr += 1
                state = 0
        if state in (3, 4) and (i - sweep_bar) > MSS_MAX: state = 0

def pd_idx_d_f(ser, t):
    # index of the HTF bar containing t (last open <= t) via cached pointer
    key = id(ser)
    p = _ptr.get(key, 0)
    while p + 1 < len(ser) and ser[p + 1][0] <= t: p += 1
    _ptr[key] = p
    return p if ser[p][0] <= t else None
_ptr = {}

run()
for l in out: print(l)
