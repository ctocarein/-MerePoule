//+------------------------------------------------------------------+
//| Telegram.mqh                                                     |
//| Canal d'alerte direct du Watchdog, independant de la passerelle. |
//|                                                                  |
//| WebRequest exige l'URL https://api.telegram.org dans             |
//| Outils > Options > Expert Advisors > "Autoriser WebRequest".     |
//| L'appel bloque jusqu'au delai donne : ne jamais l'appeler avant  |
//| une fermeture de position.                                       |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_TELEGRAM_MQH
#define MEREPOULE_TELEGRAM_MQH

#include "Json.mqh"

class CTelegram
{
private:
   string m_token;
   string m_chatId;
   bool   m_hintShown;

public:
   CTelegram() : m_token(""), m_chatId(""), m_hintShown(false) {}

   void Init(const string token, const string chatId)
   {
      m_token  = token;
      m_chatId = chatId;
      StringTrimLeft(m_token);  StringTrimRight(m_token);
      StringTrimLeft(m_chatId); StringTrimRight(m_chatId);
   }

   bool Enabled() const { return m_token != "" && m_chatId != ""; }

   //--- html : message en mode HTML de Telegram ; plain : le meme en texte
   //--- brut, envoye si Telegram refuse le HTML (HTTP 400).
   bool Send(const string html, const string plain, const int timeoutMs)
   {
      if(!Enabled()) return false;
      int code = Post(html, true, timeoutMs);
      if(code == 400) code = Post(plain, false, timeoutMs);
      return code == 200;
   }

private:
   //--- Code HTTP, ou -1 si la requete n'est pas partie. N'ecrit jamais
   //--- l'URL dans le journal : elle contient le jeton.
   int Post(const string text, const bool html, const int timeoutMs)
   {
      string url  = "https://api.telegram.org/bot" + m_token + "/sendMessage";
      string body = "{\"chat_id\":" + MP_JsonStr(m_chatId) + ",\"text\":" + MP_JsonStr(text)
                  + (html ? ",\"parse_mode\":\"HTML\"" : "")
                  + ",\"disable_web_page_preview\":true}";

      char data[];
      int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      ArrayResize(data, n - 1);   // sans le zero final

      char   result[];
      string headers;
      ResetLastError();
      int code = WebRequest("POST", url, "Content-Type: application/json\r\n", timeoutMs, data, result, headers);
      if(code == -1)
      {
         int err = GetLastError();
         if(err == 4014 && !m_hintShown)
         {
            Print("MerePoule: Telegram refuse par MT5. Ajouter https://api.telegram.org dans "
                  "Outils > Options > Expert Advisors > Autoriser WebRequest.");
            m_hintShown = true;
         }
         else if(err != 4014)
            PrintFormat("MerePoule: Telegram injoignable, err=%d", err);
         return -1;
      }
      if(code != 200)
         PrintFormat("MerePoule: Telegram HTTP %d : %s", code, CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8));
      return code;
   }
};

#endif // MEREPOULE_TELEGRAM_MQH
