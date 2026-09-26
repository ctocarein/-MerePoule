//+------------------------------------------------------------------+
//| NewsWatch.mqh                                                    |
//| Regle "annonce majeure" : calendrier economique MT5, importance  |
//| haute, pour les devises listees. Liste vide = regle desactivee   |
//| (indices synthetiques 24/7, decision 2 du 24/09/2026).          |
//|                                                                  |
//| Une annonce est "en cours" si son heure tombe dans               |
//| [maintenant - apres, maintenant + avant]. Le calendrier est      |
//| interroge au plus une fois par minute ; les heures sont celles   |
//| du serveur de trading.                                           |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_NEWSWATCH_MQH
#define MEREPOULE_NEWSWATCH_MQH

class CNewsWatch
{
private:
   string   m_currencies[];
   int      m_beforeSec;
   int      m_afterSec;
   bool     m_active;
   string   m_label;
   datetime m_lastRefresh;

public:
   CNewsWatch() : m_beforeSec(0), m_afterSec(0), m_active(false), m_label(""), m_lastRefresh(0) {}

   //--- currencies : "USD;EUR"
   void Init(const string currencies, const int beforeMin, const int afterMin)
   {
      ArrayResize(m_currencies, 0);
      string parts[];
      int n = StringSplit(currencies, ';', parts);
      for(int i = 0; i < n; i++)
      {
         string c = parts[i];
         StringTrimLeft(c);
         StringTrimRight(c);
         StringToUpper(c);
         if(c == "") continue;
         int k = ArraySize(m_currencies);
         ArrayResize(m_currencies, k + 1);
         m_currencies[k] = c;
      }
      m_beforeSec   = MathMax(0, beforeMin) * 60;
      m_afterSec    = MathMax(0, afterMin) * 60;
      m_active      = false;
      m_label       = "";
      m_lastRefresh = 0;
   }

   bool   Enabled() const { return ArraySize(m_currencies) > 0; }
   bool   Active()  const { return m_active; }
   string Label()   const { return m_label; }
   bool   Due(const datetime now) const { return Enabled() && now - m_lastRefresh >= 60; }

   //--- false si le calendrier ne repond pas : la regle devient alors
   //--- inactive, les autres regles continuent.
   bool Refresh(const datetime now)
   {
      m_lastRefresh = now;
      bool     active  = false;
      string   label   = "";
      datetime nearest = 0;

      for(int c = 0; c < ArraySize(m_currencies); c++)
      {
         MqlCalendarValue values[];
         ResetLastError();
         if(!CalendarValueHistory(values, now - m_afterSec, now + m_beforeSec, NULL, m_currencies[c]))
         {
            if(GetLastError() != 0) { m_active = false; m_label = ""; return false; }
            continue;   // aucune valeur sur la fenetre
         }
         for(int i = 0; i < ArraySize(values); i++)
         {
            MqlCalendarEvent ev;
            if(!CalendarEventById(values[i].event_id, ev)) continue;
            if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
            if(active && MathAbs((long)(values[i].time - now)) >= MathAbs((long)(nearest - now))) continue;
            active  = true;
            nearest = values[i].time;
            label   = m_currencies[c] + " " + ev.name + " " + TimeToString(values[i].time, TIME_MINUTES);
         }
      }
      m_active = active;
      m_label  = label;
      return true;
   }
};

#endif // MEREPOULE_NEWSWATCH_MQH
