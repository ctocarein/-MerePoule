//+------------------------------------------------------------------+
//| Contract.mqh                                                     |
//| Contrat Watchdog <-> Passerelle, v2. Reference :                 |
//| docs/MerePoule_Architecture.md, section "Contrat", et contract/. |
//|                                                                  |
//| Un sous-dossier par compte dans le dossier commun de MT5         |
//| (FILE_COMMON) : Terminal\Common\Files\MerePoule\<compte>\.       |
//|  - seul l'ecrivain designe cree un fichier                       |
//|  - seul son destinataire supprime un drapeau : le Watchdog, ou   |
//|    le Lecteur pour compare.flag                                  |
//|  - statut et drapeaux : fichier temporaire puis renommage, pour  |
//|    qu'un lecteur ne voie jamais un fichier a moitie ecrit        |
//|  - journal : ajout seul ; une ligne sans \n final est en cours   |
//|    d'ecriture                                                    |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_CONTRACT_MQH
#define MEREPOULE_CONTRACT_MQH

#include "Json.mqh"

#define MP_STATUS          "status.json"      // Watchdog -> passerelle, chaque seconde
#define MP_EVENTS          "events.jsonl"     // Watchdog -> passerelle, une ligne par evenement
#define MP_EVENTS_OLD      "events.1.jsonl"   // journal precedent, apres rotation
#define MP_KILL_FLAG       "kill.flag"        // passerelle -> Watchdog : arret
#define MP_RESET_FLAG      "reset.flag"       // passerelle -> Watchdog : rearmement
#define MP_PAUSE_FLAG      "pause.flag"       // passerelle -> Watchdog : robot en pause
#define MP_RELAUNCH_FLAG   "relaunch.flag"    // passerelle -> Watchdog : relance du robot
#define MP_ROBOT_FLAG      "robot.flag"       // passerelle -> Watchdog : reglage du robot
#define MP_CONFIG_FLAG     "config.flag"      // passerelle -> Watchdog : seuils
#define MP_CUT_FLAG        "cut.flag"         // passerelle -> Watchdog : couper un symbole (1.32)
#define MP_RULES_FLAG      "rules.flag"       // passerelle -> Watchdog : regle choisie pour un symbole (1.34)
#define MP_COMPARE_FLAG    "compare.flag"     // passerelle -> Lecteur : comparatif des regles (supprime par le Lecteur)
#define MP_LECTEUR_FILE    "lecteur.json"     // Lecteur -> passerelle : le comparatif
#define MP_EVENTS_MAX_SIZE 5242880            // 5 Mo

string MP_Dir(const long account) { return "MerePoule\\" + IntegerToString(account) + "\\"; }

bool MP_CreateDir(const long account)
{
   FolderCreate("MerePoule", FILE_COMMON);
   return FolderCreate("MerePoule\\" + IntegerToString(account), FILE_COMMON);
}

//--- Ecrit le contenu en UTF-8, sans BOM, puis renomme sur le nom final.
bool MP_WriteAtomic(const string path, const string content)
{
   string tmp = path + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE) return false;

   uchar bytes[];
   int n = StringToCharArray(content, bytes, 0, WHOLE_ARRAY, CP_UTF8) - 1;   // sans le zero final
   if(n > 0) FileWriteArray(h, bytes, 0, n);
   FileClose(h);

   return FileMove(tmp, FILE_COMMON, path, FILE_COMMON | FILE_REWRITE);
}

//--- Ajoute une ligne (terminee par \n) en une seule ecriture.
bool MP_AppendLine(const string path, const string line)
{
   int h = FileOpen(path, FILE_READ | FILE_WRITE | FILE_BIN | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return false;

   uchar bytes[];
   int n = StringToCharArray(line, bytes, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   FileSeek(h, 0, SEEK_END);
   uint written = (n > 0) ? FileWriteArray(h, bytes, 0, n) : 0;
   FileClose(h);
   return (int)written == n;
}

//--- Contenu d'un fichier texte UTF-8, 64 Ko au plus ; "" si absent.
string MP_ReadText(const string path)
{
   int h = FileOpen(path, FILE_READ | FILE_BIN | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE) return "";
   ulong size = MathMin(FileSize(h), (ulong)65536);
   uchar bytes[];
   uint n = (size > 0) ? FileReadArray(h, bytes, 0, (int)size) : 0;
   FileClose(h);
   return (n > 0) ? CharArrayToString(bytes, 0, (int)n, CP_UTF8) : "";
}

//--- Cote Watchdog : lit la demande puis supprime le drapeau. Une
//--- demande ne s'applique qu'une fois, meme refusee.
bool MP_TakeFlag(const string path, string &content)
{
   content = "";
   if(!FileIsExist(path, FILE_COMMON)) return false;
   content = MP_ReadText(path);
   if(!FileDelete(path, FILE_COMMON))
      PrintFormat("MerePoule: %s non supprime, err=%d", path, GetLastError());
   return true;
}

//--- Au-dela de 5 Mo, le journal devient events.1.jsonl (l'ancien est ecrase).
void MP_RotateEvents(const string dir)
{
   string path = dir + MP_EVENTS;
   int h = FileOpen(path, FILE_READ | FILE_BIN | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE) return;
   ulong size = FileSize(h);
   FileClose(h);
   if(size > MP_EVENTS_MAX_SIZE && !FileMove(path, FILE_COMMON, dir + MP_EVENTS_OLD, FILE_COMMON | FILE_REWRITE))
      PrintFormat("MerePoule: rotation du journal impossible, err=%d", GetLastError());
}

//--- UUID v4 pour les demandes deposees depuis MT5 (script).
string MP_NewRequestId()
{
   MathSrand((int)(GetMicrosecondCount() ^ (ulong)TimeLocal()));
   string hex = "0123456789abcdef";
   string id  = "";
   for(int i = 0; i < 32; i++)
   {
      int v = MathRand() % 16;
      if(i == 12) v = 4;                 // version 4
      if(i == 16) v = 8 + v % 4;         // variante RFC 4122
      id += StringSubstr(hex, v, 1);
      if(i == 7 || i == 11 || i == 15 || i == 19) id += "-";
   }
   return id;
}

#endif // MEREPOULE_CONTRACT_MQH
