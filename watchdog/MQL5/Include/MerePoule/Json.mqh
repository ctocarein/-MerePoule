//+------------------------------------------------------------------+
//| Json.mqh                                                         |
//| Le strict necessaire pour le contrat v2 : ecrire du JSON, et     |
//| lire les cles d'un objet plat (les demandes de la passerelle).   |
//| Pas un parseur general : pas de tableaux, pas d'objets imbriques |
//| cote lecture, sauf a partir d'une position donnee.               |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_JSON_MQH
#define MEREPOULE_JSON_MQH

//+------------------------------------------------------------------+
//| Ecriture                                                         |
//+------------------------------------------------------------------+
string MP_JsonEscape(const string s)
{
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(c == '\\')      out += "\\\\";
      else if(c == '"')  out += "\\\"";
      else if(c == '\n') out += "\\n";
      else if(c == '\r') continue;
      else if(c == '\t') out += "\\t";
      else if(c < 0x20)  out += StringFormat("\\u%04x", c);
      else               out += ShortToString(c);
   }
   return out;
}

string MP_JsonStr(const string s)       { return "\"" + MP_JsonEscape(s) + "\""; }
string MP_JsonStrOrNull(const string s) { return (s == "") ? "null" : MP_JsonStr(s); }
string MP_JsonBool(const bool b)        { return b ? "true" : "false"; }
string MP_JsonNum(const double v, const int digits) { return DoubleToString(v, digits); }

//--- "2026-09-24T13:46:57Z" ; t est une heure GMT.
string MP_IsoTime(const datetime t)
{
   string s = TimeToString(t, TIME_DATE | TIME_SECONDS);   // 2026.09.24 13:46:57
   StringReplace(s, ".", "-");
   StringReplace(s, " ", "T");
   return s + "Z";
}

//--- Inverse de MP_IsoTime ; 0 si illisible.
datetime MP_ParseIso(const string iso)
{
   if(StringLen(iso) < 19) return 0;
   string s = StringSubstr(iso, 0, 19);   // 2026-09-24T13:46:57
   StringReplace(s, "-", ".");
   StringReplace(s, "T", " ");
   return StringToTime(s);
}

//+------------------------------------------------------------------+
//| Lecture                                                          |
//+------------------------------------------------------------------+
bool MP_IsSpace(const ushort c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

int MP_HexValue(const ushort c)
{
   if(c >= '0' && c <= '9') return c - '0';
   if(c >= 'a' && c <= 'f') return c - 'a' + 10;
   if(c >= 'A' && c <= 'F') return c - 'A' + 10;
   return -1;
}

//--- Valeur de la premiere cle key trouvee a partir de from. value
//--- recoit le texte decode d'une chaine, ou le jeton brut (nombre,
//--- true, false, null) ; isString dit lequel. false si absente.
bool MP_JsonGet(const string json, const string key, string &value, bool &isString, const int from = 0)
{
   value    = "";
   isString = false;
   string pattern = "\"" + key + "\"";
   int len = StringLen(json);
   int pos = StringFind(json, pattern, from);
   while(pos >= 0)
   {
      int i = pos + StringLen(pattern);
      while(i < len && MP_IsSpace(StringGetCharacter(json, i))) i++;
      if(i < len && StringGetCharacter(json, i) == ':')
      {
         i++;
         while(i < len && MP_IsSpace(StringGetCharacter(json, i))) i++;
         if(i >= len) return false;

         if(StringGetCharacter(json, i) == '"')
         {
            isString = true;
            for(i++; i < len; i++)
            {
               ushort c = StringGetCharacter(json, i);
               if(c == '"') return true;
               if(c != '\\' || i + 1 >= len) { value += ShortToString(c); continue; }
               ushort e = StringGetCharacter(json, ++i);
               if(e == 'n')      value += "\n";
               else if(e == 't') value += "\t";
               else if(e == 'r') value += "\r";
               else if(e == 'u' && i + 4 < len)
               {
                  int code = 0;
                  for(int k = 1; k <= 4; k++) code = code * 16 + MathMax(0, MP_HexValue(StringGetCharacter(json, i + k)));
                  value += ShortToString((ushort)code);
                  i += 4;
               }
               else value += ShortToString(e);   // \" \\ \/
            }
            return false;   // chaine non terminee
         }

         int start = i;
         while(i < len)
         {
            ushort c = StringGetCharacter(json, i);
            if(c == ',' || c == '}' || c == ']' || MP_IsSpace(c)) break;
            i++;
         }
         value = StringSubstr(json, start, i - start);
         return value != "";
      }
      //--- Suivi d'autre chose que ':' : ce n'etait pas une cle.
      pos = StringFind(json, pattern, pos + 1);
   }
   return false;
}

//--- Texte d'une cle chaine ; "" si absente, null ou d'un autre type.
string MP_JsonText(const string json, const string key, const int from = 0)
{
   string value;
   bool   isString;
   if(!MP_JsonGet(json, key, value, isString, from) || !isString) return "";
   return value;
}

//--- -1 absente (ou null), 0 presente mais pas un nombre, 1 lue dans out.
int MP_JsonNumber(const string json, const string key, double &out)
{
   out = 0.0;
   string value;
   bool   isString;
   if(!MP_JsonGet(json, key, value, isString)) return -1;
   if(!isString && value == "null") return -1;
   if(isString) return 0;

   bool digit = false;
   for(int i = 0; i < StringLen(value); i++)
   {
      ushort c = StringGetCharacter(value, i);
      if(c >= '0' && c <= '9') { digit = true; continue; }
      if(c != '-' && c != '+' && c != '.' && c != 'e' && c != 'E') return 0;
   }
   if(!digit) return 0;
   out = StringToDouble(value);
   return 1;
}

//--- Texte venu de l'exterieur, avant de l'ecrire dans un journal.
//--- strict : identifiants seulement (lettres, chiffres, - _ : . @).
string MP_Sanitize(const string s, const int maxLen, const bool strict)
{
   string out = "";
   int n = MathMin(StringLen(s), maxLen);
   for(int i = 0; i < n; i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(strict)
      {
         bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                || c == '-' || c == '_' || c == ':' || c == '.' || c == '@';
         if(ok) out += ShortToString(c);
      }
      else out += (c < 0x20) ? " " : ShortToString(c);
   }
   return out;
}

#endif // MEREPOULE_JSON_MQH

//--- Tableau de chaines d'un objet JSON plat : "cle":["a","b"]. Vide si
//--- absent ou mal forme. Les chaines ne sont pas dechappees (symboles).
int MP_JsonStrings(const string json, const string key, string &out[])
{
   ArrayResize(out, 0);
   string tag = "\"" + key + "\"";
   int k = StringFind(json, tag);
   if(k < 0) return 0;
   int colon = StringFind(json, ":", k + StringLen(tag));
   int open  = StringFind(json, "[", k);
   if(colon < 0 || open < 0 || open < colon) return 0;
   string gap = StringSubstr(json, colon + 1, open - colon - 1);
   StringTrimLeft(gap);
   StringTrimRight(gap);
   if(gap != "") return 0;   // "[" qui n'appartient pas a cette cle
   int close = StringFind(json, "]", open);
   if(close < 0) return 0;
   string body = StringSubstr(json, open + 1, close - open - 1);
   int pos = 0;
   while(true)
   {
      int a = StringFind(body, "\"", pos);
      if(a < 0) break;
      int b = StringFind(body, "\"", a + 1);
      if(b < 0) break;
      int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = StringSubstr(body, a + 1, b - a - 1);
      pos = b + 1;
   }
   return ArraySize(out);
}
