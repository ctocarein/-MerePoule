//+------------------------------------------------------------------+
//| Chameleon.mqh                                                    |
//| Cameleon (decision 21) : avant l'arret, repere un groupe de      |
//| positions (symbole et sens) a contre-tendance - achats sur un    |
//| marche en baisse, ventes sur un marche en hausse - qui perd plus |
//| qu'une part du seuil de perte flottante (raison "trend"). Depuis |
//| la 1.28, aussi un groupe qui perd lourd, quelle que soit la      |
//| tendance (raison "heavy") : le 25/09 a 12:24, un groupe a perdu  |
//| -304 sur une tendance jugee neutre.                              |
//|                                                                  |
//| En observation, il ne ferme rien. Il note ce qu'une coupe aurait |
//| realise (le resultat du groupe a ce moment), puis, quand toutes  |
//| les positions de ce moment sont fermees (par le robot ou par     |
//| l'arret), compare avec ce qui s'est vraiment passe : les         |
//| fermetures du groupe depuis. Le bilan cumule dira s'il faut      |
//| l'activer.                                                       |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_CHAMELEON_MQH
#define MEREPOULE_CHAMELEON_MQH

#include "Json.mqh"
#include "Market.mqh"

struct MP_Episode
{
   string   symbol;
   bool     buy;
   datetime at;         // declenchement, heure serveur (historique des transactions)
   datetime atGmt;      // le meme, en GMT (messages et statut)
   double   cut;        // resultat du groupe a ce moment : ce qu'une coupe aurait realise
   int      positions;
   double   volume;
   string   trend;
   double   chg4h;
   string   mood;
   string   tickets;    // positions ouvertes a ce moment, separees par des virgules
   string   reason;     // trend : a contre-tendance ; heavy : perte lourde
   // bilan
   double   actual;     // fermetures du groupe depuis le declenchement
   datetime closedGmt;
};

class CChameleon
{
private:
   MP_Episode m_open[];
   string     m_file;    // "MerePoule\<compte>\chameleon.txt" sous MQL5\Files
   string     m_gv;      // prefixe des variables globales du bilan cumule
   long       m_magic;

   bool Monitored(const long magic) const { return m_magic == 0 || magic == m_magic; }

   int Find(const string symbol, const bool buy, const string reason) const
   {
      for(int i = 0; i < ArraySize(m_open); i++)
         if(m_open[i].symbol == symbol && m_open[i].buy == buy && m_open[i].reason == reason) return i;
      return -1;
   }

   void Save() const
   {
      if(ArraySize(m_open) == 0) { FileDelete(m_file); return; }
      int h = FileOpen(m_file, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE) { PrintFormat("MerePoule: %s non ecrit, err=%d", m_file, GetLastError()); return; }
      for(int i = 0; i < ArraySize(m_open); i++)
      {
         MP_Episode e = m_open[i];
         FileWriteString(h, StringFormat("%s;%s;%I64d;%I64d;%.2f;%d;%.2f;%s;%.2f;%s;%s;%s\r\n",
                                         e.symbol, e.buy ? "b" : "s", (long)e.at, (long)e.atGmt, e.cut, e.positions,
                                         e.volume, e.trend, e.chg4h, e.mood, e.tickets, e.reason));
      }
      FileClose(h);
   }

   void Load()
   {
      ArrayResize(m_open, 0);
      int h = FileOpen(m_file, FILE_READ | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE) return;
      while(!FileIsEnding(h))
      {
         string l = FileReadString(h);
         StringTrimRight(l);
         string p[];
         int fields = StringSplit(l, ';', p);
         if(fields < 11) continue;
         MP_Episode e;
         e.symbol    = p[0];
         e.buy       = p[1] == "b";
         e.at        = (datetime)StringToInteger(p[2]);
         e.atGmt     = (datetime)StringToInteger(p[3]);
         e.cut       = StringToDouble(p[4]);
         e.positions = (int)StringToInteger(p[5]);
         e.volume    = StringToDouble(p[6]);
         e.trend     = p[7];
         e.chg4h     = StringToDouble(p[8]);
         e.mood      = p[9];
         e.tickets   = p[10];
         e.reason    = (fields > 11) ? p[11] : "trend";   // cas ouverts par la 1.26
         e.actual    = 0.0;
         e.closedGmt = 0;
         int n = ArraySize(m_open);
         ArrayResize(m_open, n + 1);
         m_open[n] = e;
      }
      FileClose(h);
   }

   bool AnyOpen(const string tickets) const
   {
      string t[];
      int n = StringSplit(tickets, ',', t);
      for(int i = 0; i < n; i++)
         if(t[i] != "" && PositionSelectByTicket((ulong)StringToInteger(t[i]))) return true;
      return false;
   }

   //--- Fermetures des positions du groupe depuis le declenchement : ce
   //--- qu'a donne le groupe sans coupe, positions ajoutees depuis comprises.
   double ClosedSince(const MP_Episode &e) const
   {
      ulong  ids[];
      double net[];
      if(!HistorySelect(e.at, TimeCurrent() + 3600)) return 0.0;
      for(int d = 0; d < HistoryDealsTotal(); d++)
      {
         ulong deal  = HistoryDealGetTicket(d);
         long  entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != e.symbol) continue;
         //--- La sortie d'un achat est une vente, et inversement.
         bool closesBuy = HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_SELL;
         if(closesBuy != e.buy) continue;
         int n = ArraySize(ids);
         ArrayResize(ids, n + 1);
         ArrayResize(net, n + 1);
         ids[n] = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
         net[n] = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
                + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      }
      double total = 0.0;
      for(int i = 0; i < ArraySize(ids); i++)
      {
         //--- Magic filtre : la sortie peut venir du Watchdog (arret), c'est
         //--- l'entree de la position qui dit si elle etait au robot.
         if(m_magic != 0 && HistorySelectByPosition(ids[i]))
         {
            bool ours = false;
            for(int d = 0; d < HistoryDealsTotal(); d++)
            {
               ulong deal = HistoryDealGetTicket(d);
               if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
                  ours = Monitored(HistoryDealGetInteger(deal, DEAL_MAGIC));
            }
            if(!ours) continue;
         }
         total += net[i];
      }
      return total;
   }

public:
   CChameleon() : m_file(""), m_gv(""), m_magic(0) {}

   void Init(const string gvPrefix, const long account, const long magic)
   {
      m_gv    = gvPrefix + "cham.";
      m_magic = magic;
      m_file  = "MerePoule\\" + IntegerToString(account) + "\\chameleon.txt";
      Load();
   }

   //--- Nouveaux cas : groupe a contre-tendance au-dela de threshold, ou
   //--- groupe au-dela de heavy quelle que soit la tendance. 0 : raison inactive.
   int Detect(const CMarket &market, const double threshold, const double heavy, MP_Episode &fresh[])
   {
      ArrayResize(fresh, 0);
      if(threshold <= 0.0 && heavy <= 0.0) return 0;
      string keys[];
      bool   buys[];
      int    count[];
      double vol[], res[];
      string tix[];
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !Monitored(PositionGetInteger(POSITION_MAGIC))) continue;
         string sym = PositionGetString(POSITION_SYMBOL);
         bool   buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
         int k = -1;
         for(int j = 0; j < ArraySize(keys); j++)
            if(keys[j] == sym && buys[j] == buy) { k = j; break; }
         if(k < 0)
         {
            k = ArraySize(keys);
            ArrayResize(keys, k + 1);
            ArrayResize(buys, k + 1);
            ArrayResize(count, k + 1);
            ArrayResize(vol, k + 1);
            ArrayResize(res, k + 1);
            ArrayResize(tix, k + 1);
            keys[k] = sym;
            buys[k] = buy;
            count[k] = 0;
            vol[k] = 0.0;
            res[k] = 0.0;
            tix[k] = "";
         }
         count[k]++;
         vol[k] += PositionGetDouble(POSITION_VOLUME);
         res[k] += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         tix[k] += (tix[k] == "" ? "" : ",") + IntegerToString((long)t);
      }

      bool changed = false;
      for(int k = 0; k < ArraySize(keys); k++)
      {
         MP_Market m;
         bool   known   = market.Get(keys[k], m);
         bool   against = known && ((buys[k] && m.trend == "baisse") || (!buys[k] && m.trend == "hausse"));
         //--- Contre-tendance et perte lourde : un seul cas ouvert par groupe.
         //--- Retournement (1.32) : bougie M5 forte contre le sens voulu, cas a part.
         bool   open    = Find(keys[k], buys[k], "trend") >= 0 || Find(keys[k], buys[k], "heavy") >= 0;
         string reason  = "";
         if(!open && threshold > 0.0 && against && res[k] <= -threshold) reason = "trend";
         else if(!open && heavy > 0.0 && res[k] <= -heavy)          reason = "heavy";
         else if(known && m.reversal && m.want == (buys[k] ? 1 : -1) && Find(keys[k], buys[k], "reversal") < 0) reason = "reversal";
         if(reason == "") continue;
         if(!known)
         {
            m.trend = "inconnue";
            m.chg4h = 0.0;
            m.mood  = "inconnu";
         }

         MP_Episode e;
         e.symbol    = keys[k];
         e.buy       = buys[k];
         e.at        = TimeCurrent();
         e.atGmt     = TimeGMT();
         e.cut       = res[k];
         e.positions = count[k];
         e.volume    = vol[k];
         e.trend     = m.trend;
         e.chg4h     = m.chg4h;
         e.mood      = m.mood;
         e.tickets   = tix[k];
         e.reason    = reason;
         e.actual    = 0.0;
         e.closedGmt = 0;
         int n = ArraySize(m_open);
         ArrayResize(m_open, n + 1);
         m_open[n] = e;
         n = ArraySize(fresh);
         ArrayResize(fresh, n + 1);
         fresh[n] = e;
         changed = true;
      }
      if(changed) Save();
      return ArraySize(fresh);
   }

   //--- Groupes dont toutes les positions du declenchement sont fermees :
   //--- bilan, et cumul dans les variables globales du terminal.
   int Settle(MP_Episode &done[])
   {
      ArrayResize(done, 0);
      MP_Episode keep[];
      for(int i = 0; i < ArraySize(m_open); i++)
      {
         MP_Episode e = m_open[i];
         if(AnyOpen(e.tickets))
         {
            int n = ArraySize(keep);
            ArrayResize(keep, n + 1);
            keep[n] = e;
            continue;
         }
         e.actual    = ClosedSince(e);
         e.closedGmt = TimeGMT();
         GlobalVariableSet(m_gv + "n", Episodes() + 1);
         GlobalVariableSet(m_gv + "saved", SavedTotal() + (e.cut - e.actual));
         if(e.reason == "heavy" || e.reason == "reversal")
         {
            GlobalVariableSet(m_gv + "n." + e.reason, Episodes(e.reason) + 1);
            GlobalVariableSet(m_gv + "saved." + e.reason, SavedTotal(e.reason) + (e.cut - e.actual));
         }
         int n = ArraySize(done);
         ArrayResize(done, n + 1);
         done[n] = e;
      }
      if(ArraySize(done) == 0) return 0;
      ArrayResize(m_open, ArraySize(keep));
      for(int i = 0; i < ArraySize(keep); i++) m_open[i] = keep[i];
      Save();
      return ArraySize(done);
   }

   int    Open() const { return ArraySize(m_open); }

   double Gv(const string name) const { return GlobalVariableCheck(m_gv + name) ? GlobalVariableGet(m_gv + name) : 0.0; }

   //--- Cas soldes : reason "" = tous, "heavy" = perte lourde, "reversal" =
   //--- retournement, "trend" = le reste (compte d'avant la 1.28).
   int Episodes(const string reason = "") const
   {
      if(reason == "heavy" || reason == "reversal") return (int)Gv("n." + reason);
      if(reason == "trend") return (int)(Gv("n") - Gv("n.heavy") - Gv("n.reversal"));
      return (int)Gv("n");
   }

   //--- Somme de (coupe - reel) : positif, la coupe aurait epargne de l'argent.
   double SavedTotal(const string reason = "") const
   {
      if(reason == "heavy" || reason == "reversal") return Gv("saved." + reason);
      if(reason == "trend") return Gv("saved") - Gv("saved.heavy") - Gv("saved.reversal");
      return Gv("saved");
   }

   string Json(const double pct, const double threshold, const double heavyPct, const double heavy) const
   {
      string s = "{\"mode\":\"observe\",\"pct\":" + MP_JsonNum(pct, 1)
               + ",\"threshold\":" + MP_JsonNum(threshold, 2)
               + ",\"heavy_pct\":" + MP_JsonNum(heavyPct, 1)
               + ",\"heavy_threshold\":" + MP_JsonNum(heavy, 2) + ",\"open\":[";
      for(int i = 0; i < ArraySize(m_open); i++)
      {
         if(i > 0) s += ",";
         s += "{\"symbol\":" + MP_JsonStr(m_open[i].symbol)
            + ",\"side\":" + MP_JsonStr(m_open[i].buy ? "buy" : "sell")
            + ",\"since\":" + MP_JsonStr(MP_IsoTime(m_open[i].atGmt))
            + ",\"cut_result\":" + MP_JsonNum(m_open[i].cut, 2)
            + ",\"positions\":" + IntegerToString(m_open[i].positions)
            + ",\"reason\":" + MP_JsonStr(m_open[i].reason) + "}";
      }
      return s + "],\"episodes\":" + IntegerToString(Episodes())
               + ",\"saved_total\":" + MP_JsonNum(SavedTotal(), 2)
               + ",\"by_reason\":{\"trend\":{\"episodes\":" + IntegerToString(Episodes("trend"))
               + ",\"saved_total\":" + MP_JsonNum(SavedTotal("trend"), 2) + "}"
               + ",\"heavy\":{\"episodes\":" + IntegerToString(Episodes("heavy"))
               + ",\"saved_total\":" + MP_JsonNum(SavedTotal("heavy"), 2) + "}"
               + ",\"reversal\":{\"episodes\":" + IntegerToString(Episodes("reversal"))
               + ",\"saved_total\":" + MP_JsonNum(SavedTotal("reversal"), 2) + "}}}";
   }
};

#endif // MEREPOULE_CHAMELEON_MQH
