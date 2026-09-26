//+------------------------------------------------------------------+
//| Shield.mqh                                                       |
//| Bouclier suiveur (architecture, decisions 15 et 17).             |
//|                                                                  |
//| Pose un stop loss cote courtier sur les positions qui n'en ont   |
//| pas : la seule protection quand la machine de trading tombe.     |
//|  - groupes par symbole et par sens, part egale du budget         |
//|  - tous les SL d'un groupe au meme prix : celui ou le groupe     |
//|    perdrait sa part EN PLUS de sa perte actuelle                 |
//|  - suiveur : recalcule a chaque ouverture ou fermeture, et       |
//|    chaque minute, dans les deux sens, tant que le Watchdog       |
//|    tourne. En marche normale il ne coupe donc pas une grille :   |
//|    ce sont les regles du Watchdog qui protegent. Si la machine   |
//|    tombe, les SL restent ou ils etaient : chaque groupe perd au  |
//|    plus sa part en plus                                          |
//|  - un SL pose par le robot n'est jamais touche : le Bouclier ne  |
//|    gere que les positions sans SL et celles dont il a pose le SL |
//|    (retenues dans les variables globales "<prefixe>sh.<ticket>") |
//|  - Bouclier desactive : il retire les SL qu'il a poses           |
//|  - position fermee par un de ses SL : signalee, avec le resultat |
//|    (y compris pendant un arret de la machine, vue au demarrage)  |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_SHIELD_MQH
#define MEREPOULE_SHIELD_MQH

#include <Trade\Trade.mqh>
#include "Json.mqh"

#define MP_SHIELD_TRAIL_SEC 60   // recalcul periodique
#define MP_SHIELD_RETRY_SEC 60   // apres un refus du courtier

class CShield
{
private:
   CTrade   m_trade;
   string   m_gv;          // prefixe des variables globales du Bouclier
   long     m_magic;       // 0 = toutes les positions
   string   m_signature;   // positions gerees et budget au dernier calcul
   datetime m_lastTrail;   // dernier recalcul
   datetime m_retryAt;     // apres un refus, nouvel essai a cette heure
   string   m_warned;      // cles deja signalees, "|cle|"
   bool     m_active;
   double   m_budget;
   int      m_groups;
   int      m_protected;
   int      m_unprotected;

   bool Monitored(const long magic) const { return m_magic == 0 || magic == m_magic; }

   string TicketVar(const ulong ticket) const { return m_gv + IntegerToString((long)ticket); }

   //--- SL pose par le Bouclier (et non par le robot) ?
   bool Ours(const ulong ticket, const string symbol, const double sl) const
   {
      string name = TicketVar(ticket);
      if(!GlobalVariableCheck(name)) return false;
      return MathAbs(GlobalVariableGet(name) - sl) <= SymbolInfoDouble(symbol, SYMBOL_POINT) / 2.0;
   }

   //--- Gain ou perte, en devise du compte, pour un deplacement de 1.0 du prix.
   double ValuePerPrice(const string symbol, const bool buy, const double volume, const double open) const
   {
      double delta  = MathMax(open * 0.01, 1000.0 * SymbolInfoDouble(symbol, SYMBOL_POINT));
      double profit = 0.0;
      if(delta <= 0.0) return 0.0;
      if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, symbol, volume, open,
                          buy ? open + delta : open - delta, profit)) return 0.0;
      return MathAbs(profit) / delta;
   }

   //--- Alerte une seule fois par cle, jusqu'a ce que le probleme disparaisse.
   void Warn(const string key, const string text, string &alerts)
   {
      if(StringFind(m_warned, "|" + key + "|") >= 0) return;
      m_warned += "|" + key + "|";
      alerts   += text + " ";
   }

   void Clear(const string key) { StringReplace(m_warned, "|" + key + "|", ""); }

   //--- Positions protegees disparues : fermees par un stop loss du Bouclier ?
   //--- L'historique de chaque position est lu avant d'oublier sa variable ;
   //--- s'il n'est pas encore la, nouvel essai, au plus 10 minutes.
   //--- hits : resume par groupe ; result : resultat net ; count : positions.
   void CheckClosed(string &hits, double &result, int &count)
   {
      string keys[];
      int    n[];
      double res[];
      for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
      {
         string name = GlobalVariableName(i);
         if(StringFind(name, m_gv) != 0) continue;
         string rest = StringSubstr(name, StringLen(m_gv));
         if(StringFind(rest, "x.") == 0) continue;   // marque "historique manquant"
         ulong ticket = (ulong)StringToInteger(rest);
         if(PositionSelectByTicket(ticket)) continue;

         double ours   = GlobalVariableGet(name);
         bool   closed = false, bySL = false, buy = false;
         string symbol = "";
         double net    = 0.0;
         if(HistorySelectByPosition(ticket))
            for(int d = 0; d < HistoryDealsTotal(); d++)
            {
               ulong deal  = HistoryDealGetTicket(d);
               long  entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
               net += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
               if(entry == DEAL_ENTRY_IN) buy = HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_BUY;
               if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
               closed = true;
               symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
               //--- Stop loss, et le notre : un SL remis par le robot entre-temps ne compte pas.
               double dsl = HistoryDealGetDouble(deal, DEAL_SL);
               bySL = HistoryDealGetInteger(deal, DEAL_REASON) == DEAL_REASON_SL
                   && (dsl == 0.0 || MathAbs(dsl - ours) <= SymbolInfoDouble(symbol, SYMBOL_POINT) / 2.0);
            }

         string miss = m_gv + "x." + IntegerToString((long)ticket);
         if(!closed)
         {
            if(!GlobalVariableCheck(miss)) GlobalVariableSet(miss, (double)TimeLocal());
            if(TimeLocal() - (datetime)GlobalVariableGet(miss) < 600) continue;
         }
         GlobalVariableDel(name);
         GlobalVariableDel(miss);
         if(!bySL) continue;

         string key = symbol + (buy ? " achats" : " ventes");
         int k = -1;
         for(int j = 0; j < ArraySize(keys); j++)
            if(keys[j] == key) { k = j; break; }
         if(k < 0)
         {
            k = ArraySize(keys);
            ArrayResize(keys, k + 1);
            ArrayResize(n, k + 1);
            ArrayResize(res, k + 1);
            keys[k] = key;
            n[k]    = 0;
            res[k]  = 0.0;
         }
         n[k]++;
         res[k] += net;
         count++;
         result += net;
      }
      for(int k = 0; k < ArraySize(keys); k++)
         hits += StringFormat("%s%s : %d position(s), %.2f", hits == "" ? "" : "\n", keys[k], n[k], res[k]);
   }

   //--- Bouclier desactive : retire les SL qu'il a poses.
   int RemoveAll(string &alerts)
   {
      int removed = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !Monitored(PositionGetInteger(POSITION_MAGIC))) continue;
         string symbol = PositionGetString(POSITION_SYMBOL);
         double sl     = PositionGetDouble(POSITION_SL);
         if(sl == 0.0 || !Ours(t, symbol, sl)) continue;
         string key = "r" + IntegerToString((long)t);
         if(m_trade.PositionModify(t, 0.0, PositionGetDouble(POSITION_TP)) && m_trade.ResultRetcode() == TRADE_RETCODE_DONE)
         {
            GlobalVariableDel(TicketVar(t));
            removed++;
            Clear(key);
         }
         else if(m_trade.ResultRetcode() == TRADE_RETCODE_POSITION_CLOSED) Clear(key);   // deja fermee
         else Warn(key, StringFormat("stop de s{e'}curit{e'} non retir{e'} pour %s #%I64u (%u %s).", symbol, t,
                                     m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription()), alerts);
      }
      return removed;
   }

public:
   CShield() : m_gv(""), m_magic(0), m_signature(""), m_lastTrail(0), m_retryAt(0), m_warned(""),
               m_active(false), m_budget(0.0), m_groups(0), m_protected(0), m_unprotected(0) {}

   void Init(const string gvPrefix, const long magic)
   {
      m_gv        = gvPrefix + "sh.";
      m_magic     = magic;
      m_signature = "";
      m_lastTrail = 0;
      m_retryAt   = 0;
      m_warned    = "";
      m_trade.SetAsyncMode(false);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
   }

   //--- A appeler chaque seconde hors KILL. budget <= 0 : Bouclier inactif,
   //--- ses SL sont retires. alerts : texte des nouvelles alertes ; placed,
   //--- moved, removed : SL poses, deplaces, retires ; hits, hitResult,
   //--- hitCount : positions fermees par un stop loss du Bouclier.
   void Update(const double budget, string &alerts, int &placed, int &moved, int &removed,
               string &hits, double &hitResult, int &hitCount)
   {
      alerts    = "";
      placed    = 0;
      moved     = 0;
      removed   = 0;
      hits      = "";
      hitResult = 0.0;
      hitCount  = 0;
      m_active = budget > 0.0;
      m_budget = MathMax(0.0, budget);

      if(!m_active)
      {
         removed       = RemoveAll(alerts);
         m_signature   = "";
         m_groups      = 0;
         m_protected   = 0;
         m_unprotected = 0;
         return;
      }

      //--- 1. Positions gerees : surveillees, sans SL ou avec un SL du Bouclier.
      ulong tickets[];
      string sig = "";
      m_protected   = 0;
      m_unprotected = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !Monitored(PositionGetInteger(POSITION_MAGIC))) continue;
         double sl = PositionGetDouble(POSITION_SL);
         if(sl != 0.0 && !Ours(t, PositionGetString(POSITION_SYMBOL), sl)) continue;   // SL du robot
         int n = ArraySize(tickets);
         ArrayResize(tickets, n + 1);
         tickets[n] = t;
         sig += IntegerToString((long)t) + ",";
         if(sl == 0.0) m_unprotected++;
         else          m_protected++;
      }
      sig += "|" + DoubleToString(m_budget, 2);

      bool due = sig != m_signature
              || TimeLocal() - m_lastTrail >= MP_SHIELD_TRAIL_SEC
              || (m_retryAt > 0 && TimeLocal() >= m_retryAt);
      if(!due) return;
      m_signature = sig;
      m_lastTrail = TimeLocal();
      m_retryAt   = 0;

      //--- 2. Groupes par symbole et par sens : valeur au prix cumulee.
      string gSymbol[];
      bool   gBuy[];
      double gV[];
      int    tGroup[];
      int    count = ArraySize(tickets);
      ArrayResize(tGroup, count);
      for(int k = 0; k < count; k++)
      {
         tGroup[k] = -1;
         if(!PositionSelectByTicket(tickets[k])) continue;
         string symbol = PositionGetString(POSITION_SYMBOL);
         bool   buy    = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
         double v      = ValuePerPrice(symbol, buy, PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN));
         if(v <= 0.0)
         {
            Warn("v" + symbol, StringFormat("stop de s{e'}curit{e'} impossible {a`} calculer pour %s (valeur du point inconnue).", symbol), alerts);
            continue;
         }
         int g = -1;
         for(int j = 0; j < ArraySize(gSymbol); j++)
            if(gSymbol[j] == symbol && gBuy[j] == buy) { g = j; break; }
         if(g < 0)
         {
            g = ArraySize(gSymbol);
            ArrayResize(gSymbol, g + 1);
            ArrayResize(gBuy, g + 1);
            ArrayResize(gV, g + 1);
            gSymbol[g] = symbol;
            gBuy[g]    = buy;
            gV[g]      = 0.0;
         }
         gV[g]    += v;
         tGroup[k] = g;
      }
      m_groups = ArraySize(gSymbol);
      if(m_groups == 0) { CheckClosed(hits, hitResult, hitCount); return; }

      //--- 3. Prix du SL de chaque groupe : a sa part du budget du prix
      //--- actuel, jamais plus pres que la distance minimale du courtier.
      double share = m_budget / m_groups;
      double level[], tolerance[];
      bool   ok[];
      ArrayResize(level, m_groups);
      ArrayResize(tolerance, m_groups);
      ArrayResize(ok, m_groups);
      for(int g = 0; g < m_groups; g++)
      {
         string symbol = gSymbol[g];
         double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
         double gap    = (double)MathMax(SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                         SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * point;
         double price  = gBuy[g] ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
         double dist   = MathMax(share / gV[g], gap + point);

         level[g]     = NormalizeDouble(gBuy[g] ? price - dist : price + dist, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
         tolerance[g] = MathMax(10.0 * point, 0.05 * dist);   // pas de modification pour un ecart negligeable
         ok[g]        = price > 0.0 && level[g] > 0.0;        // achat : sous zero, rien a proteger
      }

      //--- 4. Pose, ou deplace si l'ecart compte.
      for(int k = 0; k < count; k++)
      {
         int g = tGroup[k];
         if(g < 0 || !ok[g] || !PositionSelectByTicket(tickets[k])) continue;
         double cur = PositionGetDouble(POSITION_SL);
         if(cur != 0.0 && MathAbs(level[g] - cur) <= tolerance[g]) continue;

         string key = "t" + IntegerToString((long)tickets[k]);
         if(m_trade.PositionModify(tickets[k], level[g], PositionGetDouble(POSITION_TP))
            && m_trade.ResultRetcode() == TRADE_RETCODE_DONE
            && PositionSelectByTicket(tickets[k]))
         {
            GlobalVariableSet(TicketVar(tickets[k]), PositionGetDouble(POSITION_SL));
            if(cur == 0.0) { placed++; m_unprotected--; m_protected++; }
            else moved++;
            Clear(key);
         }
         else if(m_trade.ResultRetcode() == TRADE_RETCODE_POSITION_CLOSED || !PositionSelectByTicket(tickets[k]))
         {
            //--- fermee par le robot entre la lecture et la modification : plus rien a proteger
            if(cur == 0.0) m_unprotected--;
            else           m_protected--;
            Clear(key);
         }
         else
         {
            Warn(key, StringFormat("le courtier a refus{e'} le stop de s{e'}curit{e'} de %s #%I64u (%u %s) ; nouvel essai dans une minute.", gSymbol[g], tickets[k],
                                   m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription()), alerts);
            m_retryAt = TimeLocal() + MP_SHIELD_RETRY_SEC;
         }
      }
      CheckClosed(hits, hitResult, hitCount);
   }

   double Budget() const      { return m_budget; }
   bool   Active() const      { return m_active; }
   int    Protected() const   { return m_protected; }
   int    Unprotected() const { return m_unprotected; }
   int    Groups() const { return m_groups; }

   string Json() const
   {
      return "{\"active\":" + MP_JsonBool(m_active)
           + ",\"budget\":" + MP_JsonNum(m_budget, 2)
           + ",\"groups\":" + IntegerToString(m_groups)
           + ",\"protected\":" + IntegerToString(m_protected)
           + ",\"unprotected\":" + IntegerToString(m_unprotected) + "}";
   }
};

#endif // MEREPOULE_SHIELD_MQH
