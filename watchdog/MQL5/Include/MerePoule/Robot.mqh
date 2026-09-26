//+------------------------------------------------------------------+
//| Robot.mqh                                                        |
//| Graphiques du robot surveille : les trouver, les fermer en       |
//| enregistrant leur modele (arret, PAUSE), les rouvrir (RELANCER), |
//| lire et modifier leurs reglages.                                 |
//|                                                                  |
//| Un modele (.tpl, UTF-16 avec BOM) contient l'EA du graphique et  |
//| ses reglages, dans <expert><inputs>nom=valeur</inputs></expert>. |
//|  - arret, PAUSE : MQL5\Profiles\Templates\MerePoule_<compte>_<n> |
//|    et la liste MQL5\Files\MerePoule\<compte>\robot.txt, une      |
//|    ligne "symbole;periode;modele" par graphique                  |
//|  - lecture et modification des reglages : MQL5\Files\MerePoule\  |
//|    <compte>\read.tpl et edit_<n>.tpl. Reappliquer un modele      |
//|    modifie a son graphique redemarre l'EA avec la nouvelle valeur|
//| Fichiers propres au Watchdog, hors contrat.                      |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_ROBOT_MQH
#define MEREPOULE_ROBOT_MQH

#include "Json.mqh"

#define MP_INPUTS_REFRESH_SEC 60

class CRobot
{
private:
   string   m_targets[];
   string   m_list;         // liste des graphiques enregistres
   string   m_prefix;       // nom des modeles d'arret et de pause
   string   m_files;        // "MerePoule\<compte>\" sous MQL5\Files
   datetime m_closedAt;     // ChartClose est asynchrone : un graphique ferme peut rester visible un instant
   long     m_inputIds[];   // graphiques dont les reglages sont connus...
   string   m_inputJson[];  // ...et leurs reglages, en objet JSON
   datetime m_inputsAt;

   void WriteList(const string lines)
   {
      if(lines == "") { FileDelete(m_list); return; }
      int h = FileOpen(m_list, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE) { PrintFormat("MerePoule: %s non ecrit, err=%d", m_list, GetLastError()); return; }
      FileWriteString(h, lines);
      FileClose(h);
   }

   int ReadList(string &lines[]) const
   {
      ArrayResize(lines, 0);
      int h = FileOpen(m_list, FILE_READ | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE) return 0;
      while(!FileIsEnding(h))
      {
         string l = FileReadString(h);
         StringTrimRight(l);
         if(l == "") continue;
         int n = ArraySize(lines);
         ArrayResize(lines, n + 1);
         lines[n] = l;
      }
      FileClose(h);
      return ArraySize(lines);
   }

   //--- Modele d'un graphique, enregistre sous MQL5\Files puis lu en entier.
   bool Snapshot(const long chartId, const string name, string &content) const
   {
      content = "";
      if(!ChartSaveTemplate(chartId, "\\Files\\" + m_files + name)) return false;
      int h = FileOpen(m_files + name + ".tpl", FILE_READ | FILE_BIN);
      if(h == INVALID_HANDLE) return false;
      ushort buf[];
      int got = (int)FileReadArray(h, buf, 0, (int)(FileSize(h) / 2));
      FileClose(h);
      if(got <= 0) return false;
      int start = (buf[0] == 0xFEFF) ? 1 : 0;
      content = ShortArrayToString(buf, start, got - start);
      return true;
   }

   //--- Ecrit un modele comme le terminal : UTF-16, BOM en tete.
   bool WriteTemplate(const string name, const string content) const
   {
      int h = FileOpen(m_files + name + ".tpl", FILE_WRITE | FILE_BIN);
      if(h == INVALID_HANDLE) return false;
      ushort buf[];
      StringToShortArray(content, buf);
      int n = StringLen(content);
      FileWriteInteger(h, 0xFEFF, SHORT_VALUE);
      uint written = FileWriteArray(h, buf, 0, n);
      FileClose(h);
      return (int)written == n;
   }

   //--- Bloc des reglages de l'EA du modele : [from, to[ dans content.
   static bool InputsSpan(const string content, int &from, int &to)
   {
      int e = StringFind(content, "<expert>");
      if(e < 0) return false;
      int end = StringFind(content, "</expert>", e);
      int i   = StringFind(content, "<inputs>", e);
      if(i < 0 || (end >= 0 && i > end)) return false;
      int j = StringFind(content, "</inputs>", i);
      if(j < 0) return false;
      from = i + StringLen("<inputs>");
      to   = j;
      return true;
   }

   //--- {"InpParamL1":"0.2", ...} ; les lignes de titre ("=== GESTION ===") sont ignorees.
   static string InputsJson(const string content)
   {
      int from, to;
      if(!InputsSpan(content, from, to)) return "{}";
      string lines[];
      int n = StringSplit(StringSubstr(content, from, to - from), '\n', lines);
      string s = "{";
      for(int i = 0; i < n; i++)
      {
         string l = lines[i];
         StringTrimRight(l);
         int eq = StringFind(l, "=");
         if(eq <= 0) continue;
         string value = StringSubstr(l, eq + 1);
         int bar = StringFind(value, "||");
         if(bar >= 0) value = StringSubstr(value, 0, bar);
         if(s != "{") s += ",";
         s += MP_JsonStr(StringSubstr(l, 0, eq)) + ":" + MP_JsonStr(value);
      }
      return s + "}";
   }

   void RefreshInputs()
   {
      long ids[];
      int n = Find(ids);
      ArrayResize(m_inputIds, n);
      ArrayResize(m_inputJson, n);
      for(int i = 0; i < n; i++)
      {
         string content;
         m_inputIds[i]  = ids[i];
         m_inputJson[i] = Snapshot(ids[i], "read", content) ? InputsJson(content) : "{}";
      }
      m_inputsAt = TimeLocal();
   }

public:
   CRobot() : m_list(""), m_prefix(""), m_files(""), m_closedAt(0), m_inputsAt(0) {}

   //--- targets : noms exacts des EA, separes par ";"
   void Init(const string targets)
   {
      ArrayResize(m_targets, 0);
      string parts[];
      int n = StringSplit(targets, ';', parts);
      for(int i = 0; i < n; i++)
      {
         string s = parts[i];
         StringTrimLeft(s);
         StringTrimRight(s);
         if(s == "") continue;
         int k = ArraySize(m_targets);
         ArrayResize(m_targets, k + 1);
         m_targets[k] = s;
      }
      ArrayResize(m_inputIds, 0);
      ArrayResize(m_inputJson, 0);
      m_inputsAt = 0;
   }

   void SetAccount(const long account)
   {
      m_list   = "MerePoule\\" + IntegerToString(account) + "\\robot.txt";
      m_prefix = "MerePoule_" + IntegerToString(account) + "_";
      m_files  = "MerePoule\\" + IntegerToString(account) + "\\";
      FolderCreate("MerePoule");
      FolderCreate("MerePoule\\" + IntegerToString(account));
   }

   //--- Symboles du robot : graphiques ouverts, puis ceux enregistres pour RELANCER.
   int Symbols(string &out[]) const
   {
      ArrayResize(out, 0);
      long ids[];
      int n = Find(ids);
      string lines[];
      int saved = ReadList(lines);
      for(int i = 0; i < n + saved; i++)
      {
         string sym = (i < n) ? ChartSymbol(ids[i]) : "";
         if(i >= n)
         {
            string parts[];
            if(StringSplit(lines[i - n], ';', parts) < 1) continue;
            sym = parts[0];
         }
         bool dup = false;
         for(int j = 0; j < ArraySize(out) && !dup; j++) dup = out[j] == sym;
         if(dup || sym == "") continue;
         int k = ArraySize(out);
         ArrayResize(out, k + 1);
         out[k] = sym;
      }
      return ArraySize(out);
   }

   int  TargetCount() const    { return ArraySize(m_targets); }
   bool RecentlyClosed() const { return TimeLocal() - m_closedAt < 5; }
   int  Saved() const          { string lines[]; return ReadList(lines); }

   bool IsTarget(const long chartId) const
   {
      string name = ChartGetString(chartId, CHART_EXPERT_NAME);
      if(name == "") return false;
      for(int i = 0; i < ArraySize(m_targets); i++)
         if(name == m_targets[i]) return true;
      return false;
   }

   //--- Graphiques portant un EA cible, hors celui du Watchdog.
   int Find(long &ids[]) const
   {
      ArrayResize(ids, 0);
      for(long id = ChartFirst(); id >= 0; id = ChartNext(id))
      {
         if(id == ChartID() || !IsTarget(id)) continue;
         int n = ArraySize(ids);
         ArrayResize(ids, n + 1);
         ids[n] = id;
      }
      return ArraySize(ids);
   }

   int Close(const long &ids[])
   {
      int closed = 0;
      for(int i = 0; i < ArraySize(ids); i++)
      {
         string where = ChartSymbol(ids[i]);
         if(ChartClose(ids[i])) closed++;
         else PrintFormat("MerePoule: graphique %s non ferme, err=%d", where, GetLastError());
      }
      if(ArraySize(ids) > 0) m_closedAt = TimeLocal();
      return closed;
   }

   //--- Enregistre le modele de chaque graphique du robot, puis les ferme.
   //--- Sans graphique ouvert, la liste precedente est gardee : un arret
   //--- pendant une PAUSE ne perd pas ce que RELANCER doit rouvrir.
   //--- Modele de chaque graphique : un nom stable par symbole et periode,
   //--- pour qu'une sauvegarde ne remplace que le sien.
   string TemplateName(const string symbol, const int period) const
   {
      string s = symbol;
      StringReplace(s, " ", "");
      return m_prefix + s + "_" + IntegerToString(period);
   }

   //--- Enregistre et ferme les graphiques ouverts du robot. Les graphiques
   //--- deja gardes et fermes restent dans la liste : un symbole eteint par
   //--- le go-to-market par symbole ne doit pas etre oublie.
   int SaveAndClose(int &found, int &saved, const string only = "")
   {
      long all[], ids[];
      int n = Find(all);
      found = 0;
      saved = 0;
      for(int i = 0; i < n; i++)   // only : un seul symbole (pause ou coupe par symbole)
      {
         if(only != "" && ChartSymbol(all[i]) != only) continue;
         ArrayResize(ids, found + 1);
         ids[found++] = all[i];
      }
      if(found == 0) return 0;

      string keep[];
      ReadList(keep);
      string lines = "";
      for(int i = 0; i < found; i++)
      {
         string sym = ChartSymbol(ids[i]);
         string per = IntegerToString((int)ChartPeriod(ids[i]));
         string tpl = TemplateName(sym, (int)ChartPeriod(ids[i]));
         if(ChartSaveTemplate(ids[i], tpl))
         {
            saved++;
            lines += sym + ";" + per + ";" + tpl + "\r\n";
            for(int k = 0; k < ArraySize(keep); k++)
            {
               string p[];
               if(StringSplit(keep[k], ';', p) == 3 && p[0] == sym && p[1] == per) keep[k] = "";
            }
         }
         else PrintFormat("MerePoule: modele de %s non enregistre, err=%d", sym, GetLastError());
      }
      string old = "";
      for(int k = 0; k < ArraySize(keep); k++)
         if(keep[k] != "") old += keep[k] + "\r\n";
      WriteList(old + lines);
      return Close(ids);
   }

   //--- Symboles gardes pour RELANCER, en tableau JSON.
   string SavedJson() const
   {
      string lines[];
      int n = ReadList(lines);
      string s = "[", seen = "|";
      for(int i = 0; i < n; i++)
      {
         string p[];
         if(StringSplit(lines[i], ';', p) != 3 || StringFind(seen, "|" + p[0] + "|") >= 0) continue;
         seen += p[0] + "|";
         s += (s == "[" ? "" : ",") + MP_JsonStr(p[0]);
      }
      return s + "]";
   }

   //--- Rouvre les graphiques gardes qui ne sont pas deja ouverts ; only
   //--- vide = tous, sinon seulement ces symboles (go-to-market par
   //--- symbole). total : graphiques a rouvrir.
   int Relaunch(int &total, string &errors, const string &only[])
   {
      errors = "";
      total  = 0;
      string lines[];
      int n = ReadList(lines);
      long ids[];
      int open = Find(ids);
      int opened = 0;
      for(int i = 0; i < n; i++)
      {
         string parts[];
         if(StringSplit(lines[i], ';', parts) != 3) { errors += "ligne illisible ; "; continue; }
         string          symbol = parts[0];
         ENUM_TIMEFRAMES period = (ENUM_TIMEFRAMES)StringToInteger(parts[1]);
         bool wanted = ArraySize(only) == 0;
         for(int k = 0; k < ArraySize(only) && !wanted; k++) wanted = only[k] == symbol;
         bool already = false;
         for(int k = 0; k < open && !already; k++) already = ChartSymbol(ids[k]) == symbol && ChartPeriod(ids[k]) == period;
         if(!wanted || already) continue;
         total++;

         SymbolSelect(symbol, true);
         long id = ChartOpen(symbol, period);
         if(id == 0)
         {
            errors += StringFormat("%s : graphique non ouvert (err %d) ; ", symbol, GetLastError());
            continue;
         }
         if(!ChartApplyTemplate(id, parts[2] + ".tpl"))
         {
            errors += StringFormat("%s : mod{e`}le non appliqu{e'} (err %d) ; ", symbol, GetLastError());
            ChartClose(id);
            continue;
         }
         opened++;
      }
      return opened;
   }

   //--- A appeler chaque seconde en RUN : relit les reglages chaque minute,
   //--- ou tout de suite quand un graphique du robot est nouveau (relance).
   void UpdateInputs()
   {
      long ids[];
      int  n     = Find(ids);
      bool known = n == ArraySize(m_inputIds);
      for(int i = 0; i < n && known; i++)
      {
         bool found = false;
         for(int j = 0; j < ArraySize(m_inputIds); j++)
            if(m_inputIds[j] == ids[i]) { found = true; break; }
         known = found;
      }
      if(!known || TimeLocal() - m_inputsAt >= MP_INPUTS_REFRESH_SEC) RefreshInputs();
   }

   string InputsOf(const long chartId) const
   {
      for(int i = 0; i < ArraySize(m_inputIds); i++)
         if(m_inputIds[i] == chartId) return m_inputJson[i];
      return "{}";
   }

   //--- Change le reglage param des graphiques du robot (symbol vide :
   //--- tous) en leur reappliquant leur modele modifie ; l'EA redemarre
   //--- avec la nouvelle valeur. eligible : graphiques qui ont ce reglage.
   //--- Renvoie le nombre de graphiques modifies.
   int SetParam(const string param, const string value, const string symbol,
                int &eligible, string &previous, string &charts, string &errors)
   {
      eligible = 0;
      previous = "";
      charts   = "";
      errors   = "";
      int changed = 0;
      long ids[];
      int n = Find(ids);
      for(int i = 0; i < n; i++)
      {
         string where = ChartSymbol(ids[i]);
         if(symbol != "" && where != symbol) continue;

         string name = "edit_" + IntegerToString(i + 1);
         string content;
         int    from, to;
         if(!Snapshot(ids[i], name, content) || !InputsSpan(content, from, to))
         {
            errors += where + " : mod{e`}le illisible ; ";
            continue;
         }
         int p = StringFind(content, "\n" + param + "=", from - 1);
         if(p < 0 || p >= to) continue;   // ce graphique n'a pas ce reglage
         eligible++;

         int vs  = p + 1 + StringLen(param) + 1;
         int le  = StringFind(content, "\r\n", vs);
         if(le < 0 || le > to) le = to;
         int bar = StringFind(content, "||", vs);
         int ve  = (bar >= 0 && bar < le) ? bar : le;
         string old = StringSubstr(content, vs, ve - vs);

         if(!WriteTemplate(name, StringSubstr(content, 0, vs) + value + StringSubstr(content, ve)))
         {
            errors += where + " : mod{e`}le modifi{e'} non {e'}crit ; ";
            continue;
         }
         if(!ChartApplyTemplate(ids[i], "\\Files\\" + m_files + name + ".tpl"))
         {
            errors += StringFormat("%s : mod{e`}le non appliqu{e'} (err %d) ; ", where, GetLastError());
            continue;
         }
         changed++;
         if(previous == "") previous = old;
         charts += (charts == "" ? "" : ", ") + where;
      }
      //--- L'EA recharge le modele de facon asynchrone : relire dans une dizaine de secondes.
      m_inputsAt = TimeLocal() - MP_INPUTS_REFRESH_SEC + 10;
      return changed;
   }

   //--- Aide au reglage de la cible : les EA reellement poses.
   string ExpertsOnCharts() const
   {
      string list = "";
      for(long id = ChartFirst(); id >= 0; id = ChartNext(id))
      {
         if(id == ChartID()) continue;
         string name = ChartGetString(id, CHART_EXPERT_NAME);
         if(name == "") continue;
         if(list != "") list += ", ";
         list += "\"" + name + "\" (" + ChartSymbol(id) + ")";
      }
      return (list == "") ? "aucun" : list;
   }

   //--- [{"expert":..,"symbol":..,"period":"M1","inputs":{..}}, ...]
   string TargetsJson() const
   {
      long ids[];
      int n = Find(ids);
      string s = "[";
      for(int i = 0; i < n; i++)
      {
         string period = EnumToString(ChartPeriod(ids[i]));
         StringReplace(period, "PERIOD_", "");
         if(i > 0) s += ",";
         s += "{\"expert\":" + MP_JsonStr(ChartGetString(ids[i], CHART_EXPERT_NAME))
            + ",\"symbol\":" + MP_JsonStr(ChartSymbol(ids[i]))
            + ",\"period\":" + MP_JsonStr(period)
            + ",\"inputs\":" + InputsOf(ids[i]) + "}";
      }
      return s + "]";
   }
};

#endif // MEREPOULE_ROBOT_MQH
