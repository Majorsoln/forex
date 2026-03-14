//+------------------------------------------------------------------+
//|                                                   MarketStateV2  |
//|   V2.1 Scoring Layers (Macro W1/D1, Mid H4/H1, Micro M15)        |
//|   FIXES:                                                          |
//|     1. ADX buffer index corrected (0=ADX, 1=+DI, 2=-DI)          |
//|     2. EMA spread + slope analysis added                          |
//|     3. Improved W1/D1 conflict handling with D1 recency weight    |
//|     4. Rebalanced Mid layer (H1 weight increased for M15 exec)   |
//|     5. RSI gradient scoring (not binary)                          |
//|     6. Tick Volume + ATR momentum proxy (no real volume needed)   |
//|     7. Chart pattern & candle scores integrated into gating       |
//|     8. Indicator handles cached (no leaks on repeated Compute)    |
//|     9. +DI/-DI directional confirmation added                     |
//|    10. Momentum divergence detection (price vs RSI)               |
//+------------------------------------------------------------------+
#property strict

#include "MasterSignalGenerator.mqh" // ENUM_SIGNAL_DIR

struct MarketStateOut
{
   ENUM_SIGNAL_DIR MacroDirection;
   double          MacroScore;          // 0..100

   bool            MidAlignment;
   double          MidScore;            // 0..100

   bool            MicroEntryPermission;
   double          MicroScore;          // 0..100

   double          ChartPatternScore;   // 0..100
   double          CandleScore;         // 0..100

   // --- V2.1 diagnostics ---
   double          VolatilityScore;     // 0..100 (ATR-based)
   double          TickMomentumScore;   // 0..100 (tick volume proxy)
   bool            DivergenceDetected;  // price/RSI divergence flag
   string          DivergenceType;      // "BULL_DIV" / "BEAR_DIV" / ""
};

//+------------------------------------------------------------------+
//| Cached handle entry for one symbol+timeframe+indicator combo     |
//+------------------------------------------------------------------+
struct HandleEntry
{
   string symbol;
   int    tf;
   int    indicator_type;  // 0=EMA20, 1=EMA50, 2=ADX, 3=RSI, 4=ATR
   int    handle;
};

class CMarketStateV2
{
private:
   // --- Handle cache ---
   HandleEntry m_handles[];
   int         m_handle_count;

   // --- Helpers ---
   double Clamp100(const double v) const { return MathMax(0.0, MathMin(100.0, v)); }

   int  GetOrCreateHandle(const string symbol, const ENUM_TIMEFRAMES tf, const int type);
   void ReleaseAllHandles(void);

   // --- Core analysis functions ---
   ENUM_SIGNAL_DIR DirectionByEMA(const string symbol, const ENUM_TIMEFRAMES tf,
                                   double &out_spread_norm, double &out_slope_score) const;

   double ScoreByADX(const string symbol, const ENUM_TIMEFRAMES tf,
                     double &out_di_confirmation) const;

   double ScoreByRSIGradient(const string symbol, const ENUM_TIMEFRAMES tf,
                              const ENUM_SIGNAL_DIR expected_dir) const;

   double ScoreByTickMomentum(const string symbol, const ENUM_TIMEFRAMES tf,
                               const ENUM_SIGNAL_DIR expected_dir) const;

   double ScoreByATRVolatility(const string symbol, const ENUM_TIMEFRAMES tf) const;

   bool   DetectRSIDivergence(const string symbol, const ENUM_TIMEFRAMES tf,
                               const ENUM_SIGNAL_DIR macro_dir,
                               string &div_type) const;

public:
   CMarketStateV2()
   {
      m_handle_count = 0;
      ArrayResize(m_handles, 0);
   }

   ~CMarketStateV2()
   {
      ReleaseAllHandles();
   }

   bool Compute(const string symbol,
                const double chart_score_0_100,
                const double candle_score_0_100,
                MarketStateOut &out);
};

//+------------------------------------------------------------------+
//| Handle cache: get existing or create new indicator handle         |
//+------------------------------------------------------------------+
int CMarketStateV2::GetOrCreateHandle(const string symbol, const ENUM_TIMEFRAMES tf, const int type)
{
   // Search cache first
   for(int i = 0; i < m_handle_count; i++)
   {
      if(m_handles[i].symbol == symbol &&
         m_handles[i].tf == (int)tf &&
         m_handles[i].indicator_type == type)
      {
         return m_handles[i].handle;
      }
   }

   // Create new handle
   int h = INVALID_HANDLE;
   switch(type)
   {
      case 0: h = iMA(symbol, tf, 20, 0, MODE_EMA, PRICE_CLOSE);  break; // EMA20
      case 1: h = iMA(symbol, tf, 50, 0, MODE_EMA, PRICE_CLOSE);  break; // EMA50
      case 2: h = iADX(symbol, tf, 14);                            break; // ADX
      case 3: h = iRSI(symbol, tf, 14, PRICE_CLOSE);               break; // RSI
      case 4: h = iATR(symbol, tf, 14);                             break; // ATR
   }

   if(h == INVALID_HANDLE) return INVALID_HANDLE;

   // Cache it
   ArrayResize(m_handles, m_handle_count + 1);
   m_handles[m_handle_count].symbol         = symbol;
   m_handles[m_handle_count].tf             = (int)tf;
   m_handles[m_handle_count].indicator_type = type;
   m_handles[m_handle_count].handle         = h;
   m_handle_count++;

   return h;
}

void CMarketStateV2::ReleaseAllHandles(void)
{
   for(int i = 0; i < m_handle_count; i++)
   {
      if(m_handles[i].handle != INVALID_HANDLE)
         IndicatorRelease(m_handles[i].handle);
   }
   ArrayResize(m_handles, 0);
   m_handle_count = 0;
}

//+------------------------------------------------------------------+
//| FIX #1 & #2: EMA direction + spread normalization + slope        |
//| Returns direction, outputs normalized spread (0..1) and slope    |
//| score (0..100) for scoring use.                                  |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CMarketStateV2::DirectionByEMA(const string symbol,
                                                const ENUM_TIMEFRAMES tf,
                                                double &out_spread_norm,
                                                double &out_slope_score) const
{
   out_spread_norm = 0.0;
   out_slope_score = 0.0;

   // Use const_cast workaround: call iMA directly since we can't call
   // non-const GetOrCreateHandle from const method. For the const helpers
   // we look up handles that should already be cached by Compute().
   int h20 = INVALID_HANDLE, h50 = INVALID_HANDLE;
   for(int i = 0; i < m_handle_count; i++)
   {
      if(m_handles[i].symbol == symbol && m_handles[i].tf == (int)tf)
      {
         if(m_handles[i].indicator_type == 0) h20 = m_handles[i].handle;
         if(m_handles[i].indicator_type == 1) h50 = m_handles[i].handle;
      }
   }
   if(h20 == INVALID_HANDLE || h50 == INVALID_HANDLE) return SIGNAL_NONE;

   // Need 3 bars: shift 1,2,3 (closed candles) for slope calculation
   double b20[3], b50[3];
   if(CopyBuffer(h20, 0, 1, 3, b20) < 3) return SIGNAL_NONE;
   if(CopyBuffer(h50, 0, 1, 3, b50) < 3) return SIGNAL_NONE;

   // b20[0]=shift3(oldest), b20[1]=shift2, b20[2]=shift1(newest)
   const double ema20_now  = b20[2];
   const double ema50_now  = b50[2];
   const double ema20_prev = b20[1];
   const double ema50_prev = b50[1];
   const double ema20_old  = b20[0];

   // --- Direction ---
   ENUM_SIGNAL_DIR dir = SIGNAL_NONE;
   if(ema20_now > ema50_now) dir = SIGNAL_BUY;
   if(ema20_now < ema50_now) dir = SIGNAL_SELL;
   if(dir == SIGNAL_NONE) return SIGNAL_NONE;

   // --- Spread normalization ---
   // Normalize EMA spread relative to price (percentage of price)
   // Typical strong trend: spread > 0.5% of price
   // We map 0..1% spread -> 0..1.0
   const double mid_price = (ema20_now + ema50_now) / 2.0;
   if(mid_price <= 0.0) return dir;

   const double spread_pct = MathAbs(ema20_now - ema50_now) / mid_price * 100.0;
   out_spread_norm = MathMin(1.0, spread_pct / 1.0); // 1% = full score

   // --- Slope analysis ---
   // EMA20 slope over last 2 closed candles
   // Positive slope for BUY trend = confirmation, negative = warning
   const double slope_20 = (ema20_now - ema20_old);   // raw price change over 2 bars
   const double slope_pct = (mid_price > 0.0) ? (slope_20 / mid_price * 100.0) : 0.0;

   // Map slope alignment to 0..100
   // For BUY:  positive slope = good (up to 100), negative = bad (0)
   // For SELL: negative slope = good, positive = bad
   double slope_alignment = 0.0;
   if(dir == SIGNAL_BUY)
      slope_alignment = (slope_pct > 0.0) ? MathMin(100.0, slope_pct * 200.0) : 0.0;
   else
      slope_alignment = (slope_pct < 0.0) ? MathMin(100.0, MathAbs(slope_pct) * 200.0) : 0.0;

   // Also check if EMA50 slope confirms (both EMAs moving same direction)
   const double slope_50 = (ema50_now - b50[0]);
   bool both_aligned = false;
   if(dir == SIGNAL_BUY)  both_aligned = (slope_20 > 0.0 && slope_50 > 0.0);
   if(dir == SIGNAL_SELL) both_aligned = (slope_20 < 0.0 && slope_50 < 0.0);

   // Bonus 20 points if both EMAs slope in trend direction
   out_slope_score = slope_alignment + (both_aligned ? 20.0 : 0.0);
   out_slope_score = MathMin(100.0, out_slope_score);

   return dir;
}

//+------------------------------------------------------------------+
//| FIX #1 & #9: ADX with correct buffer index + DI confirmation     |
//| Buffer 0 = ADX main line                                         |
//| Buffer 1 = +DI                                                   |
//| Buffer 2 = -DI                                                   |
//| out_di_confirmation: 0..1 (how well +DI/-DI confirms direction)  |
//+------------------------------------------------------------------+
double CMarketStateV2::ScoreByADX(const string symbol, const ENUM_TIMEFRAMES tf,
                                   double &out_di_confirmation) const
{
   out_di_confirmation = 0.0;

   int h = INVALID_HANDLE;
   for(int i = 0; i < m_handle_count; i++)
   {
      if(m_handles[i].symbol == symbol && m_handles[i].tf == (int)tf &&
         m_handles[i].indicator_type == 2)
      {
         h = m_handles[i].handle;
         break;
      }
   }
   if(h == INVALID_HANDLE) return 0.0;

   double adx_buf[1], plus_di[1], minus_di[1];

   // FIX: Buffer 0 = ADX line (was incorrectly 2 before)
   if(CopyBuffer(h, 0, 1, 1, adx_buf)  < 1) return 0.0;
   if(CopyBuffer(h, 1, 1, 1, plus_di)  < 1) return 0.0;
   if(CopyBuffer(h, 2, 1, 1, minus_di) < 1) return 0.0;

   // Map ADX 10..40 -> 0..100 (wider range than before)
   double adx_score = (adx_buf[0] - 10.0) * (100.0 / 30.0);
   adx_score = MathMax(0.0, MathMin(100.0, adx_score));

   // DI confirmation: how much +DI dominates -DI (or vice versa)
   // Normalized to 0..1
   const double di_sum = plus_di[0] + minus_di[0];
   if(di_sum > 0.0)
   {
      // For BUY: +DI should dominate => (+DI - -DI) / sum
      // For SELL: -DI should dominate => (-DI - +DI) / sum
      // We return the raw ratio; caller decides direction
      // Range: -1 (full -DI dominance) to +1 (full +DI dominance)
      out_di_confirmation = (plus_di[0] - minus_di[0]) / di_sum;
   }

   return adx_score;
}

//+------------------------------------------------------------------+
//| FIX #5: RSI gradient scoring (not binary 0/20)                   |
//| Returns 0..30 score based on RSI position and momentum           |
//+------------------------------------------------------------------+
double CMarketStateV2::ScoreByRSIGradient(const string symbol, const ENUM_TIMEFRAMES tf,
                                            const ENUM_SIGNAL_DIR expected_dir) const
{
   int h = INVALID_HANDLE;
   for(int i = 0; i < m_handle_count; i++)
   {
      if(m_handles[i].symbol == symbol && m_handles[i].tf == (int)tf &&
         m_handles[i].indicator_type == 3)
      {
         h = m_handles[i].handle;
         break;
      }
   }
   if(h == INVALID_HANDLE) return 0.0;

   double rsi_buf[3];
   if(CopyBuffer(h, 0, 1, 3, rsi_buf) < 3) return 0.0;

   // rsi_buf[0]=shift3(oldest), rsi_buf[1]=shift2, rsi_buf[2]=shift1(newest)
   const double rsi_now  = rsi_buf[2];
   const double rsi_prev = rsi_buf[1];

   double score = 0.0;

   if(expected_dir == SIGNAL_BUY)
   {
      // Zone scoring: 50-60 = moderate, 60-70 = strong, >70 = overbought penalty
      if(rsi_now >= 50.0 && rsi_now < 60.0)
         score = 10.0 + ((rsi_now - 50.0) / 10.0) * 5.0;    // 10..15
      else if(rsi_now >= 60.0 && rsi_now < 70.0)
         score = 15.0 + ((rsi_now - 60.0) / 10.0) * 10.0;   // 15..25
      else if(rsi_now >= 70.0)
         score = 25.0 - ((rsi_now - 70.0) / 15.0) * 15.0;   // 25..10 (overbought penalty)
      else
         score = 0.0; // RSI < 50 for BUY = no support

      // RSI direction bonus: rising RSI confirms BUY
      if(rsi_now > rsi_prev) score += 5.0;
   }
   else if(expected_dir == SIGNAL_SELL)
   {
      if(rsi_now <= 50.0 && rsi_now > 40.0)
         score = 10.0 + ((50.0 - rsi_now) / 10.0) * 5.0;
      else if(rsi_now <= 40.0 && rsi_now > 30.0)
         score = 15.0 + ((40.0 - rsi_now) / 10.0) * 10.0;
      else if(rsi_now <= 30.0)
         score = 25.0 - ((30.0 - rsi_now) / 15.0) * 15.0;   // oversold penalty
      else
         score = 0.0;

      // RSI direction bonus: falling RSI confirms SELL
      if(rsi_now < rsi_prev) score += 5.0;
   }

   return MathMax(0.0, MathMin(30.0, score));
}

//+------------------------------------------------------------------+
//| FIX #6: Tick Volume momentum proxy                               |
//| Most FX brokers provide tick volume. We compare recent tick       |
//| volume to its moving average to gauge participation.              |
//| Returns 0..100                                                    |
//+------------------------------------------------------------------+
double CMarketStateV2::ScoreByTickMomentum(const string symbol, const ENUM_TIMEFRAMES tf,
                                            const ENUM_SIGNAL_DIR expected_dir) const
{
   // Get last 21 bars of tick volume (20-bar average + current)
   long tick_vol[21];
   if(CopyTickVolume(symbol, tf, 1, 21, tick_vol) < 21) return 50.0; // neutral default

   // Calculate 20-bar average (tick_vol[0]=oldest .. tick_vol[20]=newest)
   double avg = 0.0;
   for(int i = 0; i < 20; i++)
      avg += (double)tick_vol[i];
   avg /= 20.0;

   if(avg <= 0.0) return 50.0;

   const double current_vol = (double)tick_vol[20];

   // Volume ratio: how current compares to average
   // ratio > 1.0 = above average activity (trend confirmation)
   // ratio < 1.0 = below average (weak move)
   const double ratio = current_vol / avg;

   // Map ratio 0.5..2.0 -> 0..100
   double score = (ratio - 0.5) / 1.5 * 100.0;
   score = MathMax(0.0, MathMin(100.0, score));

   // Direction confirmation via price-volume alignment
   // If price moved in expected direction AND volume is above average, boost
   double close_buf[2];
   if(CopyClose(symbol, tf, 1, 2, close_buf) == 2)
   {
      const double price_change = close_buf[1] - close_buf[0];
      bool vol_confirms = false;

      if(expected_dir == SIGNAL_BUY  && price_change > 0.0 && ratio > 1.0) vol_confirms = true;
      if(expected_dir == SIGNAL_SELL && price_change < 0.0 && ratio > 1.0) vol_confirms = true;

      if(vol_confirms) score = MathMin(100.0, score + 15.0);

      // Penalty: price moved against direction on high volume
      if(expected_dir == SIGNAL_BUY  && price_change < 0.0 && ratio > 1.2) score *= 0.6;
      if(expected_dir == SIGNAL_SELL && price_change > 0.0 && ratio > 1.2) score *= 0.6;
   }

   return MathMax(0.0, MathMin(100.0, score));
}

//+------------------------------------------------------------------+
//| FIX #6: ATR volatility scoring                                   |
//| High volatility + trend = good. Low volatility = weak trend.     |
//| Returns 0..100                                                    |
//+------------------------------------------------------------------+
double CMarketStateV2::ScoreByATRVolatility(const string symbol, const ENUM_TIMEFRAMES tf) const
{
   int h = INVALID_HANDLE;
   for(int i = 0; i < m_handle_count; i++)
   {
      if(m_handles[i].symbol == symbol && m_handles[i].tf == (int)tf &&
         m_handles[i].indicator_type == 4)
      {
         h = m_handles[i].handle;
         break;
      }
   }
   if(h == INVALID_HANDLE) return 50.0;

   // Get current ATR and 20-bar lookback for normalization
   double atr_buf[21];
   if(CopyBuffer(h, 0, 1, 21, atr_buf) < 21) return 50.0;

   // atr_buf[20] = newest (shift 1)
   const double atr_now = atr_buf[20];

   // Average ATR over last 20 bars
   double atr_avg = 0.0;
   for(int i = 0; i < 20; i++)
      atr_avg += atr_buf[i];
   atr_avg /= 20.0;

   if(atr_avg <= 0.0) return 50.0;

   // ATR ratio: current vs average
   const double ratio = atr_now / atr_avg;

   // Map 0.5..2.0 -> 0..100
   // Above average volatility supports trend moves
   double score = (ratio - 0.5) / 1.5 * 100.0;
   return MathMax(0.0, MathMin(100.0, score));
}

//+------------------------------------------------------------------+
//| FIX #10: Price vs RSI divergence detection                       |
//| Compares last 2 swing points in price vs RSI                     |
//+------------------------------------------------------------------+
bool CMarketStateV2::DetectRSIDivergence(const string symbol, const ENUM_TIMEFRAMES tf,
                                          const ENUM_SIGNAL_DIR macro_dir,
                                          string &div_type) const
{
   div_type = "";

   int h_rsi = INVALID_HANDLE;
   for(int i = 0; i < m_handle_count; i++)
   {
      if(m_handles[i].symbol == symbol && m_handles[i].tf == (int)tf &&
         m_handles[i].indicator_type == 3)
      {
         h_rsi = m_handles[i].handle;
         break;
      }
   }
   if(h_rsi == INVALID_HANDLE) return false;

   // Get 20 bars of close and RSI for swing comparison
   double closes[20], rsi_vals[20];
   if(CopyClose(symbol, tf, 1, 20, closes) < 20) return false;
   if(CopyBuffer(h_rsi, 0, 1, 20, rsi_vals) < 20) return false;

   // Simple 2-point divergence: compare bar[5] region vs bar[15] region
   // (approximate swing points)
   // closes[0]=shift20(oldest) .. closes[19]=shift1(newest)
   const double price_old = closes[5];   // ~15 bars ago
   const double price_new = closes[17];  // ~3 bars ago
   const double rsi_old   = rsi_vals[5];
   const double rsi_new   = rsi_vals[17];

   // Bearish divergence: price makes higher high but RSI makes lower high
   if(macro_dir == SIGNAL_BUY)
   {
      if(price_new > price_old && rsi_new < rsi_old)
      {
         div_type = "BEAR_DIV";
         return true;
      }
   }

   // Bullish divergence: price makes lower low but RSI makes higher low
   if(macro_dir == SIGNAL_SELL)
   {
      if(price_new < price_old && rsi_new > rsi_old)
      {
         div_type = "BULL_DIV";
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| MAIN COMPUTE - All fixes integrated                              |
//+------------------------------------------------------------------+
bool CMarketStateV2::Compute(const string symbol,
                              const double chart_score_0_100,
                              const double candle_score_0_100,
                              MarketStateOut &out)
{
   // Zero init
   out.ChartPatternScore     = Clamp100(chart_score_0_100);
   out.CandleScore           = Clamp100(candle_score_0_100);
   out.MacroDirection        = SIGNAL_NONE;
   out.MacroScore            = 0.0;
   out.MidAlignment          = false;
   out.MidScore              = 0.0;
   out.MicroEntryPermission  = false;
   out.MicroScore            = 0.0;
   out.VolatilityScore       = 0.0;
   out.TickMomentumScore     = 0.0;
   out.DivergenceDetected    = false;
   out.DivergenceType        = "";

   // ============================================================
   // Pre-cache all handles needed (prevents leaks, improves speed)
   // ============================================================
   const ENUM_TIMEFRAMES tfs[] = {PERIOD_W1, PERIOD_D1, PERIOD_H4, PERIOD_H1, PERIOD_M15};
   for(int t = 0; t < ArraySize(tfs); t++)
   {
      for(int ind = 0; ind <= 4; ind++)
         GetOrCreateHandle(symbol, tfs[t], ind);
   }

   // ============================================================
   //  MACRO LAYER (W1 + D1) — FIX #2, #3, #9
   // ============================================================
   double w1_spread = 0.0, w1_slope = 0.0;
   double d1_spread = 0.0, d1_slope = 0.0;
   ENUM_SIGNAL_DIR w1 = DirectionByEMA(symbol, PERIOD_W1, w1_spread, w1_slope);
   ENUM_SIGNAL_DIR d1 = DirectionByEMA(symbol, PERIOD_D1, d1_spread, d1_slope);

   double w1_di_conf = 0.0, d1_di_conf = 0.0;
   double w1_adx = ScoreByADX(symbol, PERIOD_W1, w1_di_conf);
   double d1_adx = ScoreByADX(symbol, PERIOD_D1, d1_di_conf);

   // Direction decision: W1 primary, D1 secondary
   // If both agree, strong. If conflict, D1 gets recency weight.
   if(w1 != SIGNAL_NONE && d1 != SIGNAL_NONE)
   {
      if(w1 == d1)
      {
         out.MacroDirection = w1;
      }
      else
      {
         // FIX #3: D1 recency - if D1 has stronger spread + slope, it may override
         const double w1_strength = w1_spread * 50.0 + w1_slope * 0.3 + w1_adx * 0.2;
         const double d1_strength = d1_spread * 60.0 + d1_slope * 0.4 + d1_adx * 0.3; // D1 weighted higher (recency)

         out.MacroDirection = (d1_strength > w1_strength) ? d1 : w1;
      }
   }
   else if(w1 != SIGNAL_NONE)
      out.MacroDirection = w1;
   else
      out.MacroDirection = d1;

   // MacroScore composition:
   //   EMA regime (spread + slope): 40%
   //   ADX strength: 30%
   //   DI directional confirmation: 15%
   //   ATR volatility: 15%
   double s_ema_regime = 0.0;
   if(out.MacroDirection != SIGNAL_NONE)
   {
      // Use average of W1/D1 spread and slope
      const double avg_spread = (w1_spread + d1_spread) / 2.0;
      const double avg_slope  = (w1_slope  + d1_slope)  / 2.0;
      s_ema_regime = avg_spread * 60.0 + avg_slope * 0.4;  // spread 0..1 * 60, slope 0..100 * 0.4
      s_ema_regime = MathMin(100.0, s_ema_regime);
   }

   const double avg_adx = (w1_adx + d1_adx) / 2.0;

   // DI confirmation: check if DI direction aligns with MacroDirection
   double di_score = 0.0;
   if(out.MacroDirection == SIGNAL_BUY)
   {
      // +DI should dominate: di_conf > 0
      const double avg_di = (w1_di_conf + d1_di_conf) / 2.0;
      di_score = (avg_di > 0.0) ? avg_di * 100.0 : 0.0;
   }
   else if(out.MacroDirection == SIGNAL_SELL)
   {
      // -DI should dominate: di_conf < 0
      const double avg_di = (w1_di_conf + d1_di_conf) / 2.0;
      di_score = (avg_di < 0.0) ? MathAbs(avg_di) * 100.0 : 0.0;
   }
   di_score = MathMin(100.0, di_score);

   const double macro_volatility = ScoreByATRVolatility(symbol, PERIOD_D1);

   out.MacroScore = Clamp100(
      s_ema_regime    * 0.40 +
      avg_adx         * 0.30 +
      di_score        * 0.15 +
      macro_volatility* 0.15
   );

   // FIX #3: Conflict penalty (graduated, not flat 35%)
   if(w1 != SIGNAL_NONE && d1 != SIGNAL_NONE && w1 != d1)
   {
      // Strong D1 counter-signal = heavier penalty
      const double conflict_severity = MathMin(1.0, d1_spread + d1_adx / 100.0);
      const double penalty = 0.50 + (conflict_severity * 0.25); // 50%..75% retention
      out.MacroScore = Clamp100(out.MacroScore * penalty);
   }

   // ============================================================
   //  MID LAYER (H4 + H1) — FIX #4
   // ============================================================
   double h4_spread = 0.0, h4_slope = 0.0;
   double h1_spread = 0.0, h1_slope = 0.0;
   ENUM_SIGNAL_DIR h4 = DirectionByEMA(symbol, PERIOD_H4, h4_spread, h4_slope);
   ENUM_SIGNAL_DIR h1 = DirectionByEMA(symbol, PERIOD_H1, h1_spread, h1_slope);

   double h4_di_conf = 0.0, h1_di_conf = 0.0;
   double h4_adx = ScoreByADX(symbol, PERIOD_H4, h4_di_conf);
   double h1_adx = ScoreByADX(symbol, PERIOD_H1, h1_di_conf);

   out.MidScore = 0.0;
   if(out.MacroDirection != SIGNAL_NONE)
   {
      // FIX #4: Rebalanced - H1 gets more weight (closer to M15 execution)
      //   H4 alignment: 35 points (was 55)
      //   H1 alignment: 40 points (was 25) — with spread gradient
      //   ADX contribution: 25 points

      // H4: binary alignment + spread bonus
      if(h4 == out.MacroDirection)
         out.MidScore += 25.0 + (h4_spread * 10.0); // 25..35
      else
         out.MidScore += 5.0;

      // H1: alignment + spread gradient (partial credit for near-cross)
      if(h1 == out.MacroDirection)
         out.MidScore += 25.0 + (h1_spread * 15.0); // 25..40
      else
      {
         // Partial credit: if H1 EMAs are very close (about to cross), give some score
         out.MidScore += 5.0 + ((1.0 - h1_spread) * 8.0); // tighter spread = closer to crossing = more credit
      }

      // ADX on H4/H1
      out.MidScore += 0.15 * (h4_adx + h1_adx); // 0..30
   }
   out.MidScore = Clamp100(out.MidScore);
   out.MidAlignment = (out.MidScore >= 60.0); // slightly relaxed from 65

   // ============================================================
   //  MICRO LAYER (M15) — FIX #5, #6, #7, #10
   // ============================================================
   double m15_spread = 0.0, m15_slope = 0.0;
   ENUM_SIGNAL_DIR m15 = DirectionByEMA(symbol, PERIOD_M15, m15_spread, m15_slope);

   out.MicroScore = 0.0;
   if(out.MacroDirection != SIGNAL_NONE && out.MidAlignment)
   {
      // M15 EMA alignment: 30 points
      if(m15 == out.MacroDirection)
         out.MicroScore += 20.0 + (m15_spread * 10.0);
      else
         out.MicroScore += 5.0;

      // FIX #5: RSI gradient (0..30 points)
      out.MicroScore += ScoreByRSIGradient(symbol, PERIOD_M15, out.MacroDirection);

      // FIX #6: Tick volume momentum (0..100, weighted to 0..20)
      const double tick_mom = ScoreByTickMomentum(symbol, PERIOD_M15, out.MacroDirection);
      out.TickMomentumScore = tick_mom;
      out.MicroScore += tick_mom * 0.20;

      // ADX on M15 (0..100, weighted to 0..15)
      double m15_di_conf = 0.0;
      double m15_adx = ScoreByADX(symbol, PERIOD_M15, m15_di_conf);
      out.MicroScore += m15_adx * 0.15;

      // ATR volatility on M15 (diagnostic + small contribution)
      out.VolatilityScore = ScoreByATRVolatility(symbol, PERIOD_M15);
      out.MicroScore += out.VolatilityScore * 0.05;

      // FIX #7: Chart pattern & candle score integration (0..10 bonus)
      // These now actually affect the gating decision
      const double pattern_bonus = (out.ChartPatternScore + out.CandleScore) / 200.0 * 10.0;
      out.MicroScore += pattern_bonus;

      // FIX #10: Divergence penalty
      string div_type = "";
      if(DetectRSIDivergence(symbol, PERIOD_M15, out.MacroDirection, div_type))
      {
         out.DivergenceDetected = true;
         out.DivergenceType = div_type;

         // Counter-trend divergence = reduce micro score
         // e.g. BEAR_DIV on a BUY setup = warning
         if((out.MacroDirection == SIGNAL_BUY  && div_type == "BEAR_DIV") ||
            (out.MacroDirection == SIGNAL_SELL && div_type == "BULL_DIV"))
         {
            out.MicroScore *= 0.70; // 30% penalty
         }
      }
   }
   out.MicroScore = Clamp100(out.MicroScore);

   // Entry permission: MicroScore >= 65 (adjusted for new scoring range)
   out.MicroEntryPermission = (out.MicroScore >= 65.0);

   return true;
}
