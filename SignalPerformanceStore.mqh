//+------------------------------------------------------------------+
//|                                           SignalPerformanceStore |
//|   V2.0: Provides signal_quality (0..100) by signal_quality_id     |
//|   NOTE: Minimal deterministic stub; replace with your backtest DB |
//+------------------------------------------------------------------+
#property strict

class CSignalPerformanceStore
{
public:
   // Return normalized 0..100 performance score for a given signal id
   double GetSignalQuality(const string signal_quality_id)
   {
      // TODO: Replace with real historical lookup (win-rate, PF, expectancy, maxDD penalty)
      // Deterministic default mapping:
      if(signal_quality_id == "EMA_CROSS") return 55.0;
      if(signal_quality_id == "RSI_BREAK") return 50.0;
      return 50.0;
   }
};
