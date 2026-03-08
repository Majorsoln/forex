//+------------------------------------------------------------------+
//|                                        InstitutionalExitManager  |
//|                     V2.0 - EXIT BUILDER ONLY (H1 SL, M15 TP)     |
//| Responsibilities:
//|  - Build SL from H1 structure (risk truth)
//|  - Build TP from M15 micro structure (execution target)
//| Must NOT:
//|  - Register/manage positions
//|  - Trailing, BE, partial closes
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"

#include "MasterSignalGenerator.mqh" // for ENUM_SIGNAL_DIR

struct ExitParams
{
   bool   is_valid;
   double sl_price;
   double tp_price;
   double sl_pips;
   string sl_rule;
   string tp_rule;
};

class CExitManager
{
private:
   // Config
   int    m_h1_lookback;      // bars to scan for structure points
   int    m_m15_lookback;
   double m_sl_buffer_pips;   // extra buffer beyond structure
   double m_min_rr;           // minimum reward:risk
   double m_min_sl_pips;      // minimum SL distance
   double m_min_tp_pips;      // minimum TP distance
   double m_spread_buffer_pips; // extra TP buffer beyond spread

   // Helpers
   double PipSize(const string symbol) const;
   double PriceToPips(const string symbol, const double price_distance) const;
   double FindNearestSupport(const string symbol, const ENUM_TIMEFRAMES tf, const double from_price) const;
   double FindNearestResistance(const string symbol, const ENUM_TIMEFRAMES tf, const double from_price) const;
   double MinStopDistancePrice(const string symbol) const;
   double NormalizePrice(const string symbol, const double price) const;

public:
   CExitManager()
   {
      m_h1_lookback = 240;   // ~10 days of H1
      m_m15_lookback = 400;  // ~4 days of M15
      m_sl_buffer_pips = 3.0;
      m_min_rr = 1.20;
      m_min_sl_pips = 2.0;
      m_min_tp_pips = 2.0;
      m_spread_buffer_pips = 0.5;
   }

   void SetLookbacks(const int h1_bars, const int m15_bars)
   {
      m_h1_lookback  = MathMax(80, h1_bars);
      m_m15_lookback = MathMax(120, m15_bars);
   }

   void SetSLBufferPips(const double pips)
   {
      m_sl_buffer_pips = MathMax(0.0, pips);
   }

   
   void SetSanityParams(const double min_rr, const double min_sl_pips, const double min_tp_pips, const double spread_buffer_pips)
   {
      m_min_rr = MathMax(0.0, min_rr);
      m_min_sl_pips = MathMax(0.0, min_sl_pips);
      m_min_tp_pips = MathMax(0.0, min_tp_pips);
      m_spread_buffer_pips = MathMax(0.0, spread_buffer_pips);
   }
bool BuildExits(const string symbol, const ENUM_SIGNAL_DIR dir, const double entry_price, ExitParams &out)
   {
      out.is_valid = false;
      out.sl_price = 0.0;
      out.tp_price = 0.0;
      out.sl_pips  = 0.0;
      out.sl_rule  = "";
      out.tp_rule  = "";

      if(dir == SIGNAL_NONE || entry_price <= 0.0) return false;

      // --- SL from H1 structure ---
      if(dir == SIGNAL_BUY)
      {
         double sup = FindNearestSupport(symbol, PERIOD_H1, entry_price);
         if(sup <= 0.0)
            return false;
         out.sl_price = sup - (m_sl_buffer_pips * PipSize(symbol));
         out.sl_rule  = "H1_NEAREST_SUPPORT";
      }
      else if(dir == SIGNAL_SELL)
      {
         double res = FindNearestResistance(symbol, PERIOD_H1, entry_price);
         if(res <= 0.0)
            return false;
         out.sl_price = res + (m_sl_buffer_pips * PipSize(symbol));
         out.sl_rule  = "H1_NEAREST_RESISTANCE";
      }

      // sl_pips for RiskManager
      out.sl_pips = PriceToPips(symbol, MathAbs(entry_price - out.sl_price));
      if(out.sl_pips <= 0.5) // sanity
         return false;

      // --- TP from M15 micro structure ---
      if(dir == SIGNAL_BUY)
      {
         double res15 = FindNearestResistance(symbol, PERIOD_M15, entry_price);
         if(res15 <= 0.0)
            return false;
         out.tp_price = res15;
         out.tp_rule  = "M15_NEAREST_RESISTANCE";
      }
      else
      {
         double sup15 = FindNearestSupport(symbol, PERIOD_M15, entry_price);
         if(sup15 <= 0.0)
            return false;
         out.tp_price = sup15;
         out.tp_rule  = "M15_NEAREST_SUPPORT";
      }


      // -----------------------
      // SANITY & BROKER CHECKS
      // -----------------------
      const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      const double pip = PipSize(symbol);
      const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

      const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(bid <= 0.0 || ask <= 0.0) return false;

      const double spread_price = MathMax(0.0, ask - bid);
      const double spread_pips  = (pip > 0.0 ? spread_price / pip : 0.0);
      const double spread_buffer_pips = MathMax(0.0, spread_pips) + m_spread_buffer_pips;

      // Directional correctness + minimum distances
      const double sl_dist_pips = PriceToPips(symbol, MathAbs(entry_price - out.sl_price));
      const double tp_dist_pips = PriceToPips(symbol, MathAbs(out.tp_price - entry_price));

      if(sl_dist_pips < m_min_sl_pips) return false;
      if(tp_dist_pips < m_min_tp_pips) return false;

      if(dir == SIGNAL_BUY)
      {
         if(!(out.sl_price < entry_price)) return false;
         if(!(out.tp_price > entry_price)) return false;

         // TP must clear spread + buffer
         if(tp_dist_pips <= spread_buffer_pips) return false;
      }
      else if(dir == SIGNAL_SELL)
      {
         if(!(out.sl_price > entry_price)) return false;
         if(!(out.tp_price < entry_price)) return false;

         if(tp_dist_pips <= spread_buffer_pips) return false;
      }

      // Minimum RR
      const double rr = (sl_dist_pips > 0.0 ? tp_dist_pips / sl_dist_pips : 0.0);
      if(rr < m_min_rr) return false;

      // Broker stop/freeze levels (distance from current price)
      const double min_stop = MinStopDistancePrice(symbol);
      // Use execution-side reference price
      const double ref = (dir == SIGNAL_BUY ? bid : ask);
      if(MathAbs(ref - out.sl_price) < min_stop) return false;
      if(MathAbs(ref - out.tp_price) < min_stop) return false;

      // Normalize prices
      out.sl_price = NormalizePrice(symbol, out.sl_price);
      out.tp_price = NormalizePrice(symbol, out.tp_price);
      out.sl_pips  = sl_dist_pips;

      out.is_valid = true;
      return true;
   }
};

// --------------------
// Helpers
// --------------------
double CExitManager::PipSize(const string symbol) const
{
   // For most FX: 5-digit/3-digit brokers => pip = 10 points
   // For 4-digit/2-digit => pip = 1 point
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5) return point * 10.0;
   return point;
}

double CExitManager::PriceToPips(const string symbol, const double price_distance) const
{
   const double pip = PipSize(symbol);
   if(pip <= 0.0) return 0.0;
   return price_distance / pip;
}

// Nearest swing-low style support below price
// Simple local-min rule: low[i] < low[i-1] && low[i] < low[i+1]
// We pick the closest level strictly below from_price.
double CExitManager::FindNearestSupport(const string symbol, const ENUM_TIMEFRAMES tf, const double from_price) const
{
   const int lookback = (tf == PERIOD_H1 ? m_h1_lookback : m_m15_lookback);
   if(Bars(symbol, tf) < lookback + 5) return 0.0;

   double lows[];
   if(CopyLow(symbol, tf, 1, lookback, lows) < lookback) return 0.0;

   double best = 0.0;
   double best_dist = DBL_MAX;

   // indices: lows[0] = bar shift 1 (last closed)
   for(int i=1; i<lookback-1; i++)
   {
      const double l_prev = lows[i+1];
      const double l_now  = lows[i];
      const double l_next = lows[i-1];

      if(!(l_now < l_prev && l_now < l_next)) continue;
      if(l_now >= from_price) continue;

      const double dist = from_price - l_now;
      if(dist < best_dist)
      {
         best_dist = dist;
         best = l_now;
      }
   }

   return best;
}

// Nearest swing-high style resistance above price
// local-max rule: high[i] > high[i-1] && high[i] > high[i+1]
double CExitManager::FindNearestResistance(const string symbol, const ENUM_TIMEFRAMES tf, const double from_price) const
{
   const int lookback = (tf == PERIOD_H1 ? m_h1_lookback : m_m15_lookback);
   if(Bars(symbol, tf) < lookback + 5) return 0.0;

   double highs[];
   if(CopyHigh(symbol, tf, 1, lookback, highs) < lookback) return 0.0;

   double best = 0.0;
   double best_dist = DBL_MAX;

   for(int i=1; i<lookback-1; i++)
   {
      const double h_prev = highs[i+1];
      const double h_now  = highs[i];
      const double h_next = highs[i-1];

      if(!(h_now > h_prev && h_now > h_next)) continue;
      if(h_now <= from_price) continue;

      const double dist = h_now - from_price;
      if(dist < best_dist)
      {
         best_dist = dist;
         best = h_now;
      }
   }

   return best;
}


// --------------------
// Broker helpers
// --------------------

double CExitManager::MinStopDistancePrice(const string symbol) const
{
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const int stops_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   // Convert levels (points) to price
   double dist = (double)MathMax(stops_level, freeze_level) * point;

   // Add a tiny safety buffer (half spread point-equivalent)
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(bid > 0.0 && ask > 0.0)
      dist = MathMax(dist, (ask - bid) * 0.5);

   return MathMax(0.0, dist);
}

double CExitManager::NormalizePrice(const string symbol, const double price) const
{
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}
