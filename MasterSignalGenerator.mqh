//+------------------------------------------------------------------+
//|                                           MasterSignalGenerator  |
//|                           V2.0 - ENTRY ONLY (SignalPack output)  |
//|  Responsibilities:
//|   - Scan enabled strategies
//|   - Detect entry signal
//|   - Return SignalPack (no SL/TP, no management)
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"

// -----------------------------
// Signal definitions
// -----------------------------
enum ENUM_SIGNAL_DIR
{
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1,
   SIGNAL_SELL = -1
};

struct SignalPack
{
   bool            is_valid;
   string          signal_name;
   ENUM_SIGNAL_DIR direction;
   double          entry_price;      // market reference (Bid/Ask) or limit reference
   datetime        signal_time;
   string          signal_quality_id; // used for historical performance lookup
   string          reason;           // optional debug
};

// -----------------------------
// MasterSignalGenerator (ENTRY ONLY)
// -----------------------------
class CMasterSignalGenerator
{
private:
   // Strategy enable flags
   bool m_use_ema_cross;
   bool m_use_rsi_break;

   // Strategy parameters (keep small & optimizable)
   int  m_ema_fast;
   int  m_ema_slow;

   int  m_rsi_period;
   int  m_rsi_level_buy;   // e.g. 55
   int  m_rsi_level_sell;  // e.g. 45

   // Internal helpers
   bool GetEMACrossSignal(const string symbol, const ENUM_TIMEFRAMES tf, SignalPack &out);
   bool GetRSIBreakSignal(const string symbol, const ENUM_TIMEFRAMES tf, SignalPack &out);

public:
   CMasterSignalGenerator()
   {
      // Defaults
      m_use_ema_cross = true;
      m_use_rsi_break = true;

      m_ema_fast = 20;
      m_ema_slow = 50;

      m_rsi_period      = 14;
      m_rsi_level_buy   = 55;
      m_rsi_level_sell  = 45;
   }

   // Optional: configure
   void EnableEMACross(const bool enabled) { m_use_ema_cross = enabled; }
   void EnableRSIBreak(const bool enabled) { m_use_rsi_break = enabled; }

   void SetEMACrossParams(const int fast, const int slow)
   {
      m_ema_fast = MathMax(2, fast);
      m_ema_slow = MathMax(m_ema_fast+1, slow);
   }

   void SetRSIParams(const int period, const int buy_level, const int sell_level)
   {
      m_rsi_period = MathMax(2, period);
      m_rsi_level_buy  = buy_level;
      m_rsi_level_sell = sell_level;
   }

   // Main entry point
   bool GenerateSignalPack(const string symbol, const ENUM_TIMEFRAMES tf, SignalPack &out)
   {
      // reset
      out.is_valid = false;
      out.signal_name = "";
      out.direction = SIGNAL_NONE;
      out.entry_price = 0.0;
      out.signal_time = TimeCurrent();
      out.signal_quality_id = "";
      out.reason = "";

      // Strategy priority order (optimize this later if needed)
      if(m_use_ema_cross)
      {
         if(GetEMACrossSignal(symbol, tf, out)) return true;
      }

      if(m_use_rsi_break)
      {
         if(GetRSIBreakSignal(symbol, tf, out)) return true;
      }

      return false;
   }
};

// -----------------------------
// Strategy: EMA Cross (simple, robust)
// BUY when EMA_fast crosses above EMA_slow on closed candle.
// SELL when EMA_fast crosses below EMA_slow on closed candle.
// -----------------------------
bool CMasterSignalGenerator::GetEMACrossSignal(const string symbol, const ENUM_TIMEFRAMES tf, SignalPack &out)
{
   const int bars_needed = MathMax(m_ema_slow, 60) + 5;
   if(Bars(symbol, tf) < bars_needed)
   {
      out.reason = "EMA_CROSS: not enough bars";
      return false;
   }

   int h_fast = iMA(symbol, tf, m_ema_fast, 0, MODE_EMA, PRICE_CLOSE);
   int h_slow = iMA(symbol, tf, m_ema_slow, 0, MODE_EMA, PRICE_CLOSE);
   if(h_fast == INVALID_HANDLE || h_slow == INVALID_HANDLE)
   {
      out.reason = "EMA_CROSS: invalid handle";
      return false;
   }

   double fast_buf[3];
   double slow_buf[3];

   // Use closed candles: shift 1 and 2
   if(CopyBuffer(h_fast, 0, 1, 3, fast_buf) < 3 || CopyBuffer(h_slow, 0, 1, 3, slow_buf) < 3)
   {
      out.reason = "EMA_CROSS: CopyBuffer failed";
      return false;
   }

   const double fast_prev = fast_buf[1]; // shift 2 (older)
   const double slow_prev = slow_buf[1];
   const double fast_now  = fast_buf[0]; // shift 1 (latest closed)
   const double slow_now  = slow_buf[0];

   // Cross detection
   if(fast_prev <= slow_prev && fast_now > slow_now)
   {
      out.is_valid = true;
      out.signal_name = "EMA_CROSS";
      out.direction = SIGNAL_BUY;
      out.entry_price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      out.signal_time = iTime(symbol, tf, 1);
      out.signal_quality_id = out.signal_name;
      out.reason = "EMA fast crossed above slow";
      return true;
   }

   if(fast_prev >= slow_prev && fast_now < slow_now)
   {
      out.is_valid = true;
      out.signal_name = "EMA_CROSS";
      out.direction = SIGNAL_SELL;
      out.entry_price = SymbolInfoDouble(symbol, SYMBOL_BID);
      out.signal_time = iTime(symbol, tf, 1);
      out.signal_quality_id = out.signal_name;
      out.reason = "EMA fast crossed below slow";
      return true;
   }

   return false;
}

// -----------------------------
// Strategy: RSI Break Permission (momentum)
// BUY when RSI crosses above buy_level on closed candle.
// SELL when RSI crosses below sell_level on closed candle.
// -----------------------------
bool CMasterSignalGenerator::GetRSIBreakSignal(const string symbol, const ENUM_TIMEFRAMES tf, SignalPack &out)
{
   const int bars_needed = MathMax(m_rsi_period, 30) + 5;
   if(Bars(symbol, tf) < bars_needed)
   {
      out.reason = "RSI_BREAK: not enough bars";
      return false;
   }

   int h_rsi = iRSI(symbol, tf, m_rsi_period, PRICE_CLOSE);
   if(h_rsi == INVALID_HANDLE)
   {
      out.reason = "RSI_BREAK: invalid handle";
      return false;
   }

   double rsi_buf[3];
   if(CopyBuffer(h_rsi, 0, 1, 3, rsi_buf) < 3)
   {
      out.reason = "RSI_BREAK: CopyBuffer failed";
      return false;
   }

   const double rsi_prev = rsi_buf[1];
   const double rsi_now  = rsi_buf[0];

   if(rsi_prev < m_rsi_level_buy && rsi_now >= m_rsi_level_buy)
   {
      out.is_valid = true;
      out.signal_name = "RSI_BREAK";
      out.direction = SIGNAL_BUY;
      out.entry_price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      out.signal_time = iTime(symbol, tf, 1);
      out.signal_quality_id = out.signal_name;
      out.reason = "RSI crossed above buy level";
      return true;
   }

   if(rsi_prev > m_rsi_level_sell && rsi_now <= m_rsi_level_sell)
   {
      out.is_valid = true;
      out.signal_name = "RSI_BREAK";
      out.direction = SIGNAL_SELL;
      out.entry_price = SymbolInfoDouble(symbol, SYMBOL_BID);
      out.signal_time = iTime(symbol, tf, 1);
      out.signal_quality_id = out.signal_name;
      out.reason = "RSI crossed below sell level";
      return true;
   }

   return false;
}
