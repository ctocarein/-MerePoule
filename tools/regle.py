"""Rejoue la règle AUTORISÉ / INTERDIT / RETOURNEMENT (décision 25) sur
l'historique du terminal MT5 ouvert, en LECTURE SEULE, et la confronte aux
cycles réels du robot. Même logique que Scripts/MerePoule/MerePouleRegle.mq5,
en Python pour caler les réglages sans passer par MT5.

    python tools/regle.py [--days 30] [--confirm 2] [--slope 0.10] ...

Nécessite le module officiel MetaTrader5 (pip install MetaTrader5) et MT5
ouvert sur le compte. N'appelle aucune fonction de trading.
"""
import argparse
import bisect
import csv
import sys
import time
from dataclasses import dataclass, field

import MetaTrader5 as mt5

M5, M30, H1 = 300, 1800, 3600
TF = {M5: mt5.TIMEFRAME_M5, M30: mt5.TIMEFRAME_M30, H1: mt5.TIMEFRAME_H1}
WARMUP = 300


@dataclass
class Position:
    id: int
    symbol: str
    dir: int = 0          # +1 achat, -1 vente
    tin: int = 0
    tout: int = 0
    price: float = 0.0
    volume: float = 0.0
    net: float = 0.0
    closed: bool = False


@dataclass
class Cycle:
    symbol: str
    dir: int
    want: int
    start: int
    end: int
    members: list = field(default_factory=list)
    net: float = 0.0
    state: int = 0        # 1 AUTORISÉ, 0 INTERDIT
    m5: int = 0
    m30: int = 0
    h1: int = 0
    rev_at: int = 0
    cut: float = 0.0


def want_dir(symbol, robot_dir):
    if "PainX" in symbol:
        return -1
    if "GainX" in symbol:
        return 1
    return robot_dir


def load_positions(since, magic, comment=""):
    deals = mt5.history_deals_get(since - 7 * 86400, int(time.time()) + 2 * 86400) or ()
    pos = {}
    for d in deals:
        if d.type not in (mt5.DEAL_TYPE_BUY, mt5.DEAL_TYPE_SELL):
            continue
        p = pos.setdefault(d.position_id, Position(d.position_id, d.symbol))
        p.net += d.profit + d.swap + d.commission + d.fee
        if d.entry == mt5.DEAL_ENTRY_IN:
            if (magic and d.magic != magic) or (comment and not (d.comment or "").startswith(comment)):
                p.dir = 9
                continue
            p.dir = 1 if d.type == mt5.DEAL_TYPE_BUY else -1
            p.tin, p.price, p.volume = d.time, d.price, d.volume
        else:
            p.closed = True
            p.tout = max(p.tout, d.time)
    return [p for p in pos.values() if p.dir in (1, -1) and p.tin >= since and p.closed]


def load_rates(symbol, seconds, since, now):
    mt5.symbol_select(symbol, True)
    for _ in range(40):
        r = mt5.copy_rates_range(symbol, TF[seconds], since - WARMUP * seconds, now + seconds)
        if r is not None and len(r) > WARMUP:
            return r
        time.sleep(0.5)
    return None


def trend(r, no_jumps, a_fast, a_slow, slope_bars, slope_atr, jump_atr):
    """État par bougie (1 hausse, -1 baisse, 0 neutre), clôture de la série,
    EMA rapide et ATR ; sans les sauts si no_jumps."""
    n = len(r)
    state, adj, ef_s, atr_s, es_s = [0] * n, [0.0] * n, [0.0] * n, [0.0] * n, [0.0] * n
    k_f, k_s = 2.0 / (a_fast + 1), 2.0 / (a_slow + 1)
    a = r[0]["high"] - r[0]["low"]
    offset = 0.0
    ef = es = r[0]["close"]
    for i in range(n):
        hi, lo, cl = r[i]["high"], r[i]["low"], r[i]["close"]
        tr = hi - lo if i == 0 else max(hi - lo, abs(hi - r[i - 1]["close"]), abs(lo - r[i - 1]["close"]))
        jump = no_jumps and i > 20 and jump_atr > 0 and tr > jump_atr * a
        if jump:
            offset += cl - r[i - 1]["close"]
        else:
            a = (a * i + tr) / (i + 1) if i < 14 else (a * 13 + tr) / 14
        c = cl - offset
        ef += k_f * (c - ef)
        es += k_s * (c - es)
        adj[i], ef_s[i], es_s[i], atr_s[i] = c, ef, es, a
        s = 0
        if i >= a_slow + slope_bars and a > 0:
            slope = (es - es_s[i - slope_bars]) / a
            if c < es and ef < es and slope <= -slope_atr:
                s = -1
            elif c > es and ef > es and slope >= slope_atr:
                s = 1
        state[i] = s
    return state, adj, ef_s, atr_s


def closed_at(close_times, t):
    """Indice de la dernière bougie fermée à l'instant t, -1 sinon."""
    return bisect.bisect_right(close_times, t) - 1


def analyze(symbol, positions, since, now, no_jumps, o):
    mine = sorted((p for p in positions if p.symbol == symbol), key=lambda p: p.tin)
    buys = sum(1 for p in mine if p.dir > 0)
    want = want_dir(symbol, 1 if buys >= len(mine) - buys else -1)
    rates = {s: load_rates(symbol, s, since, now) for s in (M5, M30, H1)}
    if any(r is None for r in rates.values()):
        return None
    st, adj, ef, atr, closes = {}, {}, {}, {}, {}
    for s, r in rates.items():
        st[s], adj[s], ef[s], atr[s] = trend(r, no_jumps, o.fast, o.slow, o.slope_bars, o.slope, o.jump)
        closes[s] = [int(t) + s for t in r["time"]]
    r5 = rates[M5]
    n5 = len(r5) - 1  # dernière bougie en cours
    auth, rev = [0] * n5, [False] * n5
    final, streak_state, streak, switches, auth_bars, period_bars = -1, -1, 0, 0, 0, 0
    for i in range(n5):
        t = closes[M5][i]
        j30, j60 = closed_at(closes[M30], t), closed_at(closes[H1], t)
        ok = st[M5][i] == want and ((j30 >= 0 and st[M30][j30] == want) or (j60 >= 0 and st[H1][j60] == want))
        raw = 1 if ok else 0
        if raw == streak_state:
            streak += 1
        else:
            streak_state, streak = raw, 1
        if final < 0:
            final = raw
        elif raw != final and streak >= o.confirm:
            final = raw
            if t >= since:
                switches += 1
        auth[i] = final
        body = r5[i]["close"] - r5[i]["open"]
        a = atr[M5][i - 1] if i > 0 else atr[M5][i]
        rev[i] = (want < 0 and body >= o.reversal * a and adj[M5][i] > ef[M5][i]) or \
                 (want > 0 and body <= -o.reversal * a and adj[M5][i] < ef[M5][i])
        if t >= since:
            period_bars += 1
            auth_bars += final == 1

    info = mt5.symbol_info(symbol)
    per_point = info.trade_tick_value / info.trade_tick_size if info and info.trade_tick_size else 0.0
    cycles = []
    for d in (-1, 1):
        same = [p for p in mine if p.dir == d]
        k = 0
        while k < len(same):
            c = Cycle(symbol, d, want, same[k].tin, same[k].tout)
            while k < len(same) and (not c.members or same[k].tin < c.end):
                c.members.append(same[k])
                c.net += same[k].net
                c.end = max(c.end, same[k].tout)
                k += 1
            i0 = closed_at(closes[M5], c.start)
            if i0 < 0 or i0 >= n5:
                continue
            c.state = auth[i0]
            c.m5 = st[M5][i0]
            j30, j60 = closed_at(closes[M30], c.start), closed_at(closes[H1], c.start)
            c.m30 = st[M30][j30] if j30 >= 0 else 0
            c.h1 = st[H1][j60] if j60 >= 0 else 0
            c.cut = c.net
            for i in range(i0 + 1, n5):
                t = closes[M5][i]
                if t >= c.end:
                    break
                if not rev[i]:
                    continue
                c.rev_at = t
                price = r5[i]["close"]
                c.cut = sum(p.net if p.tout <= t else
                            (price - p.price) * p.dir * p.volume * per_point if p.tin <= t else 0.0
                            for p in c.members)
                break
            cycles.append(c)
    days = max(1.0, period_bars * 300 / 86400)
    return {"symbol": symbol, "want": want, "buys": buys, "sells": len(mine) - buys, "cycles": cycles,
            "auth_pct": 100.0 * auth_bars / period_bars if period_bars else 0.0, "switches_day": switches / days}


def fmt_t(t, offset):
    return time.strftime("%d/%m %H:%M", time.gmtime(t - offset))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--magic", type=int, default=0)
    ap.add_argument("--comment", default="", help="version du robot : début du commentaire des trades, ex. CJF48")
    ap.add_argument("--fast", type=int, default=20)
    ap.add_argument("--slow", type=int, default=50)
    ap.add_argument("--slope-bars", type=int, default=5)
    ap.add_argument("--slope", type=float, default=0.10)
    ap.add_argument("--jump", type=float, default=4.0)
    ap.add_argument("--confirm", type=int, default=2)
    ap.add_argument("--reversal", type=float, default=1.5)
    ap.add_argument("--csv", default="")
    ap.add_argument("--detail", action="store_true", help="liste chaque cycle")
    o = ap.parse_args()

    if not mt5.initialize():
        sys.exit(f"MT5 injoignable : {mt5.last_error()}")
    try:
        ticks = [mt5.symbol_info_tick(s) for s in ("MAX GainX 1000", "MAX PainX 1000")]
        now = max(t.time for t in ticks if t)
        offset = round((now - time.time()) / 1800) * 1800  # heure serveur - GMT
        since = now - o.days * 86400
        positions = load_positions(since, o.magic, o.comment)
        symbols = sorted({p.symbol for p in positions})
        print(f"Compte {mt5.account_info().login} : {len(positions)} positions fermées sur {o.days} j, "
              f"symboles {', '.join(symbols)} ; heure serveur = GMT{offset / 3600:+.0f}")
        print(f"Réglages : EMA {o.fast}/{o.slow}, pente {o.slope_bars} bougies >= {o.slope} ATR, "
              f"confirmation {o.confirm} M5, retournement {o.reversal} ATR, saut > {o.jump} ATR")
        writer = None
        if o.csv:
            fh = open(o.csv, "w", newline="", encoding="utf-8-sig")
            writer = csv.writer(fh, delimiter=";")
            writer.writerow(["passe", "symbole", "sens", "debut_gmt", "fin_gmt", "positions", "resultat", "etat",
                             "m5", "m30", "h1", "retournement_gmt", "coupe"])
        for no_jumps in (False, True):
            print(f"\n=== {'Prix sans les sauts' if no_jumps else 'Prix bruts'} ===")
            tot = {"real": 0.0, "auth": 0.0, "forb": 0.0, "policy": 0.0, "na": 0, "nf": 0}
            for s in symbols:
                res = analyze(s, positions, since, now, no_jumps, o)
                if res is None:
                    print(f"{s} : bougies indisponibles")
                    continue
                cy = res["cycles"]
                a = [c for c in cy if c.state == 1]
                f = [c for c in cy if c.state != 1]
                hit = [c for c in a if c.rev_at]
                sa, sf = sum(c.net for c in a), sum(c.net for c in f)
                pol = sum(c.cut for c in a)
                print(f"{s} ({'vente' if res['want'] < 0 else 'achat'} voulu ; robot {res['buys']} achats, {res['sells']} ventes)")
                print(f"  AUTORISÉ {res['auth_pct']:.0f} % du temps, {res['switches_day']:.1f} changements/jour")
                print(f"  cycles AUTORISÉ : {len(a):3d}, résultat {sa:9.2f} ({sum(c.net > 0 for c in a)} gagnants), pire {min((c.net for c in a), default=0):.2f}")
                print(f"  cycles INTERDIT : {len(f):3d}, résultat {sf:9.2f} ({sum(c.net > 0 for c in f)} gagnants), pire {min((c.net for c in f), default=0):.2f}")
                print(f"  retournement dans {len(hit)} cycle(s) AUTORISÉ : couper aurait changé {sum(c.cut - c.net for c in hit):+.2f}")
                tot["real"] += sa + sf
                tot["auth"] += sa
                tot["forb"] += sf
                tot["policy"] += pol
                tot["na"] += len(a)
                tot["nf"] += len(f)
                for c in cy:
                    row = ["sans sauts" if no_jumps else "brut", s, "achat" if c.dir > 0 else "vente",
                           fmt_t(c.start, offset), fmt_t(c.end, offset), len(c.members), f"{c.net:.2f}",
                           "AUTORISE" if c.state == 1 else "INTERDIT", c.m5, c.m30, c.h1,
                           fmt_t(c.rev_at, offset) if c.rev_at else "", f"{c.cut:.2f}"]
                    if writer:
                        writer.writerow(row)
                    if o.detail:
                        print("   ", " ".join(str(x) for x in row[2:]))
            print(f"--- Tous symboles : réel {tot['real']:.2f} ({tot['na'] + tot['nf']} cycles)")
            print(f"    AUTORISÉ {tot['auth']:.2f} ({tot['na']}) ; INTERDIT {tot['forb']:.2f} ({tot['nf']})")
            print(f"    en bloquant les INTERDIT : {tot['auth']:.2f} ; et en coupant au retournement : {tot['policy']:.2f}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
