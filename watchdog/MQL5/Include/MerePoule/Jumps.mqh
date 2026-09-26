//+------------------------------------------------------------------+
//| Jumps.mqh                                                        |
//| Les sauts des indices synthetiques (decision 30). PainX monte    |
//| doucement puis chute d'un coup ; GainX baisse puis bondit. Le    |
//| robot (vente PainX, achat GainX) attend le saut : c'est lui qui  |
//| le paie, et entre deux sauts il perd forcement un peu.           |
//|                                                                  |
//| Un saut : bougie M1 dont le mouvement dans le sens voulu depasse |
//| 8 fois le corps median des 24 h precedentes (chute pour une      |
//| vente, bond pour un achat).                                      |
//|                                                                  |
//| Meme code pour la Mere en direct et pour le Lecteur : le         |
//| comparatif juge exactement ce qu'elle applique.                  |
//+------------------------------------------------------------------+
#ifndef MEREPOULE_JUMPS_MQH
#define MEREPOULE_JUMPS_MQH

#define MP_JUMP_FACTOR      8.0
#define MP_JUMP_MEDIAN_BARS 1440    // corps median : 24 h de bougies M1
#define MP_JUMP_MEDIAN_MIN  60      // moins de bougies : pas de saut reconnu
#define MP_JUMP_LOOKBACK    720     // en direct : dernier saut cherche sur 12 h

//--- Corps median (|cloture - ouverture|) des bougies [from, to[ d'une
//--- serie chronologique ; 0 sans bougie.
double MP_MedianBody(const MqlRates &r[], const int from, const int to)
{
   int a = MathMax(0, from);
   int n = MathMin(ArraySize(r), to) - a;
   if(n <= 0) return 0.0;
   double v[];
   ArrayResize(v, n);
   for(int i = 0; i < n; i++) v[i] = MathAbs(r[a + i].close - r[a + i].open);
   ArraySort(v);
   return (n % 2 == 1) ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2.0;
}

//--- La bougie est-elle un saut dans le sens voulu (want -1 : chute, 1 : bond) ?
bool MP_IsJump(const MqlRates &bar, const int want, const double median)
{
   if(median <= 0.0 || want == 0) return false;
   if(want < 0) return bar.low - bar.open < -MP_JUMP_FACTOR * median;
   return bar.high - bar.open > MP_JUMP_FACTOR * median;
}

//--- Sauts d'une serie M1 chronologique : jump[i] vrai si la bougie i en
//--- est un. Corps median recalcule toutes les 60 bougies, sur les 1440
//--- precedentes.
void MP_JumpSeries(const MqlRates &r[], const int want, bool &jump[])
{
   int n = ArraySize(r);
   ArrayResize(jump, n);
   double median = 0.0;
   for(int i = 0; i < n; i++)
   {
      if(i % 60 == 0) median = MP_MedianBody(r, i - MP_JUMP_MEDIAN_BARS, i);
      jump[i] = i >= MP_JUMP_MEDIAN_MIN && MP_IsJump(r[i], want, median);
   }
}

//--- Minutes entre la fin de la bougie du saut et t.
int MP_JumpMinutes(const MqlRates &bar, const datetime t)
{
   return (int)MathMax(0, (long)(t - bar.time - 60) / 60);
}

//--- En direct : minutes depuis le dernier saut (bougie en cours comprise) ;
//--- MP_JUMP_LOOKBACK si aucun sur 12 h, -1 si les bougies manquent.
int MP_JumpAge(const string symbol, const int want)
{
   if(want == 0) return -1;
   MqlRates r[];
   int n = CopyRates(symbol, PERIOD_M1, 0, MP_JUMP_MEDIAN_BARS + MP_JUMP_LOOKBACK, r);   // chronologique
   if(n < MP_JUMP_MEDIAN_BARS / 2) return -1;
   double median = MP_MedianBody(r, n - 1 - MP_JUMP_MEDIAN_BARS, n - 1);
   datetime now = MathMax(TimeCurrent(), r[n - 1].time);
   for(int i = n - 1; i >= 0 && i >= n - MP_JUMP_LOOKBACK; i--)
      if(MP_IsJump(r[i], want, median)) return MP_JumpMinutes(r[i], now);
   return MP_JUMP_LOOKBACK;
}

//--- "dernier saut il y a 12 min", "aucun saut depuis plus de 12 h".
string MP_JumpText(const int age)
{
   if(age < 0) return "sauts inconnus";
   if(age >= MP_JUMP_LOOKBACK) return StringFormat("aucun saut depuis plus de %d h", MP_JUMP_LOOKBACK / 60);
   if(age == 0) return "saut il y a moins d'une minute";
   return StringFormat("dernier saut il y a %d min", age);
}

#endif // MEREPOULE_JUMPS_MQH
