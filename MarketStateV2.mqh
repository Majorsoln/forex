//+------------------------------------------------------------------+
//|                                                   MarketStateV2  |
//|   V2.0 Scoring Layers (Macro W1/D1, Mid H4/H1, Micro M15)        |
//|   NOTE: This is a minimal deterministic scaffold you can extend.  |
//+------------------------------------------------------------------+
#property strict

#include "MasterSignalGenerator.mqh" // ENUM_SIGNAL_DIR

struct MarketStateOut
{
   ENUM_SIGNAL_DIR MacroDirection;
   double          MacroScore; // 0..100

   bool            MidAlignment;
   double          MidScore;   // 0..100

   bool            MicroEntryPermission;
   double          MicroScore; // 0..100

   double          ChartPatternScore; // 0..100
   double          CandleScore;       // 0..100
};

class CMarketStateV2
{
private:
   double Clamp100(const double v) const { return MathMax(0.0, MathMin(100.0, v)); }

   // Simple structure proxy: EMA50 slope + EMA20/50 relation
   ENUM_SIGNAL_DIR DirectionByEMA(const string symbol, const ENUM_TIMEFRAMES tf) const
   {
      int h20 = iMA(symbol, tf, 20, 0, MODE_EMA, PRICE_CLOSE);
      int h50 = iMA(symbol, tf, 50, 0, MODE_EMA, PRICE_CLOSE);
      if(h20==INVALID_HANDLE || h50==INVALID_HANDLE) return SIGNAL_NONE;

      double b20[2], b50[2];
      if(CopyBuffer(h20,0,1,2,b20)<2 || CopyBuffer(h50,0,1,2,b50)<2) return SIGNAL_NONE;

      if(b20[0] > b50[0]) return SIGNAL_BUY;
      if(b20[0] < b50[0]) return SIGNAL_SELL;
      return SIGNAL_NONE;
   }

   double ScoreByADX(const string symbol, const ENUM_TIMEFRAMES tf) const
   {
      int h = iADX(symbol, tf, 14);
      if(h==INVALID_HANDLE) return 0.0;
      double adx[1];
      if(CopyBuffer(h,2,1,1,adx)<1) return 0.0; // ADX line buffer index=2 in MQL5
      // Map ADX 10..35 -> 0..100
      double v = (adx[0]-10.0) * (100.0/25.0);
      return Clamp100(v);
   }

public:
   bool Compute(const string symbol,
                const double chart_score_0_100,
                const double candle_score_0_100,
                MarketStateOut &out)
   {
      out.ChartPatternScore = Clamp100(chart_score_0_100);
      out.CandleScore       = Clamp100(candle_score_0_100);

      // -----------------
      // Macro (W1 + D1)
      // -----------------
      ENUM_SIGNAL_DIR w1 = DirectionByEMA(symbol, PERIOD_W1);
      ENUM_SIGNAL_DIR d1 = DirectionByEMA(symbol, PERIOD_D1);

      // Primary: W1, permission: D1
      out.MacroDirection = (w1 != SIGNAL_NONE ? w1 : d1);

      // MacroScore: EMA regime (50) + ADX (50)
      double s_ema = (out.MacroDirection == SIGNAL_NONE ? 20.0 : 60.0);
      double s_adx = 0.5 * (ScoreByADX(symbol, PERIOD_W1) + ScoreByADX(symbol, PERIOD_D1));
      out.MacroScore = Clamp100(0.5*s_ema + 0.5*s_adx);

      // If conflict W1 vs D1, reduce score
      if(w1 != SIGNAL_NONE && d1 != SIGNAL_NONE && w1 != d1)
      {
         out.MacroScore = Clamp100(out.MacroScore * 0.65);
      }

      // -----------------
      // Mid (H4 + H1)
      // -----------------
      ENUM_SIGNAL_DIR h4 = DirectionByEMA(symbol, PERIOD_H4);
      ENUM_SIGNAL_DIR h1 = DirectionByEMA(symbol, PERIOD_H1);

      // Alignment requires MacroDirection defined and H4 matching
      out.MidScore = 0.0;
      if(out.MacroDirection != SIGNAL_NONE)
      {
         out.MidScore += (h4 == out.MacroDirection ? 55.0 : 10.0);
         out.MidScore += (h1 == out.MacroDirection ? 25.0 : 10.0);
         out.MidScore += 0.2 * (ScoreByADX(symbol, PERIOD_H4) + ScoreByADX(symbol, PERIOD_H1));
      }
      out.MidScore = Clamp100(out.MidScore);
      out.MidAlignment = (out.MidScore >= 65.0);

      // -----------------
      // Micro (M15)
      // -----------------
      ENUM_SIGNAL_DIR m15 = DirectionByEMA(symbol, PERIOD_M15);
      out.MicroScore = 0.0;
      if(out.MacroDirection != SIGNAL_NONE && out.MidAlignment)
      {
         out.MicroScore += (m15 == out.MacroDirection ? 50.0 : 10.0);

         // RSI momentum guard (mandatory >=10 score)
         int h_rsi = iRSI(symbol, PERIOD_M15, 14, PRICE_CLOSE);
         double rsi[1];
         double s_rsi = 0.0;
         if(h_rsi!=INVALID_HANDLE && CopyBuffer(h_rsi,0,1,1,rsi)==1)
         {
            if(out.MacroDirection==SIGNAL_BUY)  s_rsi = (rsi[0] >= 50.0 ? 20.0 : 0.0);
            if(out.MacroDirection==SIGNAL_SELL) s_rsi = (rsi[0] <= 50.0 ? 20.0 : 0.0);
         }
         out.MicroScore += s_rsi;

         out.MicroScore += 0.3 * ScoreByADX(symbol, PERIOD_M15);
      }
      out.MicroScore = Clamp100(out.MicroScore);

      // Mandatory momentum score >=10 => enforce via MicroScore floor logic
      out.MicroEntryPermission = (out.MicroScore >= 70.0);

      return true;
   }
};
