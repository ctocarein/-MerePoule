//+------------------------------------------------------------------+
//| MerePouleRegle.mq5                                               |
//| Rejoue sur l'historique la regle AUTORISE / INTERDIT /           |
//| RETOURNEMENT (decision 25) et la confronte aux vrais trades du   |
//| robot. LECTURE SEULE : ce script ne trade pas.                   |
//|                                                                  |
//| Regle, par symbole, dans le sens voulu (PainX : vente, GainX :   |
//| achat) :                                                         |
//|  - AUTORISE : M5 dans le sens voulu ET (M30 OU H1 aussi) ;       |
//|  - INTERDIT sinon (NEUTRE compte comme pas aligne) ;             |
//|  - RETOURNEMENT : bougie M5 fermee, forte (corps > x ATR), contre|
//|    le sens voulu, cloturant au-dela de la moyenne rapide.        |
//| Tendance d'une unite de temps, sur bougies fermees : baisse si   |
//| cloture < EMA lente, EMA rapide < EMA lente et pente de la lente |
//| <= -seuil (en ATR) ; hausse a l'inverse ; NEUTRE sinon.          |
//|                                                                  |
//| Cycles : positions du robot sur un symbole et un sens, qui se    |
//| chevauchent (une grille, du premier achat au retour a plat).     |
//| Pour chaque cycle : etat au moment ou il commence, resultat, et  |
//| resultat d'une coupe au premier RETOURNEMENT.                    |
//|                                                                  |
//| Deux passes : prix bruts, puis prix sans les sauts (un saut plus |
//| grand que x ATR est retire de la serie des moyennes).            |
//|                                                                  |
//| Sorties dans MQL5\Files\MerePoule\<compte>\ : regle.txt (bilan)  |
//| et regle_cycles.csv (un cycle par ligne).                        |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

input int    InpDays        = 30;    // Jours d'historique a rejouer
input long   InpMagic       = 0;     // Magic du robot (0 = toutes les positions)
input int    InpEmaFast     = 20;    // Moyenne rapide (EMA)
input int    InpEmaSlow     = 50;    // Moyenne lente (EMA)
input int    InpSlopeBars   = 5;     // Pente de la lente, sur combien de bougies
input double InpSlopeAtr    = 0.10;  // Pente minimale, en ATR (sinon NEUTRE)
input double InpSpikeAtr    = 4.0;   // Saut : bougie plus grande que x ATR
input int    InpConfirm     = 2;     // Bougies M5 fermees pour changer d'etat
input double InpReversalAtr = 1.5;   // RETOURNEMENT : corps de bougie M5 > x ATR

#define WARMUP_BARS 300

struct Position
{
   ulong    id;
   string   symbol;
   int      dir;      // +1 achat, -1 vente, 0 inconnu, 9 exclu (autre magic)
   datetime tin;
   datetime tout;
   double   price;
   double   volume;
   double   net;
   bool     closed;
};

Position g_pos[];
string   g_report = "";
int      g_csv    = INVALID_HANDLE;
long     g_account = 0;

void Out(const string s)
{
   g_report += s + "\r\n";
   Print(s);
}

string DirText(const int d) { return d > 0 ? "achat" : d < 0 ? "vente" : "?"; }
string StateText(const int s) { return s > 0 ? "hausse" : s < 0 ? "baisse" : "neutre"; }

//--- Sens voulu : PainX a la vente, GainX a l'achat ; sinon le sens le
//--- plus frequent du robot.
int WantedDir(const string symbol, const int robotDir)
{
   if(StringFind(symbol, "PainX") >= 0) return -1;
   if(StringFind(symbol, "GainX") >= 0) return 1;
   return robotDir;
}

int FindPos(const ulong id)
{
   for(int i = ArraySize(g_pos) - 1; i >= 0; i--)
      if(g_pos[i].id == id) return i;
   return -1;
}

//--- Positions fermees du robot depuis from, reconstituees depuis les transactions.
int LoadPositions(const datetime from)
{
   ArrayResize(g_pos, 0);
   if(!HistorySelect(from - 7 * 86400, TimeCurrent() + 86400)) return 0;
   int deals = HistoryDealsTotal();
   for(int d = 0; d < deals; d++)
   {
      ulong t    = HistoryDealGetTicket(d);
      long  type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      ulong id    = (ulong)HistoryDealGetInteger(t, DEAL_POSITION_ID);
      long  entry = HistoryDealGetInteger(t, DEAL_ENTRY);
      int   k     = FindPos(id);
      if(k < 0)
      {
         k = ArraySize(g_pos);
         ArrayResize(g_pos, k + 1);
         g_pos[k].id     = id;
         g_pos[k].symbol = HistoryDealGetString(t, DEAL_SYMBOL);
         g_pos[k].dir    = 0;
         g_pos[k].tin    = 0;
         g_pos[k].tout   = 0;
         g_pos[k].price  = 0.0;
         g_pos[k].volume = 0.0;
         g_pos[k].net    = 0.0;
         g_pos[k].closed = false;
      }
      g_pos[k].net += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
                    + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_FEE);
      datetime when = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      if(entry == DEAL_ENTRY_IN)
      {
         if(InpMagic != 0 && HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagic) { g_pos[k].dir = 9; continue; }
         g_pos[k].dir    = (type == DEAL_TYPE_BUY) ? 1 : -1;
         g_pos[k].tin    = when;
         g_pos[k].price  = HistoryDealGetDouble(t, DEAL_PRICE);
         g_pos[k].volume = HistoryDealGetDouble(t, DEAL_VOLUME);
      }
      else
      {
         g_pos[k].closed = true;
         if(when > g_pos[k].tout) g_pos[k].tout = when;
      }
   }
   //--- Garder les positions entrees dans la periode et refermees.
   int kept = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
   {
      if((g_pos[i].dir != 1 && g_pos[i].dir != -1) || g_pos[i].tin < from || !g_pos[i].closed) continue;
      g_pos[kept++] = g_pos[i];
   }
   ArrayResize(g_pos, kept);
   return kept;
}

bool LoadRates(const string symbol, const ENUM_TIMEFRAMES tf, const datetime from, MqlRates &r[])
{
   datetime start = from - WARMUP_BARS * PeriodSeconds(tf);
   for(int attempt = 0; attempt < 40; attempt++)   // historique a telecharger : jusqu'a 20 s
   {
      int n = CopyRates(symbol, tf, start, TimeCurrent(), r);
      if(n > WARMUP_BARS) return true;
      Sleep(500);
   }
   return false;
}

//--- Tendance bougie par bougie. noJumps : les sauts plus grands que
//--- InpSpikeAtr ATR sont retires de la serie (le prix apres un saut est
//--- ramene au niveau d'avant), pour que les moyennes ne voient que la derive.
//--- adj : cloture dans la serie utilisee ; emaFast, atr : pour le retournement.
void Trend(const MqlRates &r[], const bool noJumps, int &state[], double &adj[], double &emaFast[], double &atr[])
{
   int n = ArraySize(r);
   ArrayResize(state, n);
   ArrayResize(adj, n);
   ArrayResize(emaFast, n);
   ArrayResize(atr, n);
   double emaSlow[];
   ArrayResize(emaSlow, n);
   double kF = 2.0 / (InpEmaFast + 1.0), kS = 2.0 / (InpEmaSlow + 1.0);
   double a = r[0].high - r[0].low, offset = 0.0;
   double ef = r[0].close, es = r[0].close;
   for(int i = 0; i < n; i++)
   {
      double tr = (i == 0) ? r[i].high - r[i].low
                : MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      bool jump = noJumps && i > 20 && InpSpikeAtr > 0.0 && tr > InpSpikeAtr * a;
      if(jump) offset += r[i].close - r[i - 1].close;
      else     a = (i < 14) ? (a * i + tr) / (i + 1) : (a * 13.0 + tr) / 14.0;   // ATR de Wilder, hors sauts
      double c = r[i].close - offset;
      ef += kF * (c - ef);
      es += kS * (c - es);
      adj[i] = c;
      emaFast[i] = ef;
      emaSlow[i] = es;
      atr[i] = a;
      int s = 0;
      if(i >= InpEmaSlow + InpSlopeBars && a > 0.0)
      {
         double slope = (es - emaSlow[i - InpSlopeBars]) / a;
         if(c < es && ef < es && slope <= -InpSlopeAtr)     s = -1;
         else if(c > es && ef > es && slope >= InpSlopeAtr) s = 1;
      }
      state[i] = s;
   }
}

//--- Derniere bougie fermee a l'instant t (bougies chronologiques).
int ClosedAt(const MqlRates &r[], const int seconds, const datetime t)
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

//--- Totaux d'une passe, tous symboles confondus.
double g_allActual, g_allAuth, g_allForb, g_allPolicy;
int    g_allAuthN, g_allForbN;

void AnalyzeSymbol(const string symbol, const datetime from, const bool noJumps)
{
   //--- Positions de ce symbole, par heure d'entree.
   int idx[];
   int robotBuys = 0, robotSells = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
   {
      if(g_pos[i].symbol != symbol) continue;
      int n = ArraySize(idx);
      ArrayResize(idx, n + 1);
      idx[n] = i;
      if(g_pos[i].dir > 0) robotBuys++; else robotSells++;
   }
   for(int a = 1; a < ArraySize(idx); a++)
   {
      int v = idx[a], b = a - 1;
      while(b >= 0 && g_pos[idx[b]].tin > g_pos[v].tin) { idx[b + 1] = idx[b]; b--; }
      idx[b + 1] = v;
   }
   int want = WantedDir(symbol, robotBuys >= robotSells ? 1 : -1);

   SymbolSelect(symbol, true);
   MqlRates r5[], r30[], r60[];
   if(!LoadRates(symbol, PERIOD_M5, from, r5) || !LoadRates(symbol, PERIOD_M30, from, r30) || !LoadRates(symbol, PERIOD_H1, from, r60))
   {
      Out(StringFormat("%s : historique des bougies indisponible, symbole ignore.", symbol));
      return;
   }
   int st5[], st30[], st60[];
   double adj5[], ef5[], atr5[], adj30[], ef30[], atr30[], adj60[], ef60[], atr60[];
   Trend(r5, noJumps, st5, adj5, ef5, atr5);
   Trend(r30, noJumps, st30, adj30, ef30, atr30);
   Trend(r60, noJumps, st60, adj60, ef60, atr60);

   //--- Etat final bougie M5 par bougie M5 (fermees seulement), avec confirmation.
   int n5 = ArraySize(r5) - 1;   // la derniere bougie est en cours
   int auth[];
   bool rev[];
   ArrayResize(auth, n5);
   ArrayResize(rev, n5);
   int finalState = -1, streakState = -1, streak = 0, switches = 0, authBars = 0, periodBars = 0;
   for(int i = 0; i < n5; i++)
   {
      datetime t = r5[i].time + 300;
      int j30 = ClosedAt(r30, 1800, t), j60 = ClosedAt(r60, 3600, t);
      bool ok = st5[i] == want && ((j30 >= 0 && st30[j30] == want) || (j60 >= 0 && st60[j60] == want));
      int raw = ok ? 1 : 0;
      if(raw == streakState) streak++;
      else { streakState = raw; streak = 1; }
      if(finalState < 0) finalState = raw;
      else if(raw != finalState && streak >= InpConfirm)
      {
         finalState = raw;
         if(t >= from) switches++;
      }
      auth[i] = finalState;
      //--- Retournement : bougie forte contre le sens voulu, au-dela de la rapide.
      double body = r5[i].close - r5[i].open;
      double a    = (i > 0) ? atr5[i - 1] : atr5[i];
      rev[i] = (want < 0 && body >=  InpReversalAtr * a && adj5[i] > ef5[i])
            || (want > 0 && body <= -InpReversalAtr * a && adj5[i] < ef5[i]);
      if(t >= from) { periodBars++; if(finalState == 1) authBars++; }
   }

   //--- Cycles : positions du meme sens qui se chevauchent.
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double perPoint  = (tickSize > 0.0) ? tickValue / tickSize : 0.0;
   double sumAuth = 0.0, sumForb = 0.0, sumPolicy = 0.0, worst = 0.0, cutSaved = 0.0;
   int    nAuth = 0, nForb = 0, winAuth = 0, winForb = 0, revHit = 0;
   int    count = ArraySize(idx);
   for(int dir = -1; dir <= 1; dir += 2)
   {
      int k = 0;
      while(k < count)
      {
         if(g_pos[idx[k]].dir != dir) { k++; continue; }
         int first = k;
         datetime start = g_pos[idx[k]].tin, end = g_pos[idx[k]].tout;
         double net = 0.0;
         int members[];
         ArrayResize(members, 0);
         for(int m = k; m < count; m++)
         {
            Position p = g_pos[idx[m]];
            if(p.dir != dir) continue;
            if(p.tin >= end && m != first) break;
            int q = ArraySize(members);
            ArrayResize(members, q + 1);
            members[q] = idx[m];
            net += p.net;
            if(p.tout > end) end = p.tout;
            k = m + 1;
         }
         //--- Etat au debut du cycle, et des trois unites de temps.
         int i0 = ClosedAt(r5, 300, start);
         if(i0 < 0 || i0 >= n5) continue;
         int state = auth[i0];
         int j30 = ClosedAt(r30, 1800, start), j60 = ClosedAt(r60, 3600, start);
         //--- Coupe au premier retournement pendant le cycle.
         datetime revAt = 0;
         double cut = net;
         for(int i = i0 + 1; i < n5 && r5[i].time + 300 < end; i++)
         {
            if(!rev[i]) continue;
            revAt = r5[i].time + 300;
            cut = 0.0;
            for(int q = 0; q < ArraySize(members); q++)
            {
               Position p = g_pos[members[q]];
               if(p.tout <= revAt)     cut += p.net;
               else if(p.tin <= revAt) cut += (r5[i].close - p.price) * p.dir * p.volume * perPoint;
            }
            break;
         }
         if(state == 1)
         {
            nAuth++;
            sumAuth += net;
            if(net > 0.0) winAuth++;
            sumPolicy += cut;
            if(revAt > 0) { revHit++; cutSaved += cut - net; }
         }
         else
         {
            nForb++;
            sumForb += net;
            if(net > 0.0) winForb++;
         }
         if(net < worst) worst = net;
         if(g_csv != INVALID_HANDLE)
            FileWrite(g_csv, noJumps ? "sans sauts" : "brut", symbol, DirText(dir), DirText(want),
                      TimeToString(start, TIME_DATE | TIME_MINUTES), TimeToString(end, TIME_DATE | TIME_MINUTES),
                      ArraySize(members), DoubleToString(net, 2), state == 1 ? "AUTORISE" : "INTERDIT",
                      StateText(st5[i0]), j30 >= 0 ? StateText(st30[j30]) : "?", j60 >= 0 ? StateText(st60[j60]) : "?",
                      revAt > 0 ? TimeToString(revAt, TIME_DATE | TIME_MINUTES) : "", DoubleToString(cut, 2));
      }
   }

   double days = MathMax(1.0, periodBars * 300.0 / 86400.0);
   Out(StringFormat("%s (%s voulu, robot : %d achats, %d ventes)", symbol, DirText(want), robotBuys, robotSells));
   Out(StringFormat("  AUTORISE %.0f %% du temps, %.1f changements d'etat par jour",
                    periodBars > 0 ? 100.0 * authBars / periodBars : 0.0, switches / days));
   Out(StringFormat("  Cycles commences en AUTORISE : %d, resultat %.2f (%d gagnants)", nAuth, sumAuth, winAuth));
   Out(StringFormat("  Cycles commences en INTERDIT : %d, resultat %.2f (%d gagnants)", nForb, sumForb, winForb));
   Out(StringFormat("  Retournement pendant %d cycle(s) AUTORISE : couper au premier aurait change le resultat de %+.2f", revHit, cutSaved));
   Out(StringFormat("  Pire cycle : %.2f", worst));
   g_allActual += sumAuth + sumForb;
   g_allAuth   += sumAuth;
   g_allForb   += sumForb;
   g_allPolicy += sumPolicy;
   g_allAuthN  += nAuth;
   g_allForbN  += nForb;
}

void OnStart()
{
   g_account = AccountInfoInteger(ACCOUNT_LOGIN);
   if(g_account == 0) { Print("MerePoule: aucun compte connecte"); return; }
   datetime from = TimeCurrent() - InpDays * 86400;
   int n = LoadPositions(from);
   if(n == 0) { Print("MerePoule: aucune position fermee du robot sur la periode"); return; }

   string dir = "MerePoule\\" + IntegerToString(g_account) + "\\";
   FolderCreate("MerePoule");
   FolderCreate("MerePoule\\" + IntegerToString(g_account));
   g_csv = FileOpen(dir + "regle_cycles.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
   if(g_csv != INVALID_HANDLE)
      FileWrite(g_csv, "passe", "symbole", "sens", "sens_voulu", "debut", "fin", "positions", "resultat", "etat_debut",
                "m5", "m30", "h1", "retournement", "coupe");

   //--- Symboles traites par le robot sur la periode.
   string syms[];
   for(int i = 0; i < n; i++)
   {
      bool seen = false;
      for(int j = 0; j < ArraySize(syms) && !seen; j++) seen = syms[j] == g_pos[i].symbol;
      if(seen) continue;
      int k = ArraySize(syms);
      ArrayResize(syms, k + 1);
      syms[k] = g_pos[i].symbol;
   }

   Out("MerePoule - regle AUTORISE / INTERDIT / RETOURNEMENT, rejouee sur l'historique");
   Out(StringFormat("Compte %I64d, %d positions fermees du %s au %s", g_account, n,
                    TimeToString(from, TIME_DATE), TimeToString(TimeCurrent(), TIME_DATE)));
   Out(StringFormat("Reglages : EMA %d/%d, pente sur %d bougies >= %.2f ATR, confirmation %d bougies M5, "
                    "retournement %.1f ATR, saut > %.1f ATR", InpEmaFast, InpEmaSlow, InpSlopeBars, InpSlopeAtr,
                    InpConfirm, InpReversalAtr, InpSpikeAtr));
   for(int pass = 0; pass < 2; pass++)
   {
      bool noJumps = pass == 1;
      g_allActual = g_allAuth = g_allForb = g_allPolicy = 0.0;
      g_allAuthN = g_allForbN = 0;
      Out("");
      Out(noJumps ? "=== Passe 2 : prix sans les sauts ===" : "=== Passe 1 : prix bruts ===");
      for(int s = 0; s < ArraySize(syms); s++) AnalyzeSymbol(syms[s], from, noJumps);
      Out("  --- Tous symboles ---");
      Out(StringFormat("  Resultat reel du robot : %.2f (%d cycles)", g_allActual, g_allAuthN + g_allForbN));
      Out(StringFormat("  Cycles AUTORISE : %.2f (%d) ; cycles INTERDIT : %.2f (%d)", g_allAuth, g_allAuthN, g_allForb, g_allForbN));
      Out(StringFormat("  Si la Mere avait bloque les cycles INTERDIT : %.2f", g_allAuth));
      Out(StringFormat("  ... et coupe au premier retournement : %.2f", g_allPolicy));
   }
   Out("");
   Out("Approximation : un cycle bloque aurait decale les suivants ; les coupes sont estimees au prix de cloture M5, spread ignore.");

   if(g_csv != INVALID_HANDLE) FileClose(g_csv);
   int h = FileOpen(dir + "regle.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE) { FileWriteString(h, g_report); FileClose(h); }
   PrintFormat("MerePoule: bilan dans MQL5\\Files\\%sregle.txt et regle_cycles.csv", dir);
   MessageBox("Bilan ecrit dans MQL5\\Files\\" + dir + "regle.txt", "MerePoule - regle", MB_OK);
}
