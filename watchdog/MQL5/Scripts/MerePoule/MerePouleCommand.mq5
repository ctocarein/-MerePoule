//+------------------------------------------------------------------+
//| MerePouleCommand.mq5                                             |
//| Depose une demande pour le Watchdog du compte connecte, comme le |
//| fera la passerelle (contrat v2). Sert tant que la passerelle et  |
//| l'app n'existent pas : glisser le script sur n'importe quel      |
//| graphique du terminal.                                           |
//|                                                                  |
//| Aucune commande par defaut : un script glisse puis valide sans   |
//| rien choisir ne fait rien (le 25/09, un STOP par defaut a mis le |
//| compte a plat par erreur).                                       |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <MerePoule\Contract.mqh>

enum MP_Command
{
   CMD_NONE     = 0,   // -- choisir une commande --
   CMD_KILL     = 1,   // STOP : arret d'urgence, compte mis a plat
   CMD_PAUSE    = 2,   // PAUSE : robot coupe, positions gardees
   CMD_RELAUNCH = 3,   // RELANCER : rouvre les graphiques du robot
   CMD_RESET    = 4    // RESET : rearmement apres un arret
};

input MP_Command InpCommand = CMD_NONE;   // Commande
input string     InpReason  = "";         // Motif (facultatif, recopie dans le journal)

void OnStart()
{
   if(InpCommand == CMD_NONE)
   {
      Print("MerePoule: aucune commande choisie, rien depose");
      return;
   }
   long account = AccountInfoInteger(ACCOUNT_LOGIN);
   if(account == 0)
   {
      Print("MerePoule: aucun compte connecte, rien depose");
      return;
   }

   string flag = MP_KILL_FLAG;
   if(InpCommand == CMD_PAUSE)    flag = MP_PAUSE_FLAG;
   if(InpCommand == CMD_RELAUNCH) flag = MP_RELAUNCH_FLAG;
   if(InpCommand == CMD_RESET)    flag = MP_RESET_FLAG;

   string path = MP_Dir(account) + flag;
   string id   = MP_NewRequestId();
   string body = "{\"request_id\":" + MP_JsonStr(id) + ",\"origin\":\"script\",\"reason\":" + MP_JsonStr(InpReason) + "}\n";

   MP_CreateDir(account);
   if(MP_WriteAtomic(path, body))
      PrintFormat("MerePoule: %s depose pour le compte %I64d (request_id %s), applique dans la seconde", path, account, id);
   else
      PrintFormat("MerePoule: depot de %s impossible, err=%d", path, GetLastError());
}
