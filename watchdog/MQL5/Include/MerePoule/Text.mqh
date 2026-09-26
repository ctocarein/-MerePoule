//+------------------------------------------------------------------+
//| Text.mqh                                                         |
//| Texte lisible pour Telegram, le journal et le graphique.         |
//|                                                                  |
//| Les sources restent en ASCII (aucun doute d'encodage a la        |
//| compilation) : les accents s'ecrivent avec une notation courte,  |
//| convertie par MP_Fr en vrais caracteres Unicode.                 |
//|   {e'} e aigu   {e`} e grave   {e^} e circonflexe  {a`} a grave  |
//|   {c,} c cedille  {u`} u grave  {o^} o circonflexe  {i^} i circ. |
//|   {E'} E aigu   {E^} E circ.   {A`} A grave                      |
//|   {->} fleche   {<=} inferieur ou egal   {>=} superieur ou egal  |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_TEXT_MQH
#define MEREPOULE_TEXT_MQH

string MP_Fr(const string s)
{
   if(StringFind(s, "{") < 0) return s;
   string out = s;
   StringReplace(out, "{e'}", ShortToString(0x00E9));
   StringReplace(out, "{e`}", ShortToString(0x00E8));
   StringReplace(out, "{e^}", ShortToString(0x00EA));
   StringReplace(out, "{a`}", ShortToString(0x00E0));
   StringReplace(out, "{a^}", ShortToString(0x00E2));
   StringReplace(out, "{c,}", ShortToString(0x00E7));
   StringReplace(out, "{u`}", ShortToString(0x00F9));
   StringReplace(out, "{u^}", ShortToString(0x00FB));
   StringReplace(out, "{i^}", ShortToString(0x00EE));
   StringReplace(out, "{o^}", ShortToString(0x00F4));
   StringReplace(out, "{E'}", ShortToString(0x00C9));
   StringReplace(out, "{E^}", ShortToString(0x00CA));
   StringReplace(out, "{E`}", ShortToString(0x00C8));
   StringReplace(out, "{A`}", ShortToString(0x00C0));
   StringReplace(out, "{->}", ShortToString(0x2192));
   StringReplace(out, "{<=}", ShortToString(0x2264));
   StringReplace(out, "{>=}", ShortToString(0x2265));
   return out;
}

//--- Pour le mode HTML de Telegram : seuls <, > et & sont a proteger.
string MP_HtmlEscape(const string s)
{
   string out = s;
   StringReplace(out, "&", "&amp;");
   StringReplace(out, "<", "&lt;");
   StringReplace(out, ">", "&gt;");
   return out;
}

//--- Icones des messages Telegram, en entites HTML numeriques.
#define MP_ICON_CHICK    "&#x1F425;"
#define MP_ICON_START    "&#x1F7E2;"
#define MP_ICON_STOP     "&#x1F534;"
#define MP_ICON_KILL     "&#x1F6D1;"
#define MP_ICON_RESET    "&#x1F513;"
#define MP_ICON_PAUSE    "&#x23F8;&#xFE0F;"
#define MP_ICON_RELAUNCH "&#x25B6;&#xFE0F;"
#define MP_ICON_CONFIG   "&#x2699;&#xFE0F;"
#define MP_ICON_UNDO     "&#x21A9;&#xFE0F;"
#define MP_ICON_ROBOT    "&#x1F916;"
#define MP_ICON_REFUSED  "&#x26D4;"
#define MP_ICON_WARNING  "&#x26A0;&#xFE0F;"
#define MP_ICON_SHIELD   "&#x1F6E1;&#xFE0F;"
#define MP_ICON_RESTART  "&#x1F504;"
#define MP_ICON_OK       "&#x2705;"
#define MP_ICON_SOS      "&#x1F198;"
#define MP_ICON_INFO     "&#x2139;&#xFE0F;"
#define MP_ICON_CHAMELEON "&#x1F98E;"
#define MP_ICON_ALARM    "&#x1F6A8;"

string MP_IconFor(const string type, const string code)
{
   if(type == "start")    return MP_ICON_START;
   if(type == "stop")     return MP_ICON_STOP;
   if(type == "kill")     return MP_ICON_KILL;
   if(type == "reset")    return MP_ICON_RESET;
   if(type == "pause")    return MP_ICON_PAUSE;
   if(type == "relaunch") return MP_ICON_RELAUNCH;
   if(type == "config")   return MP_ICON_CONFIG;
   if(type == "config_cleared") return MP_ICON_UNDO;
   if(type == "robot_params")   return MP_ICON_ROBOT;
   if(type == "symbol_pause")   return MP_ICON_PAUSE;
   if(type == "symbol_cut")     return MP_ICON_KILL;
   if(type == "rule_mode")      return MP_ICON_CONFIG;
   if(StringFind(type, "chameleon") == 0) return MP_ICON_CHAMELEON;
   if(StringFind(type, "_refused") > 0) return MP_ICON_REFUSED;
   if(type == "alert")
   {
      if(code == "shield_hit" || code == "shield_failed" || code == "shield_off") return MP_ICON_SHIELD;
      if(code == "restarted")           return MP_ICON_RESTART;
      if(code == "algo_on" || code == "manual_resolved") return MP_ICON_OK;
      if(code == "manual_intervention") return MP_ICON_SOS;
      if(code == "decision")            return MP_ICON_ALARM;
      if(code == "algo_off")            return MP_ICON_REFUSED;
      return MP_ICON_WARNING;
   }
   return MP_ICON_INFO;
}

//--- Bloc Telegram d'un message : icone, premiere ligne en gras, suite en clair.
string MP_TelegramBlock(const string icon, const string text)
{
   string body  = MP_HtmlEscape(text);
   int    nl    = StringFind(body, "\n");
   string title = (nl < 0) ? body : StringSubstr(body, 0, nl);
   string rest  = (nl < 0) ? "" : StringSubstr(body, nl);
   return icon + " <b>" + title + "</b>" + rest;
}

#endif // MEREPOULE_TEXT_MQH
