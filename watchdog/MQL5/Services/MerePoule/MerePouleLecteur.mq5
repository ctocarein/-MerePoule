//+------------------------------------------------------------------+
//| MerePouleLecteur.mq5                                             |
//| Service MT5, sans graphique : le comparatif des regles           |
//| (decision 30). LECTURE SEULE : il ne trade pas et ne touche ni   |
//| au robot ni a la Mere.                                           |
//|                                                                  |
//| A part de la Mere, pour ne jamais ralentir ni faire tomber sa    |
//| surveillance : il attend compare.flag dans le dossier du contrat,|
//| relit l'historique, ecrit lecteur.json et supprime le drapeau.   |
//|                                                                  |
//| Pour chaque symbole, 4 reglages de la Mere : tendance (M5, et    |
//| M30 ou H1, dans le sens voulu), saut (pause quand aucun saut     |
//| depuis x min), les deux, aucune. Memes calculs qu'elle en direct |
//| (Market.mqh, Jumps.mqh). Deux comparatifs :                      |
//|  - marche : une entree comme le robot (vente PainX, achat GainX) |
//|    a chaque cloture M5, tenue jusqu'au saut suivant, au lot       |
//|    habituel du robot, spread compris ; gardee si le reglage       |
//|    laissait tourner le robot a ce moment ;                       |
//|  - robot : ses vrais cycles (positions du meme sens qui se       |
//|    chevauchent), gardes si le reglage le laissait tourner a leur |
//|    debut.                                                        |
//| Indicatif : les entrees du marche se chevauchent, et un cycle    |
//| bloque aurait decale les suivants.                               |
//|                                                                  |
//| Installation : Navigateur de MT5, Services, clic droit, Ajouter  |
//| un service, MerePouleLecteur. Il redemarre ensuite avec MT5.     |
//+------------------------------------------------------------------+
#property service
#property version     "1.00"
#property description "MerePoule Lecteur : compare les regles tendance et saut sur l'historique (lecture seule)."

#include <MerePoule\Contract.mqh>
#include <MerePoule\Market.mqh>
#include <MerePoule\Text.mqh>

#define LECTEUR_VERSION    "1.0"
#define LECTEUR_POLL_MS    2000
#define LECTEUR_DAYS       30
#define LECTEUR_DAYS_MAX   60
#define LECTEUR_MIN_CYCLES 30      // moins de vrais cycles : la recommandation suit le marche
#define LECTEUR_LOT        0.1     // lot des entrees du marche si le robot n'a rien trade

//--- Ce que garde un reglage : entrees (ou cycles), gagnantes, resultat.
struct Tally
{
   int    n;
   int    wins;
   double total;
};

struct Position
{
   ulong    id;
   string   symbol;
   int      dir;      // +1 achat, -1 vente, 0 inconnu, 9 exclu (autre magic)
   datetime tin;
   datetime tout;
   double   volume;
   double   net;
   bool     closed;
};

Position g_pos[];

//+------------------------------------------------------------------+
//| Historique du compte                                             |
//+------------------------------------------------------------------+
int FindPos(const ulong id)
{
   for(int i = ArraySize(g_pos) - 1; i >= 0; i--)
      if(g_pos[i].id == id) return i;
   return -1;
}

//--- Positions entrees depuis from et refermees, reconstituees depuis les
//--- transactions ; magic 0 = toutes.
int LoadPositions(const datetime from, const long magic)
{
   ArrayResize(g_pos, 0);
   if(!HistorySelect(from - 7 * 86400, TimeCurrent() + 86400)) return 0;
   int deals = HistoryDealsTotal();
   for(int d = 0; d < deals; d++)
   {
      ulong t    = HistoryDealGetTicket(d);
      long  type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      ulong id = (ulong)HistoryDealGetInteger(t, DEAL_POSITION_ID);
      int   k  = FindPos(id);
      if(k < 0)
      {
         k = ArraySize(g_pos);
         ArrayResize(g_pos, k + 1, 1000);
         g_pos[k].id     = id;
         g_pos[k].symbol = HistoryDealGetString(t, DEAL_SYMBOL);
         g_pos[k].dir    = 0;
         g_pos[k].tin    = 0;
         g_pos[k].tout   = 0;
         g_pos[k].volume = 0.0;
         g_pos[k].net    = 0.0;
         g_pos[k].closed = false;
      }
      g_pos[k].net += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
                    + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_FEE);
      datetime when = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN)
      {
         if(magic != 0 && HistoryDealGetInteger(t, DEAL_MAGIC) != magic) { g_pos[k].dir = 9; continue; }
         g_pos[k].dir    = (type == DEAL_TYPE_BUY) ? 1 : -1;
         g_pos[k].tin    = when;
         g_pos[k].volume = HistoryDealGetDouble(t, DEAL_VOLUME);
      }
      else
      {
         g_pos[k].closed = true;
         if(when > g_pos[k].tout) g_pos[k].tout = when;
      }
   }
   int kept = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
   {
      if((g_pos[i].dir != 1 && g_pos[i].dir != -1) || g_pos[i].tin < from || !g_pos[i].closed) continue;
      g_pos[kept++] = g_pos[i];
   }
   ArrayResize(g_pos, kept);
   return kept;
}

//--- Positions d'un symbole, par heure d'entree ; lot median et sens du robot.
int SymbolPositions(const string symbol, int &idx[], double &lot, string &side)
{
   ArrayResize(idx, 0);
   int buys = 0, sells = 0;
   double vols[];
   for(int i = 0; i < ArraySize(g_pos); i++)
   {
      if(g_pos[i].symbol != symbol) continue;
      int n = ArraySize(idx);
      ArrayResize(idx, n + 1, 1000);
      ArrayResize(vols, n + 1, 1000);
      idx[n]  = i;
      vols[n] = g_pos[i].volume;
      if(g_pos[i].dir > 0) buys++; else sells++;
   }
   for(int a = 1; a < ArraySize(idx); a++)
   {
      int v = idx[a], b = a - 1;
      while(b >= 0 && g_pos[idx[b]].tin > g_pos[v].tin) { idx[b + 1] = idx[b]; b--; }
      idx[b + 1] = v;
   }
   int n = ArraySize(vols);
   lot = LECTEUR_LOT;
   if(n > 0) { ArraySort(vols); lot = vols[n / 2]; }
   side = (buys + sells == 0) ? "" : (buys >= 4 * sells) ? "buy" : (sells >= 4 * buys) ? "sell" : "both";
   return n;
}

bool LoadRates(const string symbol, const ENUM_TIMEFRAMES tf, const datetime start, MqlRates &r[], const int minBars)
{
   for(int attempt = 0; attempt < 40 && !IsStopped(); attempt++)   // historique a telecharger : jusqu'a 20 s
   {
      int n = CopyRates(symbol, tf, start, TimeCurrent(), r);
      if(n > minBars) return true;
      Sleep(500);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Comparatif d'un symbole                                          |
//+------------------------------------------------------------------+
void Count(Tally &t, const double net)
{
   t.n++;
   t.total += net;
   if(net > 0.0) t.wins++;
}

string TallyJson(const Tally &t[])
{
   string s = "{";
   for(int m = 0; m < MP_MODES; m++)
      s += (m > 0 ? "," : "") + MP_JsonStr(MP_ModeName(m)) + ":{\"n\":" + IntegerToString(t[m].n)
         + ",\"wins\":" + IntegerToString(t[m].wins) + ",\"total\":" + MP_JsonNum(t[m].total, 2) + "}";
   return s + "}";
}

//--- Meilleur reglage : le plus gros resultat ; a egalite, le plus simple
//--- (aucune, puis tendance, saut, les deux).
int Best(const Tally &t[])
{
   int order[] = {MP_MODE_NONE, MP_MODE_TREND, MP_MODE_JUMP, MP_MODE_BOTH};
   int best = order[0];
   for(int k = 1; k < ArraySize(order); k++)
      if(t[order[k]].total > t[best].total + 0.005) best = order[k];
   return best;
}

//--- Dernier saut a ou avant i (-1 aucun), et saut suivant apres i (-1 aucun).
void JumpIndex(const bool &jump[], int &lastJ[], int &nextJ[])
{
   int n = ArraySize(jump);
   ArrayResize(lastJ, n);
   ArrayResize(nextJ, n);
   int last = -1;
   for(int i = 0; i < n; i++) { if(jump[i]) last = i; lastJ[i] = last; }
   int next = -1;
   for(int i = n - 1; i >= 0; i--) { nextJ[i] = next; if(jump[i]) next = i; }
}

bool IsLate(const MqlRates &r1[], const int &lastJ[], const int k, const datetime t, const int lateMin)
{
   if(lateMin <= 0) return false;
   if(k < 0 || lastJ[k] < 0) return true;
   return MP_JumpMinutes(r1[lastJ[k]], t) >= lateMin;
}

string AnalyzeSymbol(const string symbol, const datetime from, const int lateMin)
{
   SymbolSelect(symbol, true);
   int    idx[];
   double lot;
   string side;
   SymbolPositions(symbol, idx, lot, side);
   int want = MP_WantFor(symbol, side);
   string head = "{\"symbol\":" + MP_JsonStr(symbol);
   if(want == 0)
      return head + ",\"error\":" + MP_JsonStr(MP_Fr("sens du robot inconnu : pas de r{e`}gle")) + "}";

   MqlRates r1[], r5[], r30[], r60[];
   if(!LoadRates(symbol, PERIOD_M1, from - 2 * 86400, r1, 2 * MP_JUMP_MEDIAN_BARS)
      || !LoadRates(symbol, PERIOD_M5, from - MP_RULE_BARS * 300, r5, MP_RULE_BARS)
      || !LoadRates(symbol, PERIOD_M30, from - MP_RULE_BARS * 1800, r30, MP_RULE_BARS)
      || !LoadRates(symbol, PERIOD_H1, from - MP_RULE_BARS * 3600, r60, MP_RULE_BARS))
      return head + ",\"error\":" + MP_JsonStr("historique des bougies indisponible") + "}";

   int s5[], s30[], s60[];
   double ef[], atr[];
   MP_RuleTrend(r5, s5, ef, atr);
   MP_RuleTrend(r30, s30, ef, atr);
   MP_RuleTrend(r60, s60, ef, atr);
   int auth[], counter[];
   int n5 = MP_RuleSeries(r5, r30, r60, s5, s30, s60, want, auth, counter);

   bool jump[];
   int  lastJ[], nextJ[];
   MP_JumpSeries(r1, want, jump);
   JumpIndex(jump, lastJ, nextJ);

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double perPoint  = (tickSize > 0.0) ? tickValue / tickSize : 0.0;
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);

   //--- Marche : une entree a chaque cloture M5, jusqu'au saut suivant.
   Tally mk[MP_MODES];
   ZeroMemory(mk);
   int jumps = 0;
   for(int i = 0; i < ArraySize(jump); i++) if(jump[i] && r1[i].time >= from) jumps++;
   for(int i = 0; i < n5; i++)
   {
      datetime t = r5[i].time + 300;
      if(t < from) continue;
      int k = MP_ClosedAt(r1, 60, t);
      if(k < 0 || nextJ[k] < 0) continue;   // saut suivant pas encore venu
      int j = nextJ[k];
      double net = (want < 0) ? r1[k].close - (r1[j].close + r1[j].spread * point)
                              : r1[j].close - (r1[k].close + r1[k].spread * point);
      net *= lot * perPoint;
      bool late = IsLate(r1, lastJ, k, t, lateMin);
      for(int m = 0; m < MP_MODES; m++)
         if(MP_ModeAllows(m, auth[i] == 1, late)) Count(mk[m], net);
   }

   //--- Robot : ses cycles, gardes si le reglage le laissait tourner au debut.
   Tally rb[MP_MODES];
   ZeroMemory(rb);
   int count = ArraySize(idx);
   for(int dir = -1; dir <= 1; dir += 2)
   {
      int k = 0;
      while(k < count)
      {
         if(g_pos[idx[k]].dir != dir) { k++; continue; }
         datetime start = g_pos[idx[k]].tin, end = g_pos[idx[k]].tout;
         double net = 0.0;
         int first = k;
         for(int q = k; q < count; q++)
         {
            if(g_pos[idx[q]].dir != dir) continue;
            if(g_pos[idx[q]].tin >= end && q != first) break;
            net += g_pos[idx[q]].net;
            if(g_pos[idx[q]].tout > end) end = g_pos[idx[q]].tout;
            k = q + 1;
         }
         int i0 = MP_ClosedAt(r5, 300, start);
         if(i0 < 0 || i0 >= n5) continue;
         int k1 = MP_ClosedAt(r1, 60, start);
         bool late = IsLate(r1, lastJ, k1, start, lateMin);
         for(int m = 0; m < MP_MODES; m++)
            if(MP_ModeAllows(m, auth[i0] == 1, late)) Count(rb[m], net);
      }
   }

   bool byRobot = rb[MP_MODE_NONE].n >= LECTEUR_MIN_CYCLES;
   int  best    = byRobot ? Best(rb) : Best(mk);
   return head + ",\"want\":" + MP_JsonStr(want > 0 ? "buy" : "sell")
        + ",\"lot\":" + MP_JsonNum(lot, 2)
        + ",\"jumps\":" + IntegerToString(jumps)
        + ",\"market\":" + TallyJson(mk)
        + ",\"robot\":" + TallyJson(rb)
        + ",\"best\":" + MP_JsonStr(MP_ModeName(best))
        + ",\"best_by\":" + MP_JsonStr(byRobot ? "robot" : "market") + "}";
}

//+------------------------------------------------------------------+
//| Demande                                                          |
//+------------------------------------------------------------------+
void Compare(const long account, const string dir, const string content)
{
   string id = MP_Sanitize(MP_JsonText(content, "request_id"), 64, true);
   double v;
   int days    = (MP_JsonNumber(content, "days", v) == 1) ? (int)MathMax(1, MathMin(LECTEUR_DAYS_MAX, v)) : LECTEUR_DAYS;
   int lateMin = (MP_JsonNumber(content, "jump_late_min", v) == 1) ? (int)MathMax(0, v) : 40;
   long magic  = (MP_JsonNumber(content, "magic", v) == 1) ? (long)v : 0;
   string syms[];
   MP_JsonStrings(content, "symbols", syms);
   PrintFormat("MerePoule Lecteur : comparatif sur %d jours, %d symbole(s)", days, ArraySize(syms));

   ulong    began = GetTickCount64();
   datetime from  = TimeCurrent() - days * 86400;
   LoadPositions(from, magic);
   string list = "";
   for(int i = 0; i < ArraySize(syms) && !IsStopped(); i++)
      list += (i > 0 ? "," : "") + AnalyzeSymbol(syms[i], from, lateMin);

   string error = (ArraySize(syms) == 0) ? MP_Fr("aucun symbole demand{e'}") : "";
   string s = "{\"v\":1,\"lecteur\":" + MP_JsonStr(LECTEUR_VERSION)
            + ",\"request_id\":" + MP_JsonStrOrNull(id)
            + ",\"ts\":" + MP_JsonStr(MP_IsoTime(TimeGMT()))
            + ",\"account\":" + IntegerToString(account)
            + ",\"days\":" + IntegerToString(days)
            + ",\"jump_late_min\":" + IntegerToString(lateMin)
            + ",\"magic\":" + IntegerToString(magic)
            + ",\"duration_ms\":" + IntegerToString((long)(GetTickCount64() - began))
            + ",\"error\":" + MP_JsonStr(error)
            + ",\"symbols\":[" + list + "]}\n";
   if(!MP_WriteAtomic(dir + MP_LECTEUR_FILE, s))
      PrintFormat("MerePoule Lecteur : %s non ecrit, err=%d", MP_LECTEUR_FILE, GetLastError());
   else
      PrintFormat("MerePoule Lecteur : comparatif ecrit en %I64u ms", GetTickCount64() - began);
}

void OnStart()
{
   Print("MerePoule Lecteur ", LECTEUR_VERSION, " : en attente des demandes de comparatif (lecture seule)");
   while(!IsStopped())
   {
      long account = AccountInfoInteger(ACCOUNT_LOGIN);
      if(account > 0 && TerminalInfoInteger(TERMINAL_CONNECTED))
      {
         string dir = MP_Dir(account), content;
         if(MP_TakeFlag(dir + MP_COMPARE_FLAG, content)) Compare(account, dir, content);
      }
      Sleep(LECTEUR_POLL_MS);
   }
}
