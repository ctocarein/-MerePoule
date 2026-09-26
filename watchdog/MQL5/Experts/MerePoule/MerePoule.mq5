//+------------------------------------------------------------------+
//| MerePoule.mq5                                                    |
//| Watchdog de PETIT POUSSIN. docs/MerePoule_Architecture.md,       |
//| sections "Composant 1" et "Contrat".                             |
//|                                                                  |
//| SEUL composant qui decide d'un arret. Pose sur un graphique      |
//| separe de celui du robot surveille ; ne modifie jamais son code. |
//|                                                                  |
//| Etats : RUN -> PAUSE sur drapeau pause (robot coupe, positions   |
//|         gardees) ; PAUSE -> RUN sur drapeau relaunch ;           |
//|         RUN ou PAUSE -> KILL sur regle declenchee ou drapeau     |
//|         kill ; KILL -> RUN sur drapeau reset seulement (manuel). |
//| L'etat vit dans une variable globale du terminal, par compte :   |
//| ni un redemarrage de MT5 ni le retrait de l'EA ne rearment.      |
//|                                                                  |
//| Boucle, chaque seconde (timer, pas ticks : un marche sans tick   |
//| ne suspend pas la surveillance) :                                |
//|  1. solde d'ouverture si le jour serveur a change                |
//|  2. statut                                                       |
//|  3. drapeau reset                                                |
//|  4. demande de configuration                                     |
//|  5. en KILL : refermer ce qui a reapparu, puis s'arreter la      |
//|  6. drapeau kill                                                 |
//|  7. drapeaux pause, relaunch, puis reglage du robot (robot.flag) |
//|  8. regles de risque                                             |
//|  9. Bouclier suiveur : SL catastrophe a une part du prix actuel  |
//|  9b. Cameleon (observation) : groupe a contre-tendance, bilan   |
//| Et, en RUN, la pause par symbole selon la regle choisie pour     |
//| lui (1.34 : tendance, saut, les deux ou aucune ; rules.flag).    |
//| 10. calendrier economique (au plus une fois par minute)          |
//| Les messages Telegram partent en fin de boucle, apres les        |
//| actions : l'envoi peut bloquer plusieurs secondes.               |
//|                                                                  |
//| Seuils a distance : dans les plafonds InpCap*, reglables         |
//| seulement ici ; jamais de desactivation a distance ; toute       |
//| modification des parametres dans MT5 les efface.                 |
//|                                                                  |
//| Ne desactive JAMAIS "Algo Trading" en global : il ne pourrait    |
//| plus fermer lui-meme les positions.                              |
//+------------------------------------------------------------------+
#property strict
#property version     "1.34"
#property description "MerePoule : surveille PETIT POUSSIN, applique les regles de risque et met le compte a plat."

#include <Trade\Trade.mqh>
#include <MerePoule\Contract.mqh>
#include <MerePoule\Telegram.mqh>
#include <MerePoule\NewsWatch.mqh>
#include <MerePoule\Robot.mqh>
#include <MerePoule\Shield.mqh>
#include <MerePoule\Text.mqh>
#include <MerePoule\Market.mqh>
#include <MerePoule\Chameleon.mqh>

#define MP_VERSION          "1.34"
#define MP_CLOSE_PASSES     3
#define MP_CLOSE_DEVIATION  1000   // points : a l'arret, fermer prime sur le prix
#define MP_TG_TIMEOUT_MS    3000   // statut perime a 5 s : l'envoi ne doit pas le faire passer pour muet
#define MP_TG_DEINIT_MS     2000   // MT5 n'attend pas longtemps un OnDeinit
#define MP_MARGIN_REARM     1.10   // la marge doit remonter a 110 % du seuil pour realerter
#define MP_REPEAT_ALERT_SEC 60
#define MP_MARGIN_MAX       100000.0
#define MP_RESTART_MIN_SEC  60     // interruption minimale pour l'alerte de redemarrage

enum MP_State
{
   MP_RUN   = 0,
   MP_KILL  = 1,
   MP_PAUSE = 2
};

enum MP_MarginAction
{
   MARGIN_ALERT = 0,   // alerte seule (tant que le seuil n'est pas calibre)
   MARGIN_KILL  = 1    // arret
};

//--- MT5 affiche le commentaire d'un input comme son nom dans la fenetre
//--- des parametres : ces commentaires sont des libelles, pas des notes.
//--- Details : watchdog/README.md, section Parametres.
//---  - 0 desactive une regle ; le budget du Bouclier a 0 vaut 2 fois le
//---    seuil de perte flottante actif
//---  - un plafond a 0 rend sa regle non modifiable a distance
//---  - reglages du robot : input:libelle:min:max, separes par ";"
input group "Compte"
input string          InpLabel             = "";      // Nom du compte (app et Telegram)

input group "Robot surveille"
input string          InpTargetExperts     = "PETIT POUSSIN 2.V377;RETOUR A LA MAISON PETIT POUSSIN;LE RECUPERATEUR V44.5"; // Robots surveilles (noms exacts, separes par ;)
input long            InpMagicFilter       = 0;       // Magic du robot (0 = toutes les positions)

input group "Regles de risque (0 = regle desactivee)"
input double          InpMarginLevelMin    = 500.0;   // Marge critique, %
input MP_MarginAction InpMarginAction      = MARGIN_ALERT; // Sur marge critique
input double          InpMaxFloatingLoss   = 440.0;   // Perte flottante max (devise du compte)
input double          InpMaxDailyDdPct     = 5.0;     // Drawdown du jour max, %
input double          InpMaxGivebackPct    = 20.0;    // Recul max depuis le plus haut, %
input bool            InpManualDecision    = true;    // Perte flottante max : decision manuelle (non = arret automatique)
input double          InpFloatingLastResort = 0.0;    // Arret automatique, dernier filet (0 = 2 x la perte flottante max)
input bool            InpPauseMisaligned   = true;    // Regle au rouge et symbole a plat : robot eteint sur ce symbole
input bool            InpPauseCounter      = true;    // Contre-tendance confirmee : robot en pause sur ce symbole, positions gardees
input int             InpJumpLateMin       = 40;      // Regle saut : pause si aucun saut depuis (min, 0 = off)

input group "Bouclier (stop loss catastrophe chez le courtier)"
input bool            InpShield            = true;    // Bouclier actif
input double          InpShieldBudget      = 0.0;     // Budget du Bouclier (0 = 2 x perte flottante)

input group "Cameleon (avant l'arret, en observation : ne ferme rien)"
input double          InpChameleonPct      = 25.0;    // Cameleon : perte d'un groupe a contre-tendance, % de la perte flottante max (0 = off)
input double          InpChameleonHeavyPct = 50.0;    // Cameleon : perte lourde d'un groupe, toute tendance, % de la perte flottante max (0 = off)

input group "Seuils modifiables depuis l'app (limites reglables ici seulement)"
input bool            InpRemoteConfig      = true;    // Accepter les seuils envoyes depuis l'app
input double          InpCapMarginLevelMin = 250.0;   // Marge critique : plancher accepte, %
input double          InpCapFloatingLoss   = 880.0;   // Perte flottante : plafond accepte
input double          InpCapDailyDdPct     = 10.0;    // Drawdown du jour : plafond accepte, %
input double          InpCapGivebackPct    = 40.0;    // Recul : plafond accepte, %

input group "Reglages du robot modifiables depuis l'app (bornes reglables ici seulement)"
input string          InpRobotParams       = "InpParamL1:Lot:0.01:0.5"; // Reglages modifiables (input:libelle:min:max)

input group "Annonces economiques (calendrier MT5)"
input string          InpNewsCurrencies    = "";      // Devises surveillees, ex. USD;EUR (vide = off)
input int             InpNewsBeforeMin     = 10;      // Minutes avant l'annonce
input int             InpNewsAfterMin      = 5;       // Minutes apres l'annonce

input group "Telegram"
input string          InpTelegramToken     = "";      // Jeton du bot Telegram (vide = pas d'alerte)
input string          InpTelegramChatId    = "";      // Chat ID Telegram

//--- Seuils actifs : parametres locaux, ou demande a distance acceptee.
struct MP_Config
{
   double marginLevelMin;
   int    marginAction;
   double maxFloatingLoss;
   double maxDailyDdPct;
   double maxGivebackPct;
};

//--- Demande lue dans un drapeau. Champs vides si le drapeau est vide
//--- ou illisible : la demande reste valable.
struct MP_Request
{
   string id;
   string origin;
   string reason;
};

//--- Reglage du robot que la passerelle peut changer, dans ses bornes.
struct MP_RobotParam
{
   string name;    // nom de l'input dans le modele, ex. InpParamL1
   string label;   // nom affiche dans MT5 et dans l'app, ex. Lot
   double min;
   double max;
};

CTrade     g_trade;
CTelegram  g_telegram;
CNewsWatch g_news;
CRobot     g_robot;
CShield    g_shield;
CMarket    g_market;
CChameleon g_chameleon;

MP_RobotParam g_robotParams[];

bool      g_ready        = false;   // compte connecte, etat charge, verrou pris
long      g_account      = 0;
string    g_gv           = "";      // prefixe des variables globales : "MerePoule.<compte>."
string    g_dir          = "";      // dossier du contrat : "MerePoule\<compte>\"
bool      g_lockOwned    = false;
MP_State  g_state        = MP_RUN;
MP_Config g_cfg;
bool      g_cfgRemote    = false;   // au moins un seuil actif vient d'une demande a distance
long      g_seq          = 0;       // numero du dernier evenement
long      g_day          = 0;       // jour serveur
double    g_dayOpen      = 0.0;     // solde d'ouverture du jour
double    g_peak         = 0.0;     // plus haut d'equity du jour, ou depuis le rearmement
datetime  g_prevStatusTs = 0;       // heure GMT du dernier statut avant ce demarrage
string    g_lastKillAt   = "";      // heure GMT ISO du dernier arret
string    g_lastKillWhy  = "";
string    g_lastKillReq  = "";
bool      g_marginLow    = false;   // alerte de marge envoyee, en attente de remontee
bool      g_decisionAlerted = false; // alerte de decision envoyee, en attente de remontee
bool      g_manualNeeded = false;   // positions que l'arret n'a pas pu fermer
bool      g_newsDown     = false;   // calendrier indisponible, deja signale
bool      g_algoOff      = false;   // trading automatique interdit, deja signale
bool      g_statusDirty  = false;   // un evenement a eu lieu depuis le dernier statut
datetime  g_lastRepeat   = 0;       // derniere alerte "position reapparue"
datetime  g_lastIoError  = 0;
string    g_outHtml[];              // messages Telegram en attente (HTML), envoyes en fin de boucle
string    g_outPlain[];             // les memes en texte brut, si Telegram refuse le HTML

//+------------------------------------------------------------------+
//| Outils                                                           |
//+------------------------------------------------------------------+
string StateName(const MP_State s)
{
   if(s == MP_KILL)  return "KILL";
   if(s == MP_PAUSE) return "PAUSE";
   return "RUN";
}

string ActionName(const int action) { return (action == MARGIN_KILL) ? "kill" : "alert"; }

//--- "MAX GainX 2000" -> "GainX 2000" : les messages parlent simple.
string ShortSymbol(const string symbol)
{
   return (StringFind(symbol, "MAX ") == 0) ? StringSubstr(symbol, 4) : symbol;
}

string StatePlain(const MP_State s)
{
   if(s == MP_KILL)  return "tout est arr{e^}t{e'}";
   if(s == MP_PAUSE) return "robot en pause";
   return "surveillance active";
}

//--- Heure GMT en clair : "25/09 a 12:24 GMT".
string TimePlain(const datetime gmt)
{
   MqlDateTime t;
   TimeToStruct(gmt, t);
   return StringFormat("%02d/%02d {a`} %02d:%02d GMT", t.day, t.mon, t.hour, t.min);
}

//--- Meme chose depuis l'heure ISO du dernier arret.
string IsoPlain(const string iso)
{
   if(StringLen(iso) < 16) return "?";
   return StringSubstr(iso, 8, 2) + "/" + StringSubstr(iso, 5, 2) + " {a`} " + StringSubstr(iso, 11, 5) + " GMT";
}

string Duration(const long seconds)
{
   if(seconds < 60)   return IntegerToString(seconds) + " s";
   if(seconds < 3600) return StringFormat("%d min %02d s", (int)(seconds / 60), (int)(seconds % 60));
   return StringFormat("%I64d h %02d min", seconds / 3600, (int)((seconds % 3600) / 60));
}

string GvName(const string key) { return g_gv + key; }

double GvGet(const string key, const double def)
{
   string name = GvName(key);
   return GlobalVariableCheck(name) ? GlobalVariableGet(name) : def;
}

void GvSet(const string key, const double value) { GlobalVariableSet(GvName(key), value); }

void IoError(const string what)
{
   if(TimeLocal() - g_lastIoError < 60) return;
   g_lastIoError = TimeLocal();
   PrintFormat("MerePoule: %s, err=%d", what, GetLastError());
}

//--- Journal Experts tout de suite, Telegram en fin de boucle. text est
//--- deja converti par MP_Fr ; icon est une icone MP_ICON_*.
void Notify(const string text, const string icon)
{
   Print("MerePoule: ", text);
   int n = ArraySize(g_outHtml);
   ArrayResize(g_outHtml, n + 1);
   ArrayResize(g_outPlain, n + 1);
   g_outHtml[n]  = MP_TelegramBlock(icon, text);
   g_outPlain[n] = text;
}

//--- Un seul message Telegram par boucle : en-tete au nom du compte, un
//--- bloc par evenement, l'heure en pied. Au-dela de la limite de
//--- Telegram (4096), les derniers blocs restent dans le journal Experts.
void FlushOutbox(const int timeoutMs)
{
   int n = ArraySize(g_outHtml);
   if(n == 0) return;
   string who    = (InpLabel != "" ? InpLabel + " " : "") + IntegerToString(g_account);
   string html   = MP_ICON_CHICK + " <b>MerePoule</b> &#183; " + MP_HtmlEscape(who);
   string plain  = "MerePoule - " + who;
   string footer = "<i>" + TimeToString(TimeGMT(), TIME_MINUTES | TIME_SECONDS) + " GMT</i>";
   int kept = 0;
   for(int i = 0; i < n; i++)
   {
      if(StringLen(html) + StringLen(g_outHtml[i]) + StringLen(footer) > 3800) break;
      html  += "\n\n" + g_outHtml[i];
      plain += "\n\n" + g_outPlain[i];
      kept++;
   }
   if(kept < n)
   {
      html  += StringFormat("\n\n<i>%d autre(s) message(s) dans le journal</i>", n - kept);
      plain += StringFormat("\n\n%d autre(s) message(s) dans le journal", n - kept);
   }
   ArrayResize(g_outHtml, 0);
   ArrayResize(g_outPlain, 0);
   g_telegram.Send(html + "\n\n" + footer, plain, timeoutMs);
}

//--- Une ligne dans events.jsonl et, si telegram, un message Telegram.
//--- fields : paires JSON supplementaires, sans accolades.
void Report(const string type, const string level, const string text,
            const string fields = "", const bool telegram = true, const string code = "")
{
   string message = MP_Fr(text);
   g_seq++;
   GvSet("seq", (double)g_seq);
   string line = "{\"v\":2,\"seq\":" + IntegerToString(g_seq)
               + ",\"ts\":" + MP_JsonStr(MP_IsoTime(TimeGMT()))
               + ",\"account\":" + IntegerToString(g_account)
               + ",\"type\":" + MP_JsonStr(type)
               + ",\"level\":" + MP_JsonStr(level)
               + ",\"message\":" + MP_JsonStr(message)
               + (fields == "" ? "" : "," + fields) + "}\n";
   if(!MP_AppendLine(g_dir + MP_EVENTS, line)) IoError("evenement " + type + " non journalise");

   if(telegram) Notify(message, MP_IconFor(type, code));
   else Print("MerePoule: ", message);
   g_statusDirty = true;
}

void ReportAlert(const string code, const string message, const bool telegram = true, const string fields = "")
{
   Report("alert", "warning", message, "\"code\":" + MP_JsonStr(code) + (fields == "" ? "" : "," + fields), telegram, code);
}

//+------------------------------------------------------------------+
//| Demandes                                                         |
//+------------------------------------------------------------------+
void ParseRequest(const string content, MP_Request &req)
{
   req.id     = MP_Sanitize(MP_JsonText(content, "request_id"), 64, true);
   req.origin = MP_Sanitize(MP_JsonText(content, "origin"), 64, true);
   req.reason = MP_Sanitize(MP_JsonText(content, "reason"), 200, false);
}

//--- D'ou vient une demande, en clair : "depuis Telegram", "depuis l'app (pixel)"...
string OriginText(const MP_Request &req)
{
   if(req.origin == "")         return "origine inconnue";
   if(req.origin == "telegram") return "depuis Telegram";
   if(req.origin == "script")   return "depuis MT5";
   if(req.origin == "watchdog") return "par la M{e`}re";
   if(StringFind(req.origin, "app:") == 0) return "depuis l'app (" + StringSubstr(req.origin, 4) + ")";
   return req.origin;
}

string RequestFields(const MP_Request &req)
{
   return "\"origin\":" + MP_JsonStrOrNull(req.origin) + ",\"request_id\":" + MP_JsonStrOrNull(req.id);
}

//+------------------------------------------------------------------+
//| Seuils                                                           |
//+------------------------------------------------------------------+
void LocalConfig(MP_Config &c)
{
   c.marginLevelMin  = MathMax(0.0, InpMarginLevelMin);
   c.marginAction    = InpMarginAction;
   c.maxFloatingLoss = MathMax(0.0, InpMaxFloatingLoss);
   c.maxDailyDdPct   = MathMax(0.0, InpMaxDailyDdPct);
   c.maxGivebackPct  = MathMax(0.0, InpMaxGivebackPct);
}

//--- Empreinte des parametres locaux qui encadrent les seuils. Si elle
//--- change, l'operateur a regle MT5 lui-meme : ses valeurs priment.
double InputsFingerprint()
{
   string s = StringFormat("%.4f|%d|%.4f|%.4f|%.4f|%d|%.4f|%.4f|%.4f|%.4f",
                           InpMarginLevelMin, (int)InpMarginAction, InpMaxFloatingLoss, InpMaxDailyDdPct,
                           InpMaxGivebackPct, (int)InpRemoteConfig, InpCapMarginLevelMin, InpCapFloatingLoss,
                           InpCapDailyDdPct, InpCapGivebackPct);
   uint h = 2166136261;   // FNV-1a
   for(int i = 0; i < StringLen(s); i++)
   {
      h ^= StringGetCharacter(s, i);
      h *= 16777619;
   }
   return (double)h;
}

void SaveOverrides()
{
   GvSet("cfg.margin",        g_cfg.marginLevelMin);
   GvSet("cfg.margin_action", g_cfg.marginAction);
   GvSet("cfg.floating",      g_cfg.maxFloatingLoss);
   GvSet("cfg.dd",            g_cfg.maxDailyDdPct);
   GvSet("cfg.giveback",      g_cfg.maxGivebackPct);
   GlobalVariablesFlush();
}

void ClearOverrides()
{
   GlobalVariableDel(GvName("cfg.margin"));
   GlobalVariableDel(GvName("cfg.margin_action"));
   GlobalVariableDel(GvName("cfg.floating"));
   GlobalVariableDel(GvName("cfg.dd"));
   GlobalVariableDel(GvName("cfg.giveback"));
}

void LoadConfig()
{
   LocalConfig(g_cfg);
   g_cfgRemote = false;
   bool   had = GlobalVariableCheck(GvName("cfg.floating"));
   double fp  = InputsFingerprint();

   if(GvGet("cfg.inputs", -1.0) != fp || !InpRemoteConfig)
   {
      ClearOverrides();
      GvSet("cfg.inputs", fp);
      if(had)
         Report("config_cleared", "warning",
                "Param{e`}tres modifi{e'}s dans MT5\nSeuils envoy{e'}s {a`} distance effac{e'}s, retour aux valeurs locales.");
      return;
   }
   if(!had) return;

   g_cfg.marginLevelMin  = GvGet("cfg.margin",        g_cfg.marginLevelMin);
   g_cfg.marginAction    = (int)GvGet("cfg.margin_action", g_cfg.marginAction);
   g_cfg.maxFloatingLoss = GvGet("cfg.floating",      g_cfg.maxFloatingLoss);
   g_cfg.maxDailyDdPct   = GvGet("cfg.dd",            g_cfg.maxDailyDdPct);
   g_cfg.maxGivebackPct  = GvGet("cfg.giveback",      g_cfg.maxGivebackPct);
   g_cfgRemote = true;
}

//--- Un seuil "au plus" (flottant, drawdown, recul) : ]0 ; plafond].
void CheckMaxThreshold(const string json, const string key, const double cap, double &target, string &errors, int &found)
{
   double v;
   int r = MP_JsonNumber(json, key, v);
   if(r < 0) return;
   found++;
   if(r == 0)          { errors += key + " n'est pas un nombre ; "; return; }
   if(cap <= 0.0)      { errors += key + " non modifiable {a`} distance ; "; return; }
   if(v <= 0.0)        { errors += key + " : une r{e`}gle ne se d{e'}sactive que dans MT5 ; "; return; }
   if(v > cap)         { errors += StringFormat("%s %.2f au-del{a`} du plafond %.2f ; ", key, v, cap); return; }
   target = v;
}

//--- "" si la demande est acceptee (next rempli), sinon les refus.
string ValidateConfig(const string json, MP_Config &next)
{
   next = g_cfg;
   if(!InpRemoteConfig) return "modifications {a`} distance interdites dans MT5 (InpRemoteConfig)";

   string errors = "";
   int    found  = 0;
   CheckMaxThreshold(json, "max_floating_loss", InpCapFloatingLoss, next.maxFloatingLoss, errors, found);
   CheckMaxThreshold(json, "max_daily_dd_pct",  InpCapDailyDdPct,   next.maxDailyDdPct,   errors, found);
   CheckMaxThreshold(json, "max_giveback_pct",  InpCapGivebackPct,  next.maxGivebackPct,  errors, found);

   //--- Marge : un seuil "au moins", plancher InpCapMarginLevelMin.
   double v;
   int r = MP_JsonNumber(json, "margin_level_min", v);
   if(r >= 0)
   {
      found++;
      if(r == 0)                           errors += "margin_level_min n'est pas un nombre ; ";
      else if(InpCapMarginLevelMin <= 0.0) errors += "margin_level_min non modifiable {a`} distance ; ";
      else if(v < InpCapMarginLevelMin)    errors += StringFormat("margin_level_min %.1f sous le plancher %.1f ; ", v, InpCapMarginLevelMin);
      else if(v > MP_MARGIN_MAX)           errors += StringFormat("margin_level_min %.1f invraisemblable ; ", v);
      else                                 next.marginLevelMin = v;
   }

   //--- Action de marge : "alert" est un desserrement, accepte seulement
   //--- si le reglage local est deja "alerte seule".
   string action;
   bool   isString;
   if(MP_JsonGet(json, "margin_action", action, isString) && action != "null")
   {
      found++;
      if(action == "kill")       next.marginAction = MARGIN_KILL;
      else if(action != "alert") errors += "margin_action doit valoir alert ou kill ; ";
      else if(InpMarginAction == MARGIN_KILL)
         errors += "margin_action alert interdit : l'arr{e^}t sur marge est impos{e'} dans MT5 ; ";
      else next.marginAction = MARGIN_ALERT;
   }

   if(found == 0) errors = "aucun seuil dans la demande";
   return errors;
}

string ConfigDiff(const MP_Config &a, const MP_Config &b)
{
   string d = "";
   if(a.marginLevelMin != b.marginLevelMin)
      d += StringFormat("alerte de marge %.0f {->} %.0f %%, ", a.marginLevelMin, b.marginLevelMin);
   if(a.marginAction != b.marginAction)
      d += "sur marge basse : " + (a.marginAction == MARGIN_KILL ? "arr{e^}t" : "alerte") + " {->} "
         + (b.marginAction == MARGIN_KILL ? "arr{e^}t" : "alerte") + ", ";
   if(a.maxFloatingLoss != b.maxFloatingLoss)
      d += StringFormat("perte en cours max %.2f {->} %.2f, ", a.maxFloatingLoss, b.maxFloatingLoss);
   if(a.maxDailyDdPct != b.maxDailyDdPct)
      d += StringFormat("perte du jour max %.2f {->} %.2f %%, ", a.maxDailyDdPct, b.maxDailyDdPct);
   if(a.maxGivebackPct != b.maxGivebackPct)
      d += StringFormat("recul max %.2f {->} %.2f %%, ", a.maxGivebackPct, b.maxGivebackPct);
   return (d == "") ? "aucun changement" : StringSubstr(d, 0, StringLen(d) - 2);
}

//--- Dernier filet : l'arret automatique sur perte flottante (decision 28).
//--- En decision manuelle, 2 x la perte max, ou InpFloatingLastResort ;
//--- sinon la perte max elle-meme, comme avant.
double FloatingLastResort()
{
   if(g_cfg.maxFloatingLoss <= 0.0) return 0.0;
   if(!InpManualDecision) return g_cfg.maxFloatingLoss;
   return (InpFloatingLastResort > 0.0) ? MathMax(InpFloatingLastResort, g_cfg.maxFloatingLoss) : 2.0 * g_cfg.maxFloatingLoss;
}

string ConfigJson()
{
   return "{\"source\":" + MP_JsonStr(g_cfgRemote ? "remote" : "local")
        + ",\"remote_allowed\":" + MP_JsonBool(InpRemoteConfig)
        + ",\"margin_level_min\":" + MP_JsonNum(g_cfg.marginLevelMin, 1)
        + ",\"margin_action\":" + MP_JsonStr(ActionName(g_cfg.marginAction))
        + ",\"max_floating_loss\":" + MP_JsonNum(g_cfg.maxFloatingLoss, 2)
        + ",\"manual_decision\":" + MP_JsonBool(InpManualDecision)
        + ",\"floating_last_resort\":" + MP_JsonNum(FloatingLastResort(), 2)
        + ",\"max_daily_dd_pct\":" + MP_JsonNum(g_cfg.maxDailyDdPct, 2)
        + ",\"max_giveback_pct\":" + MP_JsonNum(g_cfg.maxGivebackPct, 2)
        + ",\"news_currencies\":" + MP_JsonStr(InpNewsCurrencies)
        + ",\"magic\":" + IntegerToString(InpMagicFilter)
        + ",\"jump_late_min\":" + IntegerToString(MathMax(0, InpJumpLateMin))
        + ",\"caps\":{\"margin_level_min\":" + MP_JsonNum(InpCapMarginLevelMin, 1)
        + ",\"margin_action_alert\":" + MP_JsonBool(InpMarginAction == MARGIN_ALERT)
        + ",\"max_floating_loss\":" + MP_JsonNum(InpCapFloatingLoss, 2)
        + ",\"max_daily_dd_pct\":" + MP_JsonNum(InpCapDailyDdPct, 2)
        + ",\"max_giveback_pct\":" + MP_JsonNum(InpCapGivebackPct, 2) + "}}";
}

//+------------------------------------------------------------------+
//| Reglages du robot modifiables a distance                         |
//+------------------------------------------------------------------+
//--- "InpParamL1:Lot:0.01:0.5;..." ; une entree mal formee est ignoree et signalee.
void ParseRobotParams()
{
   ArrayResize(g_robotParams, 0);
   string items[];
   int n = StringSplit(InpRobotParams, ';', items);
   for(int i = 0; i < n; i++)
   {
      string f[];
      string item = items[i];
      StringTrimLeft(item);
      StringTrimRight(item);
      if(item == "") continue;
      if(StringSplit(item, ':', f) != 4 || f[0] == "" || StringToDouble(f[3]) < StringToDouble(f[2]) || StringToDouble(f[2]) < 0.0)
      {
         PrintFormat("MerePoule: InpRobotParams, entree ignoree : %s (attendu input:libelle:min:max)", item);
         continue;
      }
      int k = ArraySize(g_robotParams);
      ArrayResize(g_robotParams, k + 1);
      g_robotParams[k].name  = f[0];
      g_robotParams[k].label = f[1];
      g_robotParams[k].min   = StringToDouble(f[2]);
      g_robotParams[k].max   = StringToDouble(f[3]);
   }
}

int FindRobotParam(const string name)
{
   for(int i = 0; i < ArraySize(g_robotParams); i++)
      if(g_robotParams[i].name == name) return i;
   return -1;
}

string RobotParamsJson()
{
   string s = "[";
   for(int i = 0; i < ArraySize(g_robotParams); i++)
   {
      if(i > 0) s += ",";
      s += "{\"name\":" + MP_JsonStr(g_robotParams[i].name)
         + ",\"label\":" + MP_JsonStr(g_robotParams[i].label)
         + ",\"min\":" + NumberText(g_robotParams[i].min)
         + ",\"max\":" + NumberText(g_robotParams[i].max) + "}";
   }
   return s + "]";
}

//--- 0.30000000 -> "0.3" : la valeur ecrite dans le modele, comme MT5 l'ecrirait.
string NumberText(const double v)
{
   string s = DoubleToString(v, 8);
   if(StringFind(s, ".") < 0) return s;
   while(StringLen(s) > 1 && StringGetCharacter(s, StringLen(s) - 1) == '0') s = StringSubstr(s, 0, StringLen(s) - 1);
   if(StringGetCharacter(s, StringLen(s) - 1) == '.') s = StringSubstr(s, 0, StringLen(s) - 1);
   return s;
}

//--- Budget du Bouclier ; suit le seuil de perte flottante actif, meme modifie a distance.
double ShieldBudget()
{
   if(!InpShield) return 0.0;
   return (InpShieldBudget > 0.0) ? InpShieldBudget : 2.0 * g_cfg.maxFloatingLoss;
}

string RulesSummary()
{
   string s = (g_cfg.marginLevelMin > 0.0)
            ? StringFormat("marge < %.0f %% (%s)", g_cfg.marginLevelMin, g_cfg.marginAction == MARGIN_KILL ? "arret" : "alerte seule")
            : "marge off";
   s += (g_cfg.maxFloatingLoss > 0.0) ? StringFormat(", flottant {<=} -%.2f", g_cfg.maxFloatingLoss) : ", flottant off";
   s += (g_cfg.maxDailyDdPct > 0.0)   ? StringFormat(", DD jour {>=} %.1f %%", g_cfg.maxDailyDdPct)  : ", DD jour off";
   s += (g_cfg.maxGivebackPct > 0.0)  ? StringFormat(", recul {>=} %.1f %%", g_cfg.maxGivebackPct)   : ", recul off";
   s += g_news.Enabled() ? ", annonces " + InpNewsCurrencies : ", annonces off";
   s += (ShieldBudget() > 0.0) ? StringFormat(", Bouclier %.2f", ShieldBudget()) : ", BOUCLIER OFF";
   s += (InpMagicFilter != 0) ? ", magic " + IntegerToString(InpMagicFilter) : ", toutes les positions";
   for(int i = 0; i < ArraySize(g_robotParams); i++)
      s += StringFormat(", %s du robot %s-%s", g_robotParams[i].label, NumberText(g_robotParams[i].min), NumberText(g_robotParams[i].max));
   if(g_cfgRemote) s += " (seuils modifi{e'}s {a`} distance)";
   return s;
}

//+------------------------------------------------------------------+
//| Compte : positions et ordres surveilles                          |
//+------------------------------------------------------------------+
bool IsMonitored(const long magic) { return InpMagicFilter == 0 || magic == InpMagicFilter; }

//--- floating : profit + swap des positions surveillees. Sans filtre
//--- magic, c'est l'equity moins le solde de la spec.
int CountPositions(double &floating)
{
   int n = 0;
   floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsMonitored(PositionGetInteger(POSITION_MAGIC))) continue;
      n++;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return n;
}

int CountPositions()
{
   double floating;
   return CountPositions(floating);
}

int CountOrders()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderGetTicket(i) == 0) continue;
      if(IsMonitored(OrderGetInteger(ORDER_MAGIC))) n++;
   }
   return n;
}

//--- Exposition par symbole des positions surveillees.
string SymbolsJson()
{
   string names[];
   int    count[];
   double buyVol[], sellVol[], floating[];
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0 || !IsMonitored(PositionGetInteger(POSITION_MAGIC))) continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      int k = -1;
      for(int j = 0; j < ArraySize(names); j++)
         if(names[j] == symbol) { k = j; break; }
      if(k < 0)
      {
         k = ArraySize(names);
         ArrayResize(names, k + 1);
         ArrayResize(count, k + 1);
         ArrayResize(buyVol, k + 1);
         ArrayResize(sellVol, k + 1);
         ArrayResize(floating, k + 1);
         names[k] = symbol;
         count[k] = 0;
         buyVol[k] = 0.0;
         sellVol[k] = 0.0;
         floating[k] = 0.0;
      }
      count[k]++;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyVol[k] += PositionGetDouble(POSITION_VOLUME);
      else                                                       sellVol[k] += PositionGetDouble(POSITION_VOLUME);
      floating[k] += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   string s = "[";
   for(int k = 0; k < ArraySize(names); k++)
   {
      if(k > 0) s += ",";
      s += "{\"symbol\":" + MP_JsonStr(names[k])
         + ",\"positions\":" + IntegerToString(count[k])
         + ",\"buy_volume\":" + MP_JsonNum(buyVol[k], 2)
         + ",\"sell_volume\":" + MP_JsonNum(sellVol[k], 2)
         + ",\"floating\":" + MP_JsonNum(floating[k], 2) + "}";
   }
   return s + "]";
}

//--- Symboles dont on suit le marche : ceux du robot (ouverts ou
//--- enregistres pour RELANCER) et ceux des positions surveillees.
int MarketSymbols(string &syms[])
{
   g_robot.Symbols(syms);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0 || !IsMonitored(PositionGetInteger(POSITION_MAGIC))) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      bool dup = false;
      for(int j = 0; j < ArraySize(syms) && !dup; j++) dup = syms[j] == sym;
      if(dup) continue;
      int k = ArraySize(syms);
      ArrayResize(syms, k + 1);
      syms[k] = sym;
   }
   return ArraySize(syms);
}

void UpdateMarket(const bool force = false)
{
   string syms[];
   MarketSymbols(syms);
   g_market.Update(syms, force);
}

//--- Perte par symbole et par sens, une ligne chacun, puis le marche de
//--- chaque symbole : ce qui explique un arret.
string ExposureText()
{
   string keys[];
   int    count[];
   double lots[], res[];
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0 || !IsMonitored(PositionGetInteger(POSITION_MAGIC))) continue;
      string key = ShortSymbol(PositionGetString(POSITION_SYMBOL))
                 + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? ", achats" : ", ventes");
      int k = -1;
      for(int j = 0; j < ArraySize(keys); j++)
         if(keys[j] == key) { k = j; break; }
      if(k < 0)
      {
         k = ArraySize(keys);
         ArrayResize(keys, k + 1);
         ArrayResize(count, k + 1);
         ArrayResize(lots, k + 1);
         ArrayResize(res, k + 1);
         keys[k] = key;
         count[k] = 0;
         lots[k] = 0.0;
         res[k] = 0.0;
      }
      count[k]++;
      lots[k] += PositionGetDouble(POSITION_VOLUME);
      res[k]  += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   if(ArraySize(keys) == 0) return "";

   //--- Du pire au meilleur : ce qui a coute d'abord.
   for(int a = 0; a < ArraySize(keys) - 1; a++)
      for(int b = a + 1; b < ArraySize(keys); b++)
         if(res[b] < res[a])
         {
            string tk = keys[a]; keys[a] = keys[b]; keys[b] = tk;
            int    tc = count[a]; count[a] = count[b]; count[b] = tc;
            double tl = lots[a]; lots[a] = lots[b]; lots[b] = tl;
            double tr = res[a]; res[a] = res[b]; res[b] = tr;
         }

   string s = "\nLe d{e'}tail, du pire au meilleur :";
   for(int k = 0; k < ArraySize(keys); k++)
      s += StringFormat("\n  - %s : %d position(s) (%.2f lot), %.2f", keys[k], count[k], lots[k], res[k]);

   string syms[];
   MarketSymbols(syms);
   string market = "";
   for(int i = 0; i < ArraySize(syms); i++)
   {
      string line = g_market.Line(syms[i]);
      if(line != "") market += "\n  - " + ShortSymbol(syms[i]) + " : " + line;
   }
   if(market != "") s += "\nLe march{e'} {a`} ce moment :" + market;
   return s;
}

double DailyDdPct(const double equity)
{
   return (g_dayOpen > 0.0) ? (g_dayOpen - equity) / g_dayOpen * 100.0 : 0.0;
}

double GivebackPct(const double equity)
{
   return (g_peak > 0.0) ? (g_peak - equity) / g_peak * 100.0 : 0.0;
}

bool TradeAllowed()
{
   return TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)
       && MQLInfoInteger(MQL_TRADE_ALLOWED)
       && AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
}

//+------------------------------------------------------------------+
//| Fermetures                                                       |
//+------------------------------------------------------------------+
void ClosePass(const string only = "")
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsMonitored(PositionGetInteger(POSITION_MAGIC))) continue;
      if(only != "" && PositionGetString(POSITION_SYMBOL) != only) continue;
      g_trade.SetTypeFillingBySymbol(PositionGetString(POSITION_SYMBOL));
      bool sent = g_trade.PositionClose(ticket);
      uint rc   = g_trade.ResultRetcode();
      if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL))
         PrintFormat("MerePoule: fermeture de %I64u refusee, %u %s", ticket, rc, g_trade.ResultRetcodeDescription());
   }
}

void DeleteOrders(const string only = "")
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsMonitored(OrderGetInteger(ORDER_MAGIC))) continue;
      if(only != "" && OrderGetString(ORDER_SYMBOL) != only) continue;
      if(!g_trade.OrderDelete(ticket) || g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
         PrintFormat("MerePoule: suppression de l'ordre %I64u refusee, %u %s",
                     ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Etat                                                             |
//+------------------------------------------------------------------+
void SetState(const MP_State s)
{
   g_state = s;
   GvSet("state", (double)s);
   if(s == MP_KILL) GvSet("kill_at", (double)TimeGMT());
   GlobalVariablesFlush();   // survit a un plantage de MT5, pas seulement a une fermeture propre
   g_statusDirty = true;
}

MP_State StoredState()
{
   int s = (int)GvGet("state", (double)MP_RUN);
   if(s == MP_KILL)  return MP_KILL;
   if(s == MP_PAUSE) return MP_PAUSE;
   return MP_RUN;
}

//+------------------------------------------------------------------+
//| Sequence d'arret. L'etat KILL est ecrit AVANT toute action : un   |
//| plantage en cours de sequence ne laisse jamais le compte en RUN.  |
//+------------------------------------------------------------------+
void Kill(const string reason, const string rule, const MP_Request &req)
{
   if(g_state == MP_KILL) return;   // idempotent : un second arret ne rearme rien
   bool wasPaused = g_state == MP_PAUSE;
   SetState(MP_KILL);
   g_lastKillAt  = MP_IsoTime(TimeGMT());
   g_lastKillWhy = MP_Fr(reason);
   g_lastKillReq = req.id;

   double equityBefore    = AccountInfoDouble(ACCOUNT_EQUITY);
   int    positionsBefore = CountPositions();
   int    ordersBefore    = CountOrders();
   UpdateMarket(true);
   string exposure     = ExposureText();   // avant de fermer : ce qui a coute
   string exposureJson = SymbolsJson();

   //--- 1. Le robot d'abord, pour qu'il ne rouvre rien. Son modele est
   //--- enregistre : RELANCER pourra le rouvrir apres le rearmement.
   int charts, saved;
   int chartsClosed = g_robot.SaveAndClose(charts, saved);

   //--- 2. Positions, trois passes au plus.
   for(int pass = 1; pass <= MP_CLOSE_PASSES && CountPositions() > 0; pass++)
   {
      if(pass > 1) Sleep(500);
      ClosePass();
   }

   //--- 3. Ordres en attente.
   DeleteOrders();

   //--- 4. Bilan : journal tout de suite, Telegram en fin de boucle.
   int    positionsLeft = CountPositions();
   int    ordersLeft    = CountOrders();
   double equityAfter   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance       = AccountInfoDouble(ACCOUNT_BALANCE);
   string msg = "ARR{E^}T D'URGENCE : la M{e`}re a tout coup{e'}\nPourquoi : " + reason + ".";
   msg += StringFormat("\nCe qu'elle a fait : robot {e'}teint (%d graphique(s) ferm{e'}(s) sur %d), %d position(s) ferm{e'}e(s) sur %d",
                       chartsClosed, charts, MathMax(0, positionsBefore - positionsLeft), positionsBefore);
   if(ordersBefore > 0)
      msg += StringFormat(", %d ordre(s) en attente supprim{e'}(s) sur %d", MathMax(0, ordersBefore - ordersLeft), ordersBefore);
   msg += StringFormat(".\nSolde maintenant : %.2f.", balance);
   if(wasPaused)
      msg += "\nLe robot {e'}tait d{e'}j{a`} en pause.";
   else if(charts == 0)
      msg += "\nATTENTION : graphique du robot introuvable. S'il rouvre des positions, la M{e`}re les refermera.";
   if(positionsLeft > 0 || ordersLeft > 0)
   {
      g_manualNeeded = true;
      msg += StringFormat("\n{A`} FAIRE : %d position(s) et %d ordre(s) n'ont pas pu {e^}tre ferm{e'}s. "
                          "La M{e`}re r{e'}essaie chaque seconde ; les fermer dans MT5 si {c,}a dure.", positionsLeft, ordersLeft);
   }
   msg += exposure;
   msg += "\nLe robot reste {e'}teint. Pour repartir : /relancer sur Telegram.";

   string fields = "\"rule\":" + MP_JsonStr(rule) + "," + RequestFields(req)
                 + ",\"charts\":" + IntegerToString(charts)
                 + ",\"charts_closed\":" + IntegerToString(chartsClosed)
                 + ",\"charts_saved\":" + IntegerToString(saved)
                 + ",\"positions\":" + IntegerToString(positionsBefore)
                 + ",\"positions_closed\":" + IntegerToString(MathMax(0, positionsBefore - positionsLeft))
                 + ",\"orders\":" + IntegerToString(ordersBefore)
                 + ",\"orders_deleted\":" + IntegerToString(MathMax(0, ordersBefore - ordersLeft))
                 + ",\"equity_before\":" + MP_JsonNum(equityBefore, 2)
                 + ",\"equity_after\":" + MP_JsonNum(equityAfter, 2)
                 + ",\"balance\":" + MP_JsonNum(balance, 2)
                 + ",\"exposure\":" + exposureJson
                 + ",\"market\":" + g_market.Json();
   Report("kill", "critical", msg, fields);
   if(charts == 0 && !wasPaused && g_robot.TargetCount() > 0)
      ReportAlert("target_missing", "Arr{e^}t sans graphique du robot {a`} fermer.", false);
   if(g_manualNeeded)
      ReportAlert("manual_intervention", StringFormat("%d position(s) et %d ordre(s) non ferm{e'}s apr{e`}s l'arr{e^}t.",
                                                      positionsLeft, ordersLeft), false);
}

//+------------------------------------------------------------------+
//| Etape 5 : en KILL, le compte reste a plat.                       |
//+------------------------------------------------------------------+
void ResolveManual()
{
   if(!g_manualNeeded) return;
   g_manualNeeded = false;
   ReportAlert("manual_resolved", "Positions restantes enfin ferm{e'}es\nLe compte n'a plus de position.");
}

//--- Un graphique du robot rouvert a la main alors que l'etat l'interdit.
void CloseRelaunchedRobot(const string why)
{
   long ids[];
   if(g_robot.RecentlyClosed() || g_robot.Find(ids) == 0) return;
   g_robot.Close(ids);
   ReportAlert("robot_relaunched", why);
}

void HoldKill()
{
   //--- Les demandes ne changent rien en KILL, mais elles sont consommees :
   //--- un kill laisse en place rearreterait tout juste apres un rearmement.
   string     content;
   MP_Request req;
   if(MP_TakeFlag(g_dir + MP_KILL_FLAG, content))
   {
      ParseRequest(content, req);
      Report("kill_ignored", "info", "Demande d'arr{e^}t (" + OriginText(req) + ") : d{e'}j{a`} en KILL.", RequestFields(req), false);
   }
   if(MP_TakeFlag(g_dir + MP_PAUSE_FLAG, content))
   {
      ParseRequest(content, req);
      Report("pause_ignored", "info", "Demande de pause (" + OriginText(req) + ") : d{e'}j{a`} en KILL.", RequestFields(req), false);
   }
   if(MP_TakeFlag(g_dir + MP_RELAUNCH_FLAG, content))
   {
      ParseRequest(content, req);
      Report("relaunch_refused", "warning", "Relance refus{e'}e (" + OriginText(req) + ")\nTout est arr{e^}t{e'} : r{e'}armer d'abord (/relancer sur Telegram).",
             RequestFields(req) + ",\"errors\":\"etat KILL\"");
   }
   if(MP_TakeFlag(g_dir + MP_ROBOT_FLAG, content))
   {
      ParseRequest(content, req);
      Report("robot_params_refused", "warning", "R{e'}glage du robot refus{e'} (" + OriginText(req) + ")\nTout est arr{e^}t{e'}, le robot est {e'}teint.",
             RequestFields(req) + ",\"errors\":\"etat KILL\"");
   }

   CloseRelaunchedRobot("Robot rallum{e'} alors que tout est arr{e^}t{e'} : la M{e`}re l'a {e'}teint\n"
                        "Pour repartir : /relancer sur Telegram.");

   int positions = CountPositions();
   int orders    = CountOrders();
   if(positions == 0 && orders == 0)
   {
      ResolveManual();
      return;
   }

   ClosePass();
   DeleteOrders();

   int positionsLeft = CountPositions();
   int ordersLeft    = CountOrders();
   if(positionsLeft == 0 && ordersLeft == 0)
   {
      if(g_manualNeeded) ResolveManual();
      else if(TimeLocal() - g_lastRepeat >= MP_REPEAT_ALERT_SEC)
      {
         g_lastRepeat = TimeLocal();
         ReportAlert("reappeared", StringFormat("Tout est arr{e^}t{e'}, mais %d position(s) et %d ordre(s) sont r{e'}apparus : la M{e`}re les a referm{e'}s.",
                                                positions, orders));
      }
   }
   else if(!g_manualNeeded)
   {
      g_manualNeeded = true;
      ReportAlert("manual_intervention",
                  StringFormat("{A`} FAIRE {A`} LA MAIN\nLe courtier refuse de fermer %d position(s) et %d ordre(s). La M{e`}re r{e'}essaie chaque seconde ; les fermer dans MT5 si {c,}a dure.",
                               positionsLeft, ordersLeft));
   }
}

//+------------------------------------------------------------------+
//| Etape 3 : rearmement. Refuse tant que le compte n'est pas a plat. |
//+------------------------------------------------------------------+
void HandleReset()
{
   string content;
   if(!MP_TakeFlag(g_dir + MP_RESET_FLAG, content)) return;
   MP_Request req;
   ParseRequest(content, req);

   if(g_state != MP_KILL)
   {
      Report("reset_ignored", "info", "Demande de r{e'}armement (" + OriginText(req) + ") : rien {a`} r{e'}armer, " + StatePlain(g_state) + ".",
             RequestFields(req), false);
      return;
   }

   int positions = CountPositions();
   int orders    = CountOrders();
   if(positions > 0 || orders > 0)
   {
      Report("reset_refused", "warning",
             StringFormat("R{e'}armement refus{e'} (%s)\n%d position(s) et %d ordre(s) sont encore ouverts : les fermer d'abord.", OriginText(req), positions, orders),
             RequestFields(req) + ",\"positions\":" + IntegerToString(positions) + ",\"orders\":" + IntegerToString(orders));
      return;
   }

   SetState(MP_RUN);
   g_peak = AccountInfoDouble(ACCOUNT_EQUITY);
   GvSet("peak", g_peak);
   g_manualNeeded = false;
   g_marginLow    = false;
   Report("reset", "info", "SURVEILLANCE R{E'}ARM{E'}E (" + OriginText(req) + ")\nLa M{e`}re surveille de nouveau. Le robot reste {e'}teint jusqu'{a`} sa relance.",
          RequestFields(req));
}

//+------------------------------------------------------------------+
//| Etape 4 : seuils envoyes a distance. Tout ou rien.               |
//+------------------------------------------------------------------+
void HandleConfig()
{
   string content;
   if(!MP_TakeFlag(g_dir + MP_CONFIG_FLAG, content)) return;
   MP_Request req;
   ParseRequest(content, req);

   MP_Config next;
   string errors = ValidateConfig(content, next);
   if(errors != "")
   {
      Report("config_refused", "warning", "Seuils REFUS{E'}S (" + OriginText(req) + ")\n" + errors,
             RequestFields(req) + ",\"errors\":" + MP_JsonStr(errors));
      return;
   }

   string diff = ConfigDiff(g_cfg, next);
   g_cfg       = next;
   g_cfgRemote = true;
   SaveOverrides();
   Report("config", "warning", "LIMITES MODIFI{E'}ES {a`} distance (" + OriginText(req) + ")\n" + diff,
          RequestFields(req) + ",\"config\":" + ConfigJson());
}

//+------------------------------------------------------------------+
//| Etape 7 : pause et relance (etats RUN et PAUSE)                  |
//+------------------------------------------------------------------+
void HandlePause()
{
   string content;
   if(!MP_TakeFlag(g_dir + MP_PAUSE_FLAG, content)) return;
   MP_Request req;
   ParseRequest(content, req);

   if(g_state == MP_PAUSE)
   {
      Report("pause_ignored", "info", "Demande de pause (" + OriginText(req) + ") : d{e'}j{a`} en PAUSE.", RequestFields(req), false);
      return;
   }

   int charts, saved;
   int closed = g_robot.SaveAndClose(charts, saved);
   SetState(MP_PAUSE);
   string msg = StringFormat("ROBOT EN PAUSE (%s)\nRobot {e'}teint (%d graphique(s) ferm{e'}(s) sur %d). Ses positions restent ouvertes et surveill{e'}es, "
                             "filet de s{e'}curit{e'} compris. RELANCER le rallume avec les m{e^}mes r{e'}glages.",
                             OriginText(req), closed, charts);
   if(charts == 0) msg += "\nAucun graphique du robot n'{e'}tait ouvert.";
   Report("pause", "warning", msg,
          RequestFields(req) + ",\"charts\":" + IntegerToString(charts)
          + ",\"charts_closed\":" + IntegerToString(closed) + ",\"charts_saved\":" + IntegerToString(saved));
}

//--- En PAUSE, RELANCER termine toujours la pause : sinon un robot sans
//--- modele enregistre ne pourrait plus jamais repartir, meme a la main.
void HandleRelaunch()
{
   string content;
   if(!MP_TakeFlag(g_dir + MP_RELAUNCH_FLAG, content)) return;
   MP_Request req;
   ParseRequest(content, req);
   string fields = RequestFields(req);

   //--- "symbols" : go-to-market par symbole (passerelle 1.31) ; absent = tous.
   string only[];
   MP_JsonStrings(content, "symbols", only);
   string which = "";
   for(int i = 0; i < ArraySize(only); i++) which += (i > 0 ? ", " : "") + ShortSymbol(only[i]);
   string requested = "[";
   for(int i = 0; i < ArraySize(only); i++) requested += (i > 0 ? "," : "") + MP_JsonStr(only[i]);
   fields += ",\"requested\":" + requested + "]";

   int    total;
   string errors;
   int    opened = g_robot.Relaunch(total, errors, only);

   if(total == 0 && g_robot.Saved() > 0)   // tout ce qui est demande tourne deja
   {
      if(g_state == MP_PAUSE) SetState(MP_RUN);
      Report("relaunch_ignored", "info", "Demande de relance (" + OriginText(req) + ") : le robot tourne d{e'}j{a`}"
             + (which != "" ? " sur " + which : "") + ".", fields, false);
      return;
   }

   if(g_state == MP_RUN && opened == 0)
   {
      string why = (total == 0) ? "la M{e`}re n'a gard{e'} aucun graphique du robot : le relancer {a`} la main" : errors;
      Report("relaunch_refused", "warning", "Relance refus{e'}e (" + OriginText(req) + ")\n" + why,
             fields + ",\"errors\":" + MP_JsonStr(why));
      return;
   }

   if(g_state == MP_PAUSE) SetState(MP_RUN);
   long ids[];
   int running = g_robot.Find(ids);
   string msg = StringFormat("ROBOT RELANC{E'} (%s)%s\n%d graphique(s) rouvert(s) sur %d : il prend ses positions lui-m{e^}me, la M{e`}re surveille.",
                             OriginText(req), which != "" ? " sur " + which : "", opened, total);
   if(which != "" && running < g_robot.Saved())
      msg += StringFormat("\nLes autres symboles restent {e'}teints (%d graphique(s) en marche sur %d).", running, g_robot.Saved());
   if(errors != "") msg += "\nPas rouverts : " + errors + "relancer le reste {a`} la main.";
   Report("relaunch", (opened < total) ? "warning" : "info", msg,
          fields + ",\"charts\":" + IntegerToString(total) + ",\"charts_reopened\":" + IntegerToString(opened));
}

//--- En PAUSE, le robot ne repart que par RELANCER.
void HoldPause()
{
   CloseRelaunchedRobot("Robot rallum{e'} {a`} la main pendant la pause : la M{e`}re l'a {e'}teint\nPour le relancer : RELANCER.");
}

//--- Reglage du robot envoye a distance : seulement en RUN (le robot doit
//--- tourner), seulement un reglage liste dans InpRobotParams, dans ses bornes.
void HandleRobotParams()
{
   string content;
   if(!MP_TakeFlag(g_dir + MP_ROBOT_FLAG, content)) return;
   MP_Request req;
   ParseRequest(content, req);
   string param  = MP_Sanitize(MP_JsonText(content, "param"), 64, true);
   string symbol = MP_Sanitize(MP_JsonText(content, "symbol"), 64, false);
   double value;
   int    r = MP_JsonNumber(content, "value", value);
   int    k = FindRobotParam(param);

   string err = "", previous = "", charts = "", errors = "";
   int    eligible = 0, changed = 0;
   if(g_state != MP_RUN)
      err = "robot coup{e'} ({e'}tat " + StateName(g_state) + ") : relancer d'abord";
   else if(k < 0)
      err = (param == "" ? "r{e'}glage absent" : param) + " non modifiable {a`} distance (InpRobotParams)";
   else if(r != 1)
      err = "valeur absente ou pas un nombre";
   else if(value < g_robotParams[k].min || value > g_robotParams[k].max)
      err = StringFormat("%s %s hors de [%s ; %s]", g_robotParams[k].label, NumberText(value),
                         NumberText(g_robotParams[k].min), NumberText(g_robotParams[k].max));
   else
   {
      changed = g_robot.SetParam(param, NumberText(value), symbol, eligible, previous, charts, errors);
      if(eligible == 0)
         err = "aucun graphique du robot n'a le r{e'}glage " + param + (symbol != "" ? " sur " + symbol : "");
      else if(changed == 0)
         err = errors;
   }

   string fields = RequestFields(req) + ",\"param\":" + MP_JsonStr(param);
   if(err != "")
   {
      Report("robot_params_refused", "warning", "R{e'}glage du robot REFUS{E'} (" + OriginText(req) + ")\n" + err,
             fields + ",\"errors\":" + MP_JsonStr(err));
      return;
   }
   string msg = StringFormat("R{E'}GLAGE DU ROBOT modifi{e'} {a`} distance (%s)\n%s (%s) : %s {->} %s sur %d graphique(s) : %s.\n"
                             "Le robot red{e'}marre avec la nouvelle valeur.",
                             OriginText(req), g_robotParams[k].label, param, previous, NumberText(value), changed, charts);
   if(errors != "") msg += "\n{E'}checs : " + errors;
   Report("robot_params", "warning", msg,
          fields + ",\"value\":" + NumberText(value) + ",\"previous\":" + MP_JsonStr(previous)
          + ",\"charts\":" + IntegerToString(eligible) + ",\"charts_changed\":" + IntegerToString(changed));
}

//+------------------------------------------------------------------+
//| Etape 8 : regles de risque. La premiere declenchee donne la      |
//| raison de l'arret.                                               |
//+------------------------------------------------------------------+
void EvaluateRules()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double floating;
   int    positions = CountPositions(floating);

   if(equity > g_peak)
   {
      g_peak = equity;
      GvSet("peak", g_peak);
   }
   double dd       = DailyDdPct(equity);
   double giveback = GivebackPct(equity);

   string reason = "", rule = "";
   double lastResort = FloatingLastResort();
   if(lastResort > 0.0 && floating <= -lastResort)
   {
      rule   = "floating_loss";
      reason = InpManualDecision
             ? StringFormat("perte en cours %.2f, au-del{a`} du dernier filet de -%.2f (aucune d{e'}cision prise {a`} -%.2f)",
                            floating, lastResort, g_cfg.maxFloatingLoss)
             : StringFormat("perte en cours %.2f, au-del{a`} de la limite de -%.2f", floating, g_cfg.maxFloatingLoss);
   }
   else if(g_cfg.maxDailyDdPct > 0.0 && dd >= g_cfg.maxDailyDdPct)
   {
      rule   = "daily_dd";
      reason = StringFormat("perte du jour %.2f %%, au-del{a`} de la limite de %.1f %% (solde du matin %.2f)",
                            dd, g_cfg.maxDailyDdPct, g_dayOpen);
   }
   else if(g_cfg.maxGivebackPct > 0.0 && giveback >= g_cfg.maxGivebackPct)
   {
      rule   = "giveback";
      reason = StringFormat("le compte a rendu %.2f %% de son plus haut du jour (%.2f), limite %.1f %%",
                            giveback, g_peak, g_cfg.maxGivebackPct);
   }
   else if(g_news.Active() && positions > 0)
   {
      rule   = "news";
      reason = "annonce {e'}conomique importante : " + g_news.Label();
   }

   //--- Decision manuelle (decision 28) : a la perte max, une alerte, pas
   //--- d'arret ; le dernier filet coupe plus loin.
   if(InpManualDecision && g_cfg.maxFloatingLoss > 0.0 && reason == "")
   {
      if(!g_decisionAlerted && floating <= -g_cfg.maxFloatingLoss)
      {
         g_decisionAlerted = true;
         ReportAlert("decision", StringFormat("D{E'}CISION {A`} PRENDRE : perte en cours %.2f\n"
                     "La M{e`}re ne coupe plus seule {a`} -%.0f : c'est toi qui d{e'}cides (/kill sur Telegram pour tout arr{e^}ter). "
                     "Elle coupera tout seule {a`} -%.0f.", floating, g_cfg.maxFloatingLoss, lastResort),
                     true, "\"floating\":" + MP_JsonNum(floating, 2) + ",\"threshold\":" + MP_JsonNum(g_cfg.maxFloatingLoss, 2));
      }
      else if(g_decisionAlerted && floating > -(g_cfg.maxFloatingLoss - 50.0))
         g_decisionAlerted = false;
   }

   //--- Marge : le niveau n'existe qu'avec au moins une position ouverte.
   double margin    = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   bool   marginLow = g_cfg.marginLevelMin > 0.0 && PositionsTotal() > 0
                   && margin > 0.0 && margin < g_cfg.marginLevelMin;
   if(marginLow && g_cfg.marginAction == MARGIN_KILL)
   {
      if(reason == "")
      {
         rule   = "margin";
         reason = StringFormat("marge trop basse : %.0f %% (limite %.0f %%)", margin, g_cfg.marginLevelMin);
      }
   }
   else if(marginLow)
   {
      if(!g_marginLow)
      {
         g_marginLow = true;
         ReportAlert("margin", StringFormat("MARGE BASSE : %.0f %% (limite %.0f %%)\nLe compte a peu de r{e'}serve pour ses %d position(s) ouverte(s). "
                                            "Simple alerte : la M{e`}re ne coupe pas pour {c,}a.", margin, g_cfg.marginLevelMin, positions));
      }
   }
   else if(g_marginLow && (PositionsTotal() == 0 || margin >= g_cfg.marginLevelMin * MP_MARGIN_REARM))
      g_marginLow = false;

   if(reason != "")
   {
      MP_Request req;
      req.id     = "";
      req.origin = "watchdog";
      req.reason = "";
      Kill(reason, rule, req);
   }
}

//+------------------------------------------------------------------+
//| Etapes 9 et 10                                                   |
//+------------------------------------------------------------------+
void UpdateShield()
{
   string alerts, hits;
   int    placed, moved, removed, hitCount;
   double hitResult;
   g_shield.Update(ShieldBudget(), alerts, placed, moved, removed, hits, hitResult, hitCount);
   if(hitCount > 0)
      ReportAlert("shield_hit",
                  StringFormat("FILET DE S{E'}CURIT{E'} TOUCH{E'} (Bouclier)\nLe courtier a ferm{e'} %d position(s) {a`} leur stop de s{e'}curit{e'}, r{e'}sultat %.2f.\n%s",
                               hitCount, hitResult, hits),
                  true, StringFormat("\"positions\":%d,\"result\":%s", hitCount, MP_JsonNum(hitResult, 2)));
   //--- Les deplacements de chaque minute ne sont pas journalises seuls :
   //--- le statut montre les positions protegees.
   if(placed + removed > 0)
      Report("shield", "info",
             StringFormat("Bouclier : %d stop loss pos{e'}(s), %d d{e'}plac{e'}(s), %d retir{e'}(s), budget %.2f sur %d groupe(s).",
                          placed, moved, removed, g_shield.Budget(), g_shield.Groups()),
             StringFormat("\"placed\":%d,\"moved\":%d,\"removed\":%d,\"budget\":%s,\"groups\":%d",
                          placed, moved, removed, MP_JsonNum(g_shield.Budget(), 2), g_shield.Groups()),
             false);
   if(alerts != "") ReportAlert("shield_failed", "FILET DE S{E'}CURIT{E'} : incident (Bouclier)\n" + alerts);
}

//+------------------------------------------------------------------+
//| Cameleon (decision 21), en observation : il ne ferme rien.        |
//+------------------------------------------------------------------+
double ChameleonThreshold()
{
   return (InpChameleonPct > 0.0 && g_cfg.maxFloatingLoss > 0.0) ? g_cfg.maxFloatingLoss * InpChameleonPct / 100.0 : 0.0;
}

double ChameleonHeavy()
{
   return (InpChameleonHeavyPct > 0.0 && g_cfg.maxFloatingLoss > 0.0) ? g_cfg.maxFloatingLoss * InpChameleonHeavyPct / 100.0 : 0.0;
}

string SideText(const bool buy) { return buy ? "achats" : "ventes"; }

string ReasonText(const string reason) { return reason == "heavy" ? "perte lourde" : reason == "reversal" ? "retournement" : "contre-tendance"; }

//--- "1 cas, la coupe aurait epargne 286.03" ; "0 cas".
string TallyText(const string reason)
{
   int    n     = g_chameleon.Episodes(reason);
   double saved = g_chameleon.SavedTotal(reason);
   if(n == 0) return "0 cas";
   return StringFormat("%d cas, la coupe aurait %s %.2f", n, saved >= 0.0 ? "{e'}pargn{e'}" : "co{u^}t{e'}", MathAbs(saved));
}

//--- Detection hors KILL ; bilan dans tous les etats : l'arret ferme aussi
//--- les groupes suivis.
void UpdateChameleon()
{
   double threshold = ChameleonThreshold();
   double heavy     = ChameleonHeavy();
   MP_Episode fresh[];
   if(g_state != MP_KILL) g_chameleon.Detect(g_market, threshold, heavy, fresh);
   for(int i = 0; i < ArraySize(fresh); i++)
   {
      MP_Episode e = fresh[i];
      string move = MP_MoveText(e.trend, e.chg4h) + " (" + MP_PctText(e.chg4h) + " en 4 h)";
      string why  = (e.reason == "heavy")
                  ? StringFormat("ce groupe perd plus de %.2f, quelle que soit la tendance (march{e'} : %s, %s).", heavy, move, MP_MoodText(e.mood))
                  : (e.reason == "reversal")
                  ? "forte bougie M5 contre le robot (retournement)."
                  : StringFormat("le march{e'} %s alors que le robot %s (%s).", move, e.buy ? "ach{e`}te" : "vend", MP_MoodText(e.mood));
      //--- Retournement : la passerelle l'annonce avec ses boutons ; ici, le journal seul.
      bool tg = e.reason != "reversal";
      Report("chameleon", "info",
             StringFormat("CAM{E'}L{E'}ON (essai, rien n'est ferm{e'})\nIl aurait coup{e'} les %s sur %s : %d position(s), %.2f.\n"
                          "Pourquoi : %s\nBilan quand ces positions seront ferm{e'}es.",
                          SideText(e.buy), ShortSymbol(e.symbol), e.positions, e.cut, why),
             "\"mode\":\"observe\",\"reason\":" + MP_JsonStr(e.reason) + ",\"symbol\":" + MP_JsonStr(e.symbol)
             + ",\"side\":" + MP_JsonStr(e.buy ? "buy" : "sell")
             + ",\"positions\":" + IntegerToString(e.positions)
             + ",\"volume\":" + MP_JsonNum(e.volume, 2)
             + ",\"floating\":" + MP_JsonNum(e.cut, 2)
             + ",\"threshold\":" + MP_JsonNum(e.reason == "heavy" ? heavy : threshold, 2)
             + ",\"trend\":" + MP_JsonStr(e.trend)
             + ",\"chg_4h_pct\":" + MP_JsonNum(e.chg4h, 2)
             + ",\"volatility\":" + MP_JsonStr(e.mood), tg);
   }

   MP_Episode done[];
   g_chameleon.Settle(done);
   for(int i = 0; i < ArraySize(done); i++)
   {
      MP_Episode e = done[i];
      double saved = e.cut - e.actual;   // positif : la coupe aurait epargne
      double total = g_chameleon.SavedTotal();
      string by    = (g_state == MP_KILL) ? "ferm{e'}s par l'arr{e^}t" : "ferm{e'}s par le robot";
      Report("chameleon_outcome", "info",
             StringFormat("CAM{E'}L{E'}ON, bilan (%s) : les %s sur %s\n"
                          "S'il avait coup{e'} {a`} %s GMT : %.2f.\n"
                          "Sans coupe, %s {a`} %s GMT : %.2f.\n"
                          "{->} Couper aurait %s %.2f.\n"
                          "Depuis le d{e'}but : contre-tendance %s ; perte lourde %s ; retournement %s.",
                          ReasonText(e.reason), SideText(e.buy), ShortSymbol(e.symbol), TimeToString(e.atGmt, TIME_MINUTES), e.cut,
                          by, TimeToString(e.closedGmt, TIME_MINUTES), e.actual,
                          saved >= 0.0 ? "{e'}pargn{e'}" : "co{u^}t{e'}", MathAbs(saved),
                          TallyText("trend"), TallyText("heavy"), TallyText("reversal")),
             "\"mode\":\"observe\",\"reason\":" + MP_JsonStr(e.reason) + ",\"symbol\":" + MP_JsonStr(e.symbol)
             + ",\"side\":" + MP_JsonStr(e.buy ? "buy" : "sell")
             + ",\"cut_result\":" + MP_JsonNum(e.cut, 2)
             + ",\"actual_result\":" + MP_JsonNum(e.actual, 2)
             + ",\"saved\":" + MP_JsonNum(saved, 2)
             + ",\"closed_by\":" + MP_JsonStr(g_state == MP_KILL ? "kill" : "robot")
             + ",\"duration_s\":" + IntegerToString((long)(e.closedGmt - e.atGmt))
             + ",\"episodes\":" + IntegerToString(g_chameleon.Episodes())
             + ",\"saved_total\":" + MP_JsonNum(total, 2));
   }
}

//--- Les regles en clair, pour le message de demarrage.
string RulesPlain()
{
   string s = "Elle coupe tout si :";
   int    n = 0;
   if(g_cfg.maxFloatingLoss > 0.0)
   {
      s += InpManualDecision
         ? StringFormat("\n  - les positions ouvertes perdent plus de %.2f (dernier filet ; {a`} -%.2f, c'est toi qui d{e'}cides)",
                        FloatingLastResort(), g_cfg.maxFloatingLoss)
         : StringFormat("\n  - les positions ouvertes perdent plus de %.2f", g_cfg.maxFloatingLoss);
      n++;
   }
   if(g_cfg.maxDailyDdPct > 0.0)
   { s += StringFormat("\n  - la perte du jour d{e'}passe %.1f %%", g_cfg.maxDailyDdPct); n++; }
   if(g_cfg.maxGivebackPct > 0.0)
   { s += StringFormat("\n  - le compte rend plus de %.1f %% de son plus haut du jour", g_cfg.maxGivebackPct); n++; }
   if(g_news.Enabled())
   { s += "\n  - une annonce {e'}conomique importante arrive (" + InpNewsCurrencies + ") avec des positions ouvertes"; n++; }
   if(g_cfg.marginLevelMin > 0.0 && g_cfg.marginAction == MARGIN_KILL)
   { s += StringFormat("\n  - la marge passe sous %.0f %%", g_cfg.marginLevelMin); n++; }
   if(n == 0) s = "ATTENTION : aucune r{e`}gle d'arr{e^}t active.";
   if(g_cfg.marginLevelMin > 0.0 && g_cfg.marginAction != MARGIN_KILL)
      s += StringFormat("\nElle pr{e'}vient, sans couper, si la marge passe sous %.0f %%.", g_cfg.marginLevelMin);
   s += (ShieldBudget() > 0.0)
      ? StringFormat("\nFilet de s{e'}curit{e'} chez le courtier (Bouclier) : %.2f au plus si l'ordinateur tombe.", ShieldBudget())
      : "\nATTENTION : filet de s{e'}curit{e'} (Bouclier) d{e'}sactiv{e'}.";
   if(ChameleonThreshold() > 0.0 || ChameleonHeavy() > 0.0)
      s += StringFormat("\nCam{e'}l{e'}on (essai, ne ferme rien) : signale un groupe qui perd plus de %.2f contre le march{e'}, ou plus de %.2f.",
                        ChameleonThreshold(), ChameleonHeavy());
   for(int i = 0; i < ArraySize(g_robotParams); i++)
      s += StringFormat("\nR{e'}glable {a`} distance : %s du robot, entre %s et %s.",
                        g_robotParams[i].label, NumberText(g_robotParams[i].min), NumberText(g_robotParams[i].max));
   if(InpPauseMisaligned)
      s += "\nElle {e'}teint le robot sur un symbole sans position quand ta r{e`}gle y est au rouge.";
   if(InpPauseCounter)
      s += "\nElle met le robot en pause sur un symbole qui part en contre-tendance (M5, et M30 ou H1) : ses positions restent ouvertes.";
   if(InpJumpLateMin > 0)
      s += StringFormat("\nL{a`} o{u`} tu as choisi la r{e`}gle saut, elle met le robot en pause quand aucun saut n'est venu depuis %d min : "
                        "ses positions restent ouvertes.", InpJumpLateMin);
   string syms[], modes = "";
   MarketSymbols(syms);
   for(int i = 0; i < ArraySize(syms); i++)
      modes += (i > 0 ? ", " : "") + ShortSymbol(syms[i]) + " : " + MP_ModePlain(g_market.ModeOf(syms[i]));
   if(modes != "")
      s += "\nR{e`}gle par symbole (/regles sur Telegram pour la changer) : " + modes + ".";
   if(g_cfgRemote)         s += "\n(limites modifi{e'}es {a`} distance)";
   if(InpMagicFilter != 0) s += "\nSeules les positions du robot (magic " + IntegerToString(InpMagicFilter) + ") sont surveill{e'}es.";
   return s;
}

//--- Positions et ordres surveilles sur un symbole.
int CountSymbol(const string symbol, int &positions, double &floating)
{
   positions = 0;
   floating  = 0.0;
   int orders = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0 && IsMonitored(PositionGetInteger(POSITION_MAGIC)) && PositionGetString(POSITION_SYMBOL) == symbol)
      {
         positions++;
         floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) != 0 && IsMonitored(OrderGetInteger(ORDER_MAGIC)) && OrderGetString(ORDER_SYMBOL) == symbol) orders++;
   return positions + orders;
}

//--- Pause par symbole, selon la regle choisie pour lui (decision 30) :
//---  - regle au rouge et symbole a plat : robot eteint, modele garde
//---    (decision 28) ; une grille ouverte va a son terme ;
//---  - tendance : contre-tendance confirmee, positions gardees (1.33) ;
//---  - saut : aucun saut depuis InpJumpLateMin, positions gardees (1.34).
//--- Aucune regle : jamais de pause. Le go-to-market par symbole le
//--- rallumera quand la regle repassera au vert.
void PauseMisaligned()
{
   if(g_state != MP_RUN || g_robot.RecentlyClosed()) return;
   long ids[];
   int n = g_robot.Find(ids);
   for(int i = 0; i < n; i++)
   {
      string sym = ChartSymbol(ids[i]);
      MP_Market m;
      int    positions;
      double floating;
      if(!g_market.Get(sym, m) || m.want == 0 || m.mode == MP_MODE_NONE) continue;
      int  busy    = CountSymbol(sym, positions, floating);
      bool flat    = InpPauseMisaligned && !m.go && busy == 0;
      bool counter = InpPauseCounter && MP_ModeTrend(m.mode) && m.counter && positions > 0;
      bool late    = MP_ModeJump(m.mode) && m.late && positions > 0;
      if(!flat && !counter && !late) continue;
      int found, saved;
      int closed = g_robot.SaveAndClose(found, saved, sym);
      if(closed <= 0) continue;
      string trends = StringFormat("M5 %s, M30 %s, H1 %s", MP_TrendName(m.m5), MP_TrendName(m.m30), MP_TrendName(m.h1));
      string kept   = StringFormat("Robot {e'}teint sur ce symbole, ses %d position(s) restent ouvertes (r{e'}sultat en cours %.2f) : "
                                   "il n'y ajoute plus rien. La M{e`}re proposera de le rallumer quand ta r{e`}gle repassera au vert ; "
                                   "l'arr{e^}t d'urgence reste ta d{e'}cision.", positions, floating);
      string msg, reason;
      if(flat)
      {
         reason = "flat";
         msg = StringFormat("PAUSE SUR %s : %s et le robot n'y a plus de position.\n"
                            "Robot {e'}teint sur ce symbole ; la M{e`}re proposera de le rallumer quand ta r{e`}gle repassera au vert.",
                            ShortSymbol(sym), CMarket::RuleText(m));
      }
      else if(counter)
      {
         reason = "counter";
         msg = StringFormat("PAUSE SUR %s : le march{e'} va contre le robot (%s).\n%s", ShortSymbol(sym), trends, kept);
      }
      else
      {
         reason = "late";
         msg = StringFormat("PAUSE SUR %s : %s (d'habitude, il en vient un toutes les 15 min environ).\n%s",
                            ShortSymbol(sym), MP_JumpText(m.jumpAge), kept);
      }
      Report("symbol_pause", flat ? "info" : "warning", msg,
             "\"symbol\":" + MP_JsonStr(sym) + ",\"charts_closed\":" + IntegerToString(closed)
             + ",\"positions\":" + IntegerToString(positions) + ",\"floating\":" + MP_JsonNum(floating, 2)
             + ",\"reason\":" + MP_JsonStr(reason) + ",\"mode\":" + MP_JsonStr(MP_ModeName(m.mode)));
      return;   // Find a change : un symbole par boucle
   }
}

//--- Regle choisie pour un symbole (decision 30), depuis Telegram ou l'app.
//--- Gardee dans une variable globale du terminal : un redemarrage ne la
//--- perd pas. Acceptee dans tous les etats : c'est un reglage.
string ModeHelp(const int mode)
{
   if(mode == MP_MODE_JUMP)
      return StringFormat("Le robot y tourne tant qu'un saut est venu il y a moins de %d min ; sinon, pause.", g_market.LateMin());
   if(mode == MP_MODE_BOTH)
      return StringFormat("Il y faut les deux : M5, et M30 ou H1, dans le sens du robot, et un saut il y a moins de %d min.", g_market.LateMin());
   if(mode == MP_MODE_NONE)
      return "Aucun filtre : le robot y tourne tout le temps ; seules les protections sur les pertes jouent.";
   return "Le robot y tourne quand M5, et M30 ou H1, vont dans son sens.";
}

void HandleRuleMode()
{
   string content;
   if(!MP_TakeFlag(g_dir + MP_RULES_FLAG, content)) return;
   MP_Request req;
   ParseRequest(content, req);
   string sym    = MP_Sanitize(MP_JsonText(content, "symbol"), 64, false);
   string name   = MP_Sanitize(MP_JsonText(content, "mode"), 16, true);
   int    mode   = MP_ModeFromName(name);
   string fields = RequestFields(req) + ",\"symbol\":" + MP_JsonStr(sym) + ",\"mode\":" + MP_JsonStr(name);
   bool   custom;
   string err = "";
   if(sym == "" || !SymbolExist(sym, custom)) err = "symbole inconnu : " + sym;
   else if(mode < 0)                          err = "r{e`}gle inconnue : " + name + " (trend, jump, both ou none)";
   if(err != "")
   {
      Report("rule_mode_refused", "warning", "Choix de r{e`}gle REFUS{E'} (" + OriginText(req) + ")\n" + err,
             fields + ",\"errors\":" + MP_JsonStr(MP_Fr(err)));
      return;
   }
   int previous = g_market.ModeOf(sym);
   g_market.SetMode(sym, mode);
   UpdateMarket(true);
   Report("rule_mode", "info",
          StringFormat("R{E`}GLE DE %s : %s (%s, avant : %s)\n%s", ShortSymbol(sym), MP_ModePlain(mode), OriginText(req),
                       MP_ModePlain(previous), ModeHelp(mode)),
          fields + ",\"previous\":" + MP_JsonStr(MP_ModeName(previous)));
}

//--- Coupe d'un seul symbole, demandee depuis l'alerte de retournement
//--- (decision 28) : robot eteint dessus, ses positions et ordres fermes ;
//--- les autres symboles continuent.
void HandleCut()
{
   string content;
   if(!MP_TakeFlag(g_dir + MP_CUT_FLAG, content)) return;
   MP_Request req;
   ParseRequest(content, req);
   string sym    = MP_Sanitize(MP_JsonText(content, "symbol"), 64, false);
   string fields = RequestFields(req) + ",\"symbol\":" + MP_JsonStr(sym);
   if(sym == "" || g_state == MP_KILL)
   {
      string why = (sym == "") ? "symbole manquant" : "tout est d{e'}j{a`} arr{e^}t{e'}";
      Report("symbol_cut_refused", "warning", "Coupe refus{e'}e (" + OriginText(req) + ") : " + why + ".",
             fields + ",\"errors\":" + MP_JsonStr(MP_Fr(why)));
      return;
   }
   int    before;
   double floating;
   CountSymbol(sym, before, floating);
   int found, saved;
   int charts = g_robot.SaveAndClose(found, saved, sym);
   int left = before;
   for(int pass = 1; pass <= MP_CLOSE_PASSES && left > 0; pass++)
   {
      if(pass > 1) Sleep(500);
      ClosePass(sym);
      double f;
      CountSymbol(sym, left, f);
   }
   DeleteOrders(sym);
   double f2;
   int positionsLeft;
   int pending = CountSymbol(sym, positionsLeft, f2) - positionsLeft;
   string msg = StringFormat("SYMBOLE COUP{E'} : %s (%s)\n%d position(s) ferm{e'}e(s) sur %d, r{e'}sultat environ %.2f. "
                             "Robot {e'}teint sur ce symbole (%d graphique(s)) ; les autres continuent.",
                             ShortSymbol(sym), OriginText(req), before - positionsLeft, before, floating, charts);
   if(positionsLeft > 0 || pending > 0)
      msg += StringFormat("\n{A`} FAIRE : %d position(s) et %d ordre(s) n'ont pas pu {e^}tre ferm{e'}s ; les fermer dans MT5.", positionsLeft, pending);
   Report("symbol_cut", (positionsLeft > 0 || pending > 0) ? "warning" : "info", msg,
          fields + ",\"positions\":" + IntegerToString(before) + ",\"positions_closed\":" + IntegerToString(before - positionsLeft)
          + ",\"charts_closed\":" + IntegerToString(charts) + ",\"result\":" + MP_JsonNum(floating, 2));
}

void RefreshNews()
{
   bool ok = g_news.Refresh(TimeTradeServer());
   if(!ok && !g_newsDown)
   {
      g_newsDown = true;
      ReportAlert("calendar_down", "Calendrier {e'}conomique indisponible\nLa M{e`}re ne voit plus les annonces {a`} venir ; ses autres protections continuent.");
   }
   else if(ok && g_newsDown)
   {
      g_newsDown = false;
      Print("MerePoule: calendrier economique retabli");
   }
}

//+------------------------------------------------------------------+
//| Jour serveur, statut, trading autorise                           |
//+------------------------------------------------------------------+
long ServerDay() { return (long)(TimeTradeServer() / 86400); }

//--- Premier demarrage du jour : solde actuel moins le resultat des
//--- deals deja clotures depuis minuit serveur. Le drawdown compte
//--- ainsi les pertes du jour meme si l'EA est pose en cours de journee.
double DayOpenFromHistory(const long day)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!HistorySelect((datetime)(day * 86400), TimeTradeServer() + 3600)) return balance;

   double result = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      long type = HistoryDealGetInteger(deal, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;   // hors depots et retraits
      result += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
              + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
   }
   return balance - result;
}

//--- Etape 1
void UpdateDay()
{
   long day = ServerDay();
   if(day == g_day) return;
   g_day     = day;
   g_dayOpen = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peak    = AccountInfoDouble(ACCOUNT_EQUITY);
   GvSet("day", (double)g_day);
   GvSet("day_open", g_dayOpen);
   GvSet("peak", g_peak);
   MP_RotateEvents(g_dir);
   PrintFormat("MerePoule: nouveau jour serveur, solde d'ouverture %.2f", g_dayOpen);
}

//--- Etape 2, et de nouveau en fin de boucle apres un evenement.
void WriteStatus()
{
   g_statusDirty = false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double floating;
   int    positions = CountPositions(floating);
   long   ids[];
   bool   percent   = AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE) == ACCOUNT_STOPOUT_MODE_PERCENT;

   string s = "{\"v\":2"
            + ",\"ts\":" + MP_JsonStr(MP_IsoTime(TimeGMT()))
            + ",\"account\":" + IntegerToString(g_account)
            + ",\"label\":" + MP_JsonStr(InpLabel)
            + ",\"watchdog\":" + MP_JsonStr(MP_VERSION)
            + ",\"state\":" + MP_JsonStr(StateName(g_state))
            + ",\"connected\":" + MP_JsonBool(TerminalInfoInteger(TERMINAL_CONNECTED) != 0)
            + ",\"algo_trading\":" + MP_JsonBool(TradeAllowed())
            + ",\"equity\":" + MP_JsonNum(equity, 2)
            + ",\"balance\":" + MP_JsonNum(AccountInfoDouble(ACCOUNT_BALANCE), 2)
            + ",\"floating\":" + MP_JsonNum(floating, 2)
            + ",\"margin_level\":" + MP_JsonNum(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), 1)
            + ",\"margin_call_level\":" + MP_JsonNum(AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL), 1)
            + ",\"stop_out_level\":" + MP_JsonNum(AccountInfoDouble(ACCOUNT_MARGIN_SO_SO), 1)
            + ",\"stop_out_mode\":" + MP_JsonStr(percent ? "percent" : "money")
            + ",\"day_open_balance\":" + MP_JsonNum(g_dayOpen, 2)
            + ",\"daily_dd_pct\":" + MP_JsonNum(DailyDdPct(equity), 2)
            + ",\"peak_equity\":" + MP_JsonNum(g_peak, 2)
            + ",\"giveback_pct\":" + MP_JsonNum(GivebackPct(equity), 2)
            + ",\"positions\":" + IntegerToString(positions)
            + ",\"pending_orders\":" + IntegerToString(CountOrders())
            + ",\"symbols\":" + SymbolsJson()
            + ",\"target_charts\":" + IntegerToString(g_robot.Find(ids))
            + ",\"targets\":" + g_robot.TargetsJson()
            + ",\"saved_charts\":" + IntegerToString(g_robot.Saved())
            + ",\"saved_symbols\":" + g_robot.SavedJson()
            + ",\"robot_params\":" + RobotParamsJson()
            + ",\"market\":" + g_market.Json()
            + ",\"chameleon\":" + g_chameleon.Json(InpChameleonPct, ChameleonThreshold(), InpChameleonHeavyPct, ChameleonHeavy())
            + ",\"shield\":" + g_shield.Json()
            + ",\"events_seq\":" + IntegerToString(g_seq)
            + ",\"news\":{\"active\":" + MP_JsonBool(g_news.Active()) + ",\"label\":" + MP_JsonStrOrNull(g_news.Label()) + "}"
            + ",\"last_kill\":{\"at\":" + MP_JsonStrOrNull(g_lastKillAt)
            + ",\"reason\":" + MP_JsonStrOrNull(g_lastKillWhy)
            + ",\"request_id\":" + MP_JsonStrOrNull(g_lastKillReq) + "}"
            + ",\"config\":" + ConfigJson()
            + "}\n";
   if(!MP_WriteAtomic(g_dir + MP_STATUS, s)) IoError("statut non ecrit");
}

//--- Sans trading automatique, le Watchdog ne peut plus rien fermer.
void CheckAlgoTrading()
{
   bool allowed = TradeAllowed();
   if(!allowed && !g_algoOff)
   {
      g_algoOff = true;
      ReportAlert("algo_off", "ATTENTION : MT5 interdit le trading automatique\n"
                              "La M{e`}re ne pourrait plus fermer les positions en cas de danger. R{e'}activer le bouton \"Algo Trading\" en haut de MT5.");
   }
   else if(allowed && g_algoOff)
   {
      g_algoOff = false;
      ReportAlert("algo_on", "Trading automatique r{e'}tabli\nLa M{e`}re peut de nouveau fermer les positions.");
   }
}

//+------------------------------------------------------------------+
//| Demarrage : attend un compte connecte avant de charger l'etat,   |
//| sinon le solde d'ouverture du jour serait lu a zero.             |
//+------------------------------------------------------------------+
double ChartFingerprint(const long id) { return (double)(id % 1000000007); }

//--- Un Watchdog par compte : deux instances doubleraient les alertes
//--- et se disputeraient les drapeaux.
bool AcquireLock(string &holder)
{
   holder = "";
   string lock = GvName("lock");
   if(GlobalVariableCheck(lock))
   {
      double fp = GlobalVariableGet(lock);
      for(long id = ChartFirst(); id >= 0; id = ChartNext(id))
      {
         if(id == ChartID() || ChartFingerprint(id) != fp) continue;
         if(ChartGetString(id, CHART_EXPERT_NAME) != MQLInfoString(MQL_PROGRAM_NAME)) continue;
         holder = ChartSymbol(id) + " " + EnumToString(ChartPeriod(id));
         return false;
      }
      //--- Porteur disparu (fermeture brutale) : le verrou est orphelin.
   }
   GlobalVariableSet(lock, ChartFingerprint(ChartID()));
   g_lockOwned = true;
   return true;
}

void ReleaseLock()
{
   if(!g_lockOwned) return;
   string lock = GvName("lock");
   if(GlobalVariableCheck(lock) && GlobalVariableGet(lock) == ChartFingerprint(ChartID()))
      GlobalVariableDel(lock);
   g_lockOwned = false;
}

//--- Le statut precedent donne l'heure de la derniere surveillance et
//--- le dernier arret, qui survivent ainsi au redemarrage.
void RecoverPrevious()
{
   string prev = MP_ReadText(g_dir + MP_STATUS);
   g_prevStatusTs = MP_ParseIso(MP_JsonText(prev, "ts"));
   int at = StringFind(prev, "\"last_kill\"");
   if(at < 0) return;
   g_lastKillAt  = MP_JsonText(prev, "at", at);
   g_lastKillWhy = MP_JsonText(prev, "reason", at);
   g_lastKillReq = MP_JsonText(prev, "request_id", at);
}

//--- "Machine redemarree" si la machine a demarre apres le dernier
//--- statut, sinon "Surveillance reprise" (MT5 ou l'EA seul).
void ReportRestart()
{
   if(g_prevStatusTs <= 0) return;
   long down = (long)(TimeGMT() - g_prevStatusTs);
   if(down < MP_RESTART_MIN_SEC) return;

   long   up     = (long)(GetTickCount64() / 1000);
   bool   reboot = up < down;
   double floating;
   int    positions = CountPositions(floating);
   string msg = reboot
                ? StringFormat("L'ORDINATEUR A RED{E'}MARR{E'}\nLa M{e`}re n'a pas surveill{e'} pendant %s (derni{e`}res nouvelles le %s). "
                               "L'ordinateur est rallum{e'} depuis %s.", Duration(down), TimePlain(g_prevStatusTs), Duration(up))
                : StringFormat("LA M{E`}RE REPREND LA SURVEILLANCE\nElle n'a pas surveill{e'} pendant %s (derni{e`}res nouvelles le %s) : "
                               "MT5 ou elle-m{e^}me {e'}taient arr{e^}t{e'}s.", Duration(down), TimePlain(g_prevStatusTs));
   msg += StringFormat("\nMaintenant : %s, %d position(s) ouverte(s), r{e'}sultat en cours %.2f.", StatePlain(g_state), positions, floating);
   ReportAlert("restarted", msg, true,
               "\"downtime_s\":" + IntegerToString(down) + ",\"machine_reboot\":" + MP_JsonBool(reboot));
}

bool Prepare()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return false;
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(login == 0) return false;

   g_account = login;
   g_gv      = "MerePoule." + IntegerToString(login) + ".";
   g_dir     = MP_Dir(login);

   string holder;
   if(!AcquireLock(holder))
   {
      string m = MP_Fr("MerePoule surveille d{e'}j{a`} ce compte depuis " + holder + ". Cette instance se retire.");
      Print("MerePoule: ", m);
      Alert(m);
      ExpertRemove();
      return false;
   }

   MP_CreateDir(login);
   MP_RotateEvents(g_dir);
   FileDelete("merepoule_heartbeat.txt", FILE_COMMON);   // reste du contrat v1 (Watchdog 1.10)
   g_robot.SetAccount(login);
   g_shield.Init(g_gv, InpMagicFilter);
   g_chameleon.Init(g_gv, login, InpMagicFilter);
   g_market.Init(InpMagicFilter, g_gv, InpJumpLateMin);

   g_seq   = (long)GvGet("seq", 0);
   g_state = StoredState();
   RecoverPrevious();
   LoadConfig();

   long   today  = ServerDay();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if((long)GvGet("day", -1) == today)
   {
      g_day     = today;
      g_dayOpen = GvGet("day_open", AccountInfoDouble(ACCOUNT_BALANCE));
      g_peak    = MathMax(GvGet("peak", equity), equity);
   }
   else
   {
      g_day     = today;
      g_dayOpen = DayOpenFromHistory(today);
      g_peak    = equity;
      GvSet("day", (double)g_day);
      GvSet("day_open", g_dayOpen);
   }
   GvSet("peak", g_peak);

   long ids[];
   int  charts = g_robot.Find(ids);
   bool demo   = AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO;
   string robotLine;
   if(g_state == MP_KILL)
      robotLine = "Tout est arr{e^}t{e'} depuis le " + IsoPlain(g_lastKillAt) + " : le robot reste {e'}teint. Pour repartir : /relancer sur Telegram.";
   else if(g_state == MP_PAUSE)
      robotLine = "Robot en pause : il ne repart que par RELANCER.";
   else if(charts > 0)
      robotLine = StringFormat("Robot en marche sur %d graphique(s).", charts);
   else
      robotLine = "Robot {e'}teint (aucun graphique du robot ouvert).";
   string m = StringFormat("LA M{E`}RE VEILLE (version %s)\nCompte %I64d, %s (%s).\n%s\n%s\nSolde %.2f.",
                           MP_VERSION, login, demo ? "d{e'}mo" : "ARGENT R{E'}EL", AccountInfoString(ACCOUNT_SERVER),
                           robotLine, RulesPlain(), AccountInfoDouble(ACCOUNT_BALANCE));
   if(g_robot.TargetCount() == 0)
      m += "\nATTENTION : aucun robot {a`} surveiller n'est indiqu{e'} dans ses r{e'}glages : un arr{e^}t ne pourra pas l'{e'}teindre.";
   else if(charts == 0 && g_state == MP_RUN)
      Print("MerePoule: graphique du robot introuvable. EA poses : ", g_robot.ExpertsOnCharts());
   if(!g_telegram.Enabled())
      Print("MerePoule: Telegram non configure, alertes dans le journal Experts seulement");

   g_ready = true;
   Report("start", "info", m, "\"state\":" + MP_JsonStr(StateName(g_state)) + ",\"version\":" + MP_JsonStr(MP_VERSION));
   ReportRestart();
   if(g_robot.TargetCount() > 0 && charts == 0 && g_state == MP_RUN)
      ReportAlert("target_missing", "Graphique du robot introuvable au d{e'}marrage.", false);
   if(ShieldBudget() <= 0.0)
      ReportAlert("shield_off", InpShield ? "Bouclier inactif : ni budget ni seuil de perte flottante."
                                          : "Bouclier d{e'}sactiv{e'} dans les param{e`}tres.", false);
   return true;
}

void ShowStatus()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double floating;
   int    positions = CountPositions(floating);
   long   ids[];
   string shield = !g_shield.Active() ? "INACTIF"
                 : StringFormat("actif, budget %.2f sur %d groupe(s), %d/%d position(s) prot{e'}g{e'}e(s)",
                                g_shield.Budget(), g_shield.Groups(), g_shield.Protected(),
                                g_shield.Protected() + g_shield.Unprotected());
   Comment(MP_Fr(StringFormat("MerePoule %s   %s   %s%s\n"
                              "Equity %.2f   Solde %.2f   Flottant %.2f\n"
                              "DD jour %.2f %%   Recul %.2f %%   Marge %.1f %%\n"
                              "Positions %d   Ordres %d   Graphiques du robot %d\n"
                              "Seuils %s : %s\n"
                              "Bouclier : %s\n"
                              "Annonce : %s",
                              MP_VERSION, InpLabel != "" ? InpLabel : IntegerToString(g_account), StateName(g_state),
                              TerminalInfoInteger(TERMINAL_CONNECTED) ? "" : "   D{E'}CONNECT{E'}",
                              equity, AccountInfoDouble(ACCOUNT_BALANCE), floating,
                              DailyDdPct(equity), GivebackPct(equity), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),
                              positions, CountOrders(), g_robot.Find(ids),
                              g_cfgRemote ? "{a`} distance" : "locaux", RulesSummary(), shield,
                              !g_news.Enabled() ? "r{e`}gle d{e'}sactiv{e'}e" : g_news.Active() ? g_news.Label() : "aucune")));
}

//+------------------------------------------------------------------+
//| Evenements                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("MerePoule se teste sur un compte demo, pas dans le Strategy Tester.");
      return INIT_FAILED;
   }

   //--- Un changement de parametres ne decharge pas l'EA : tout repart
   //--- de l'etat persistant, relu par Prepare().
   g_ready        = false;
   g_marginLow    = false;
   g_manualNeeded = false;
   g_newsDown     = false;
   g_algoOff      = false;

   g_robot.Init(InpTargetExperts);
   ParseRobotParams();
   g_telegram.Init(InpTelegramToken, InpTelegramChatId);
   g_news.Init(InpNewsCurrencies, InpNewsBeforeMin, InpNewsAfterMin);
   g_trade.SetDeviationInPoints(MP_CLOSE_DEVIATION);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   if(!EventSetTimer(1))
   {
      PrintFormat("MerePoule: timer indisponible, err=%d", GetLastError());
      return INIT_FAILED;
   }
   Comment("MerePoule : en attente du compte");
   return INIT_SUCCEEDED;
}

void OnTimer()
{
   if(!g_ready && !Prepare()) return;

   UpdateDay();                                       // 1
   UpdateMarket();
   WriteStatus();                                     // 2
   CheckAlgoTrading();
   HandleReset();                                     // 3
   HandleConfig();                                    // 4
   HandleRuleMode();
   if(g_state == MP_KILL)
      HoldKill();                                     // 5
   else
   {
      string     content;
      MP_Request req;
      if(MP_TakeFlag(g_dir + MP_KILL_FLAG, content))  // 6
      {
         ParseRequest(content, req);
         Kill("arr{e^}t demand{e'} " + OriginText(req) + (req.reason != "" ? " : " + req.reason : ""),
              "manual", req);
      }
      else
      {
         HandlePause();                               // 7
         HandleRelaunch();
         HandleRobotParams();
         HandleCut();
         if(g_state == MP_PAUSE) HoldPause();
         EvaluateRules();                             // 8
         if(g_state == MP_RUN) PauseMisaligned();
         if(g_state != MP_KILL)
         {
            if(g_state == MP_RUN) g_robot.UpdateInputs();
            UpdateShield();                           // 9
            if(g_news.Due(TimeTradeServer()))
               RefreshNews();                         // 10
         }
      }
   }

   UpdateChameleon();                                 // 9b

   if(g_statusDirty) WriteStatus();
   ShowStatus();
   FlushOutbox(MP_TG_TIMEOUT_MS);
}

//--- La surveillance tourne sur le timer.
void OnTick() {}

string DeinitReasonText(const int reason)
{
   switch(reason)
   {
      case REASON_REMOVE:     return "retir{e'}e de son graphique";
      case REASON_CHARTCLOSE: return "son graphique a {e'}t{e'} ferm{e'}";
      case REASON_CLOSE:      return "MT5 a {e'}t{e'} ferm{e'}";
      case REASON_ACCOUNT:    return "changement de compte dans MT5";
      case REASON_TEMPLATE:   return "mod{e`}le appliqu{e'} {a`} son graphique";
      case REASON_PROGRAM:    return "arr{e^}t{e'}e par le programme";
   }
   return "code " + IntegerToString(reason);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   if(!g_ready) return;
   ReleaseLock();

   //--- Rechargement immediat : le message de demarrage suivra.
   if(reason != REASON_PARAMETERS && reason != REASON_RECOMPILE && reason != REASON_CHARTCHANGE)
      Report("stop", "critical",
             StringFormat("LA M{E`}RE NE SURVEILLE PLUS (%s)\nPlus aucune protection automatique tant qu'elle n'est pas remise sur son graphique dans MT5. "
                          "{E'}tat gard{e'} : %s.", DeinitReasonText(reason), StatePlain(g_state)),
             "\"cause\":" + MP_JsonStr(MP_Fr(DeinitReasonText(reason))));
   FlushOutbox(MP_TG_DEINIT_MS);
}
