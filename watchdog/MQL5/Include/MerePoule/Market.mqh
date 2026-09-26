//+------------------------------------------------------------------+
//| Market.mqh                                                       |
//| Contexte de marche des symboles du robot, en bougies H1, pour    |
//| expliquer un arret et aider a decider d'une relance. Regles      |
//| fixes, lisibles, sans prediction :                               |
//|  - variation du prix sur 1 h, 4 h et 24 h                        |
//|  - tendance : hausse ou baisse si le prix a bouge de plus d'une  |
//|    bougie H1 moyenne (ATR 14) en 4 h, neutre sinon               |
//|  - agitation : ATR 14 compare a l'ATR moyen des 5 derniers jours |
//|    (au-dessus de 1,5 : agite ; sous 0,7 : calme)                 |
//|  - sens du robot : ses entrees des 7 derniers jours sur le       |
//|    symbole, achats (buy), ventes (sell), les deux (both) ou rien  |
//|    (""). Une tendance ne gene le robot que contre son sens.       |
//|  - regle du trader (decision 25), en information : tendance M5, |
//|    M30 et H1 (EMA 20/50 et pente, bougies fermees) ; AUTORISE si  |
//|    M5 va dans le sens voulu (PainX vente, GainX achat) et M30 ou  |
//|    H1 aussi, confirme sur 2 bougies M5 ; RETOURNEMENT si la       |
//|    derniere bougie M5 est forte (corps > 1,5 ATR) contre ce sens. |
//|    Memes reglages que tools/regle.py et MerePouleRegle.          |
//|  - regle choisie par symbole (decision 30, 1.34) : tendance (la  |
//|    regle ci-dessus), saut (aucun saut depuis x min : pause), les |
//|    deux, ou aucune ; "allowed" dit si le robot peut y tourner.   |
//|    Le choix vit dans une variable globale du terminal.           |
//| Rien ici ne declenche un arret ni une relance : la Mere decide   |
//| des pauses a partir de ces verdicts.                             |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_MARKET_MQH
#define MEREPOULE_MARKET_MQH

#include "Json.mqh"
#include "Jumps.mqh"

#define MP_MARKET_REFRESH_SEC 60
#define MP_SIDES_REFRESH_SEC  900     // l'historique change lentement
#define MP_SIDES_DAYS         7
#define MP_SIDE_DOMINANT      4.0     // 4 entrees sur 5 dans un sens : ce sens
#define MP_RULE_BARS          300
#define MP_RULE_FAST          20
#define MP_RULE_SLOW          50
#define MP_RULE_SLOPE_BARS    5
#define MP_RULE_SLOPE_ATR     0.10
#define MP_RULE_CONFIRM       2
#define MP_RULE_REVERSAL      1.5

//--- Mouvement du prix en mots simples : "baisse nettement", "reste stable"...
string MP_MoveText(const string trend, const double chg4h)
{
   if(trend == "hausse") return "monte nettement";
   if(trend == "baisse") return "baisse nettement";
   if(trend != "neutre") return "tendance inconnue";
   if(chg4h >= 0.3)      return "monte un peu";
   if(chg4h <= -0.3)     return "baisse un peu";
   return "reste stable";
}

//--- "-2,5 %", a la francaise.
string MP_PctText(const double v)
{
   string s = StringFormat("%+.1f", v);
   StringReplace(s, ".", ",");
   return s + " %";
}

string MP_MoodText(const string mood)
{
   if(mood == "agite") return "march{e'} tr{e`}s nerveux";
   if(mood == "calme") return "march{e'} tr{e`}s calme";
   if(mood == "normal") return "mouvements habituels";
   return "agitation inconnue";
}

//--- Tendance bougie par bougie (serie chronologique) : 1 hausse, -1
//--- baisse, 0 neutre ; baisse si cloture < EMA lente, EMA rapide < EMA
//--- lente et pente de la lente <= -seuil (en ATR), hausse a l'inverse.
void MP_RuleTrend(const MqlRates &r[], int &state[], double &emaFast[], double &atr[])
{
   int n = ArraySize(r);
   ArrayResize(state, n);
   ArrayResize(emaFast, n);
   ArrayResize(atr, n);
   double emaSlow[];
   ArrayResize(emaSlow, n);
   if(n == 0) return;
   double kF = 2.0 / (MP_RULE_FAST + 1.0), kS = 2.0 / (MP_RULE_SLOW + 1.0);
   double a = r[0].high - r[0].low, ef = r[0].close, es = r[0].close;
   for(int i = 0; i < n; i++)
   {
      double tr = (i == 0) ? r[i].high - r[i].low
                : MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      a = (i < 14) ? (a * i + tr) / (i + 1) : (a * 13.0 + tr) / 14.0;
      double c = r[i].close;
      ef += kF * (c - ef);
      es += kS * (c - es);
      emaFast[i] = ef;
      emaSlow[i] = es;
      atr[i] = a;
      int s = 0;
      if(i >= MP_RULE_SLOW + MP_RULE_SLOPE_BARS && a > 0.0)
      {
         double slope = (es - emaSlow[i - MP_RULE_SLOPE_BARS]) / a;
         if(c < es && ef < es && slope <= -MP_RULE_SLOPE_ATR)     s = -1;
         else if(c > es && ef > es && slope >= MP_RULE_SLOPE_ATR) s = 1;
      }
      state[i] = s;
   }
}

//--- Derniere bougie fermee a l'instant t (serie chronologique), -1 sinon.
int MP_ClosedAt(const MqlRates &r[], const int seconds, const datetime t)
{
   int lo = 0, hi = ArraySize(r) - 1, found = -1;
   while(lo <= hi)
   {
      int mid = (lo + hi) / 2;
      if(r[mid].time + seconds <= t) { found = mid; lo = mid + 1; }
      else hi = mid - 1;
   }
   return found;
}

string MP_TrendName(const int s) { return s > 0 ? "hausse" : s < 0 ? "baisse" : "neutre"; }

//--- Verdicts confirmes, bougie M5 par bougie M5 (series chronologiques ;
//--- la derniere bougie de r5, en cours, est exclue) : auth[i] 1 AUTORISE,
//--- 0 INTERDIT ; counter[i] 1 contre-tendance confirmee. Un changement
//--- doit tenir MP_RULE_CONFIRM bougies. Renvoie le nombre de bougies.
//--- Meme calcul en direct (derniere bougie) et dans le Lecteur (toutes).
int MP_RuleSeries(const MqlRates &r5[], const MqlRates &r30[], const MqlRates &r60[],
                  const int &s5[], const int &s30[], const int &s60[], const int want,
                  int &auth[], int &counter[])
{
   int n5 = MathMax(0, ArraySize(r5) - 1);
   ArrayResize(auth, n5);
   ArrayResize(counter, n5);
   int finalState = -1, streakState = -1, streak = 0;
   int counterState = -1, cStreakState = -1, cStreak = 0;   // miroir : contre-tendance
   for(int i = 0; i < n5; i++)
   {
      datetime t = r5[i].time + 300;
      int j30 = MP_ClosedAt(r30, 1800, t), j60 = MP_ClosedAt(r60, 3600, t);
      bool ok = s5[i] == want && ((j30 >= 0 && s30[j30] == want) || (j60 >= 0 && s60[j60] == want));
      int raw = ok ? 1 : 0;
      if(raw == streakState) streak++;
      else { streakState = raw; streak = 1; }
      if(finalState < 0) finalState = raw;
      else if(raw != finalState && streak >= MP_RULE_CONFIRM) finalState = raw;

      bool against = s5[i] == -want && ((j30 >= 0 && s30[j30] == -want) || (j60 >= 0 && s60[j60] == -want));
      int rawC = against ? 1 : 0;
      if(rawC == cStreakState) cStreak++;
      else { cStreakState = rawC; cStreak = 1; }
      if(counterState < 0) counterState = rawC;
      else if(rawC != counterState && cStreak >= MP_RULE_CONFIRM) counterState = rawC;

      auth[i]    = finalState;
      counter[i] = counterState;
   }
   return n5;
}

//--- Sens voulu par la regle : PainX a la vente, GainX a l'achat ; sinon
//--- le sens habituel du robot ; 0 si inconnu ou mixte.
int MP_WantFor(const string symbol, const string side)
{
   if(StringFind(symbol, "PainX") >= 0) return -1;
   if(StringFind(symbol, "GainX") >= 0) return 1;
   if(side == "buy")  return 1;
   if(side == "sell") return -1;
   return 0;
}

//--- Regle choisie par symbole (decision 30). Tendance par defaut : le
//--- comportement d'avant 1.34.
#define MP_MODE_TREND 0   // M5 dans le sens voulu, et M30 ou H1 (decision 25)
#define MP_MODE_JUMP  1   // pas de saut depuis x min : pause
#define MP_MODE_BOTH  2   // les deux
#define MP_MODE_NONE  3   // aucune : le robot tourne sans filtre
#define MP_MODES      4

string MP_ModeName(const int mode)
{
   if(mode == MP_MODE_JUMP) return "jump";
   if(mode == MP_MODE_BOTH) return "both";
   if(mode == MP_MODE_NONE) return "none";
   return "trend";
}

//--- -1 si inconnu.
int MP_ModeFromName(const string name)
{
   for(int m = 0; m < MP_MODES; m++)
      if(MP_ModeName(m) == name) return m;
   return -1;
}

string MP_ModePlain(const int mode)
{
   if(mode == MP_MODE_JUMP) return "saut";
   if(mode == MP_MODE_BOTH) return "tendance et saut";
   if(mode == MP_MODE_NONE) return "aucune";
   return "tendance";
}

bool MP_ModeTrend(const int mode) { return mode == MP_MODE_TREND || mode == MP_MODE_BOTH; }
bool MP_ModeJump(const int mode)  { return mode == MP_MODE_JUMP || mode == MP_MODE_BOTH; }

//--- Le robot peut-il tourner, selon la regle choisie ? trendOk : verdict
//--- AUTORISE de la tendance ; late : aucun saut depuis x min.
bool MP_ModeAllows(const int mode, const bool trendOk, const bool late)
{
   if(MP_ModeTrend(mode) && !trendOk) return false;
   if(MP_ModeJump(mode) && late) return false;
   return true;
}

struct MP_Market
{
   string symbol;
   double price;
   double chg1h;    // %
   double chg4h;
   double chg24h;
   string trend;    // hausse, baisse, neutre
   string mood;     // calme, normal, agite
   string side;     // sens habituel du robot : buy, sell, both ou ""
   int    want;     // regle : sens voulu, 1 achat, -1 vente, 0 sans regle
   int    m5, m30, h1;
   bool   allowed;  // AUTORISE, confirme sur MP_RULE_CONFIRM bougies M5
   bool   reversal; // derniere bougie M5 fermee : forte, contre le sens voulu
   bool   counter;  // contre-tendance confirmee : M5 contre le sens voulu et M30 ou H1 aussi (1.33)
   double chg60;    // variation sur les 60 dernieres minutes, %
   int    trend1h;  // tendance sur 1 h : 1 hausse, -1 baisse, 0 neutre (mouvement > 1/2 bougie H1 moyenne)
   int    mode;     // regle choisie : MP_MODE_* (1.34)
   int    jumpAge;  // minutes depuis le dernier saut, -1 inconnu
   bool   late;     // aucun saut depuis x min
   bool   go;       // la regle choisie laisse tourner le robot
};

class CMarket
{
private:
   MP_Market m_data[];
   datetime  m_at;
   string    m_key;   // symboles du dernier calcul
   long      m_magic;
   string    m_gv;        // prefixe des variables globales du compte
   int       m_lateMin;   // regle saut : pause sans saut depuis ces minutes (0 = jamais)
   datetime  m_sidesAt;
   string    m_sideSym[];
   string    m_side[];

   //--- Entrees du robot des 7 derniers jours, par symbole : son sens.
   void RefreshSides(const string &symbols[])
   {
      if(m_sidesAt > 0 && TimeLocal() - m_sidesAt < MP_SIDES_REFRESH_SEC) return;
      m_sidesAt = TimeLocal();
      int n = ArraySize(symbols);
      int buys[], sells[];
      ArrayResize(buys, n);
      ArrayResize(sells, n);
      ArrayInitialize(buys, 0);
      ArrayInitialize(sells, 0);
      if(HistorySelect(TimeCurrent() - MP_SIDES_DAYS * 86400, TimeCurrent() + 3600))
         for(int d = 0; d < HistoryDealsTotal(); d++)
         {
            ulong deal = HistoryDealGetTicket(d);
            if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
            if(m_magic != 0 && HistoryDealGetInteger(deal, DEAL_MAGIC) != m_magic) continue;
            string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
            long   type = HistoryDealGetInteger(deal, DEAL_TYPE);
            for(int i = 0; i < n; i++)
               if(symbols[i] == sym)
               {
                  if(type == DEAL_TYPE_BUY)  buys[i]++;
                  if(type == DEAL_TYPE_SELL) sells[i]++;
                  break;
               }
         }
      ArrayResize(m_sideSym, n);
      ArrayResize(m_side, n);
      for(int i = 0; i < n; i++)
      {
         m_sideSym[i] = symbols[i];
         if(buys[i] + sells[i] == 0)                        m_side[i] = "";
         else if(buys[i] >= MP_SIDE_DOMINANT * sells[i])    m_side[i] = "buy";
         else if(sells[i] >= MP_SIDE_DOMINANT * buys[i])    m_side[i] = "sell";
         else                                               m_side[i] = "both";
      }
   }

   //--- Regle du trader sur ce symbole ; false si les bougies manquent.
   static bool ComputeRule(const string symbol, MP_Market &m)
   {
      m.m5 = m.m30 = m.h1 = 0;
      m.allowed = false;
      m.reversal = false;
      m.counter = false;
      m.chg60 = 0.0;
      m.trend1h = 0;
      if(m.want == 0) return true;
      MqlRates r5[], r30[], r60[];
      if(CopyRates(symbol, PERIOD_M5, 0, MP_RULE_BARS, r5) < 100
         || CopyRates(symbol, PERIOD_M30, 0, MP_RULE_BARS, r30) < 100
         || CopyRates(symbol, PERIOD_H1, 0, MP_RULE_BARS, r60) < 100) return false;
      int s5[], s30[], s60[];
      double ef5[], atr5[], ef30[], atr30[], ef60[], atr60[];
      MP_RuleTrend(r5, s5, ef5, atr5);
      MP_RuleTrend(r30, s30, ef30, atr30);
      MP_RuleTrend(r60, s60, ef60, atr60);

      int auth[], counter[];
      int n5   = MP_RuleSeries(r5, r30, r60, s5, s30, s60, m.want, auth, counter);   // la derniere bougie est en cours
      int last = n5 - 1;
      if(last < 1) return false;
      datetime now = r5[last].time + 300;
      int j30 = MP_ClosedAt(r30, 1800, now), j60 = MP_ClosedAt(r60, 3600, now);
      m.m5  = s5[last];
      m.m30 = (j30 >= 0) ? s30[j30] : 0;
      m.h1  = (j60 >= 0) ? s60[j60] : 0;
      m.allowed = auth[last] == 1;
      m.counter = counter[last] == 1;

      //--- Sur 1 h : le prix actuel contre celui d'il y a 12 bougies M5 ;
      //--- tendance si le mouvement depasse une demi-bougie H1 moyenne.
      if(n5 >= 12 && r5[n5 - 12].close > 0.0)
      {
         double move = r5[n5].close - r5[n5 - 12].close;
         m.chg60 = move / r5[n5 - 12].close * 100.0;
         double atrH1 = (j60 >= 0) ? atr60[j60] : 0.0;
         m.trend1h = (atrH1 > 0.0 && MathAbs(move) >= 0.5 * atrH1) ? (move > 0.0 ? 1 : -1) : 0;
      }
      double body = r5[last].close - r5[last].open;
      double a    = atr5[last - 1];
      m.reversal = (m.want < 0 && body >=  MP_RULE_REVERSAL * a && r5[last].close > ef5[last])
                || (m.want > 0 && body <= -MP_RULE_REVERSAL * a && r5[last].close < ef5[last]);
      return true;
   }

   string SideOf(const string symbol) const
   {
      for(int i = 0; i < ArraySize(m_sideSym); i++)
         if(m_sideSym[i] == symbol) return m_side[i];
      return "";
   }

   static double TrueRange(const MqlRates &bar, const double prevClose)
   {
      return MathMax(bar.high - bar.low, MathMax(MathAbs(bar.high - prevClose), MathAbs(bar.low - prevClose)));
   }

   static bool Compute(const string symbol, MP_Market &m)
   {
      //--- Aucun graphique n'est necessaire : robot eteint, ses symboles
      //--- restent lus. Il suffit qu'ils soient dans l'Observation du marche.
      if(!SymbolInfoInteger(symbol, SYMBOL_SELECT)) SymbolSelect(symbol, true);
      MqlRates r[];
      ArraySetAsSeries(r, true);
      int n = CopyRates(symbol, PERIOD_H1, 0, 130, r);   // historique pas encore charge : nouvel essai a la minute suivante
      if(n < 30) return false;

      m.symbol = symbol;
      m.price  = r[0].close;
      m.chg1h  = (r[1].close > 0.0) ? (r[0].close - r[1].close) / r[1].close * 100.0 : 0.0;
      m.chg4h  = (r[4].close > 0.0) ? (r[0].close - r[4].close) / r[4].close * 100.0 : 0.0;
      m.chg24h = (n > 24 && r[24].close > 0.0) ? (r[0].close - r[24].close) / r[24].close * 100.0 : 0.0;

      double atr14 = 0.0, atrLong = 0.0;
      int    longN = MathMin(n - 1, 120);
      for(int i = 1; i <= longN; i++)
      {
         double tr = TrueRange(r[i], r[i + 1 < n ? i + 1 : i].close);
         if(i <= 14) atr14 += tr;
         atrLong += tr;
      }
      atr14   /= 14.0;
      atrLong /= longN;

      double move4 = r[0].close - r[4].close;
      m.trend = (atr14 > 0.0 && MathAbs(move4) > atr14) ? (move4 > 0.0 ? "hausse" : "baisse") : "neutre";
      double ratio = (atrLong > 0.0) ? atr14 / atrLong : 1.0;
      m.mood = (ratio > 1.5) ? "agite" : (ratio < 0.7) ? "calme" : "normal";
      return true;
   }

   int Find(const string symbol) const
   {
      for(int i = 0; i < ArraySize(m_data); i++)
         if(m_data[i].symbol == symbol) return i;
      return -1;
   }

public:
   CMarket() : m_at(0), m_key(""), m_magic(0), m_gv(""), m_lateMin(0), m_sidesAt(0) {}

   void Init(const long magic, const string gv, const int lateMin)
   {
      m_magic   = magic;
      m_gv      = gv;
      m_lateMin = MathMax(0, lateMin);
      m_sidesAt = 0;
   }

   int LateMin() const { return m_lateMin; }

   //--- Regle choisie pour un symbole ; tendance si jamais choisie.
   int ModeOf(const string symbol) const
   {
      string name = m_gv + "rule." + symbol;
      if(m_gv == "" || !GlobalVariableCheck(name)) return MP_MODE_TREND;
      int mode = (int)GlobalVariableGet(name);
      return (mode >= 0 && mode < MP_MODES) ? mode : MP_MODE_TREND;
   }

   //--- Verdict de la regle choisie, d'apres la tendance et le dernier saut.
   void ApplyMode(MP_Market &m) const
   {
      m.mode = ModeOf(m.symbol);
      m.late = m_lateMin > 0 && m.jumpAge >= m_lateMin;
      m.go   = m.want != 0 && MP_ModeAllows(m.mode, m.allowed, m.late);
   }

   void SetMode(const string symbol, const int mode)
   {
      if(m_gv == "") return;
      GlobalVariableSet(m_gv + "rule." + symbol, mode);
      int i = Find(symbol);
      if(i >= 0) ApplyMode(m_data[i]);
   }

   //--- Recalcule au plus une fois par minute, ou tout de suite si la liste change.
   void Update(const string &symbols[], const bool force = false)
   {
      string key = "";
      for(int i = 0; i < ArraySize(symbols); i++) key += symbols[i] + "|";
      if(!force && key == m_key && TimeLocal() - m_at < MP_MARKET_REFRESH_SEC) return;
      if(key != m_key) m_sidesAt = 0;   // nouveau symbole : son sens tout de suite
      m_key = key;
      m_at  = TimeLocal();
      RefreshSides(symbols);

      MP_Market fresh[];
      for(int i = 0; i < ArraySize(symbols); i++)
      {
         MP_Market m;
         if(!Compute(symbols[i], m))
         {
            int old = Find(symbols[i]);   // garder le dernier calcul plutot que rien
            if(old < 0) continue;
            m = m_data[old];
         }
         m.side = SideOf(symbols[i]);
         m.want = MP_WantFor(symbols[i], m.side);
         MP_Market prev;
         int old = Find(symbols[i]);
         if(!ComputeRule(symbols[i], m) && old >= 0)
         {
            prev = m_data[old];   // bougies manquantes : garder le dernier verdict
            m.m5 = prev.m5; m.m30 = prev.m30; m.h1 = prev.h1;
            m.allowed = prev.allowed; m.reversal = prev.reversal;
            m.counter = prev.counter; m.chg60 = prev.chg60; m.trend1h = prev.trend1h;
         }
         m.jumpAge = MP_JumpAge(symbols[i], m.want);
         if(m.jumpAge < 0 && old >= 0) m.jumpAge = m_data[old].jumpAge;   // bougies M1 manquantes
         ApplyMode(m);
         int k = ArraySize(fresh);
         ArrayResize(fresh, k + 1);
         fresh[k] = m;
      }
      ArrayResize(m_data, ArraySize(fresh));
      for(int i = 0; i < ArraySize(fresh); i++) m_data[i] = fresh[i];
   }

   bool Get(const string symbol, MP_Market &m) const
   {
      int i = Find(symbol);
      if(i < 0) return false;
      m = m_data[i];
      return true;
   }

   //--- "baisse nettement (-2,5 % en 4 h), mouvements habituels, contre le
   //--- robot, qui y achete" ; "" si inconnu.
   string Line(const string symbol) const
   {
      int i = Find(symbol);
      if(i < 0) return "";
      MP_Market m = m_data[i];
      string trend = m.trend;
      double chg   = m.chg4h;
      string span  = "4 h";
      if(m.want != 0)   // 1.33 : le trader decide sur 1 h
      {
         trend = MP_TrendName(m.trend1h);
         chg   = m.chg60;
         span  = "1 h";
      }
      string s = MP_MoveText(trend, chg) + " (" + MP_PctText(chg) + " en " + span + "), " + MP_MoodText(m.mood);
      string verb = (m.side == "buy") ? "ach{e`}te" : (m.side == "sell") ? "vend" : "";
      if(verb == "") return s;
      bool against = (m.side == "buy" && trend == "baisse") || (m.side == "sell" && trend == "hausse");
      if(against)               s += ", contre le robot, qui y " + verb;
      else if(trend != "neutre") s += ", bon pour le robot, qui y " + verb;
      if(m.want != 0) s += " ; " + RuleText(m);
      return s;
   }

   //--- "ta regle (saut) : INTERDIT (aucun saut depuis 47 min)" ; sans
   //--- regle, les tendances pour information.
   static string RuleText(const MP_Market &m)
   {
      string why = "";
      if(m.mode != MP_MODE_JUMP)
         why = StringFormat("M5 %s, M30 %s, H1 %s", MP_TrendName(m.m5), MP_TrendName(m.m30), MP_TrendName(m.h1));
      if(MP_ModeJump(m.mode)) why += (why != "" ? ", " : "") + MP_JumpText(m.jumpAge);
      if(m.mode == MP_MODE_NONE) return "sans r{e`}gle, ton choix (" + why + ")";
      return StringFormat("ta r{e`}gle (%s) : %s (%s)", MP_ModePlain(m.mode), m.go ? "AUTORIS{E'}" : "INTERDIT", why);
   }

   string Json() const
   {
      string s = "[";
      for(int i = 0; i < ArraySize(m_data); i++)
      {
         if(i > 0) s += ",";
         s += "{\"symbol\":" + MP_JsonStr(m_data[i].symbol)
            + ",\"price\":" + DoubleToString(m_data[i].price, (int)SymbolInfoInteger(m_data[i].symbol, SYMBOL_DIGITS))
            + ",\"chg_1h_pct\":" + MP_JsonNum(m_data[i].chg1h, 2)
            + ",\"chg_4h_pct\":" + MP_JsonNum(m_data[i].chg4h, 2)
            + ",\"chg_24h_pct\":" + MP_JsonNum(m_data[i].chg24h, 2)
            + ",\"trend\":" + MP_JsonStr(m_data[i].trend)
            + ",\"volatility\":" + MP_JsonStr(m_data[i].mood)
            + ",\"robot_side\":" + MP_JsonStr(m_data[i].side)
            + ",\"want\":" + MP_JsonStr(m_data[i].want > 0 ? "buy" : m_data[i].want < 0 ? "sell" : "")
            + ",\"m5\":" + MP_JsonStr(m_data[i].want != 0 ? MP_TrendName(m_data[i].m5) : "")
            + ",\"m30\":" + MP_JsonStr(m_data[i].want != 0 ? MP_TrendName(m_data[i].m30) : "")
            + ",\"h1\":" + MP_JsonStr(m_data[i].want != 0 ? MP_TrendName(m_data[i].h1) : "")
            + ",\"rule\":" + MP_JsonStr(m_data[i].want == 0 ? "" : m_data[i].allowed ? "autorise" : "interdit")
            + ",\"reversal\":" + (m_data[i].reversal ? "true" : "false")
            + ",\"counter\":" + (m_data[i].counter ? "true" : "false")
            + ",\"chg_60m_pct\":" + MP_JsonNum(m_data[i].chg60, 2)
            + ",\"trend_1h\":" + MP_JsonStr(m_data[i].want != 0 ? MP_TrendName(m_data[i].trend1h) : "")
            + ",\"rule_mode\":" + MP_JsonStr(m_data[i].want != 0 ? MP_ModeName(m_data[i].mode) : "")
            + ",\"jump_age_min\":" + IntegerToString(m_data[i].jumpAge)
            + ",\"jump_late\":" + MP_JsonBool(m_data[i].late)
            + ",\"allowed\":" + MP_JsonBool(m_data[i].go) + "}";
      }
      return s + "]";
   }
};

#endif // MEREPOULE_MARKET_MQH
