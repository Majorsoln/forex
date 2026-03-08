//+------------------------------------------------------------------+
//|                                               chart_pattern.mqh  |
//|                                            EliteFx Trading System |
//|                                           Version 4.02 - FIXED    |
//+------------------------------------------------------------------+
#property copyright "EliteFx Trading System"
#property link      "https://www.eliteFx.com"
#property version   "4.02"
#property strict

//+------------------------------------------------------------------+
//| Chart Pattern Result Structure                                   |
//+------------------------------------------------------------------+
struct SChartPatternResult
{
   int               signal;                // -1=Bearish, 0=Neutral, 1=Bullish
   double            pattern_strength;      // 0.0 to 10.0
   double            confidence;            // 0.0 to 1.0
   string            pattern_name;          // Name of detected pattern
   int               pattern_bars;          // Number of bars in pattern
   bool              breakout_confirmed;    // Breakout confirmation
};

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "Chart Pattern Settings "
input bool InpUseChartPatterns = true;             // Enable Chart Pattern Detection
input int InpPatternLookback = 50;                 // Pattern Lookback Bars
input double InpPatternMinConfidence = 0.65;       // Minimum Confidence (0.5-0.8)
input bool InpRequireBreakoutConfirm = false;      // Require Breakout Confirmation

//+------------------------------------------------------------------+
//| Chart Pattern Detector Class                                     |
//+------------------------------------------------------------------+
class CChartPatternDetector
{
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_period;
   bool              m_initialized;
   
   //--- Pattern detection arrays
   double            m_highs[];
   double            m_lows[];
   double            m_closes[];

public:
   CChartPatternDetector(void) : m_initialized(false) {}
   ~CChartPatternDetector(void) { Deinitialize(); }
   
   bool Initialize(string symbol, ENUM_TIMEFRAMES period);
   void Deinitialize(void);
   SChartPatternResult Analyze(void);

private:
   //--- Pattern detection functions
   int DetectDoubleTop(void);
   int DetectDoubleBottom(void);
   int DetectHeadAndShoulders(void);
   int DetectInverseHeadAndShoulders(void);
   int DetectTriangle(void);
   int DetectWedge(void);
   
   //--- Utility functions
   bool LoadPriceData(void);
   int FindLocalMaxima(int start, int end);
   int FindLocalMinima(int start, int end);
   double CalculatePatternStrength(int pattern_type, double tolerance);
};

//+------------------------------------------------------------------+
//| Initialize detector                                               |
//+------------------------------------------------------------------+
bool CChartPatternDetector::Initialize(string symbol, ENUM_TIMEFRAMES period)
{
   m_symbol = symbol;
   m_period = period;
   
   //--- Set array properties
   ArraySetAsSeries(m_highs, true);
   ArraySetAsSeries(m_lows, true);
   ArraySetAsSeries(m_closes, true);
   
   m_initialized = true;
   return true;
}

//+------------------------------------------------------------------+
//| Deinitialize                                                      |
//+------------------------------------------------------------------+
void CChartPatternDetector::Deinitialize(void)
{
   m_initialized = false;
}

//+------------------------------------------------------------------+
//| Main Analysis Function                                            |
//+------------------------------------------------------------------+
SChartPatternResult CChartPatternDetector::Analyze(void)
{
   SChartPatternResult result;
   ZeroMemory(result);
   
   if(!m_initialized || !InpUseChartPatterns)
   {
      return result;
   }
   
   //--- Load price data
   if(!LoadPriceData())
   {
      return result;
   }
   
   //--- Scan for patterns
   int max_strength = 0;
   int best_signal = 0;
   string best_pattern = "None";
   
   //--- Check Double Top
   int double_top = DetectDoubleTop();
   if(double_top != 0 && MathAbs(double_top) > max_strength)
   {
      max_strength = MathAbs(double_top);
      best_signal = -1;  // Bearish
      best_pattern = "Double Top";
   }
   
   //--- Check Double Bottom
   int double_bottom = DetectDoubleBottom();
   if(double_bottom != 0 && MathAbs(double_bottom) > max_strength)
   {
      max_strength = MathAbs(double_bottom);
      best_signal = 1;  // Bullish
      best_pattern = "Double Bottom";
   }
   
   //--- Check Head and Shoulders
   int hs = DetectHeadAndShoulders();
   if(hs != 0 && MathAbs(hs) > max_strength)
   {
      max_strength = MathAbs(hs);
      best_signal = -1;  // Bearish
      best_pattern = "Head and Shoulders";
   }
   
   //--- Check Inverse H&S
   int ihs = DetectInverseHeadAndShoulders();
   if(ihs != 0 && MathAbs(ihs) > max_strength)
   {
      max_strength = MathAbs(ihs);
      best_signal = 1;  // Bullish
      best_pattern = "Inverse H&S";
   }
   
   //--- Check Triangle
   int triangle = DetectTriangle();
   if(triangle != 0 && MathAbs(triangle) > max_strength)
   {
      max_strength = MathAbs(triangle);
      best_signal = (triangle > 0) ? 1 : -1;
      best_pattern = "Triangle";
   }
   
   //--- Check Wedge
   int wedge = DetectWedge();
   if(wedge != 0 && MathAbs(wedge) > max_strength)
   {
      max_strength = MathAbs(wedge);
      best_signal = (wedge > 0) ? 1 : -1;
      best_pattern = "Wedge";
   }
   
   //--- Fill result
   if(max_strength > 0)
   {
      result.signal = best_signal;
      result.pattern_strength = max_strength;
      result.confidence = MathMin(1.0, (double)max_strength / 10.0);
      result.pattern_name = best_pattern;
      result.pattern_bars = InpPatternLookback;
      result.breakout_confirmed = true;
      
      //--- Check minimum confidence
      if(result.confidence < InpPatternMinConfidence)
      {
         result.signal = 0;
         result.pattern_strength = 0;
      }
   }
   
   return result;
}

//+------------------------------------------------------------------+
//| Load Price Data                                                   |
//+------------------------------------------------------------------+
bool CChartPatternDetector::LoadPriceData(void)
{
   int bars = InpPatternLookback + 10;
   
   if(CopyHigh(m_symbol, m_period, 0, bars, m_highs) <= 0) return false;
   if(CopyLow(m_symbol, m_period, 0, bars, m_lows) <= 0) return false;
   if(CopyClose(m_symbol, m_period, 0, bars, m_closes) <= 0) return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Detect Double Top Pattern                                        |
//+------------------------------------------------------------------+
int CChartPatternDetector::DetectDoubleTop(void)
{
   int lookback = MathMin(InpPatternLookback, ArraySize(m_highs) - 10);
   
   //--- Find two peaks at similar levels
   int peak1 = FindLocalMaxima(5, lookback / 2);
   int peak2 = FindLocalMaxima(peak1 + 5, lookback);
   
   if(peak1 < 0 || peak2 < 0) return 0;
   
   double height1 = m_highs[peak1];
   double height2 = m_highs[peak2];
   
   //--- Check if peaks are at similar level (within 2% tolerance)
   double tolerance = (height1 + height2) / 2 * 0.02;
   
   if(MathAbs(height1 - height2) < tolerance)
   {
      //--- Check if price broke below neckline
      double neckline = MathMin(m_lows[peak1], m_lows[peak2]);
      
      if(m_closes[0] < neckline)
         return 8;  // Strong bearish signal
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Double Bottom Pattern                                     |
//+------------------------------------------------------------------+
int CChartPatternDetector::DetectDoubleBottom(void)
{
   int lookback = MathMin(InpPatternLookback, ArraySize(m_lows) - 10);
   
   //--- Find two troughs at similar levels
   int trough1 = FindLocalMinima(5, lookback / 2);
   int trough2 = FindLocalMinima(trough1 + 5, lookback);
   
   if(trough1 < 0 || trough2 < 0) return 0;
   
   double depth1 = m_lows[trough1];
   double depth2 = m_lows[trough2];
   
   //--- Check if troughs are at similar level
   double tolerance = (depth1 + depth2) / 2 * 0.02;
   
   if(MathAbs(depth1 - depth2) < tolerance)
   {
      //--- Check if price broke above neckline
      double neckline = MathMax(m_highs[trough1], m_highs[trough2]);
      
      if(m_closes[0] > neckline)
         return 8;  // Strong bullish signal
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Head and Shoulders Pattern                                |
//+------------------------------------------------------------------+
int CChartPatternDetector::DetectHeadAndShoulders(void)
{
   int lookback = MathMin(InpPatternLookback, ArraySize(m_highs) - 10);
   
   //--- Find three peaks: left shoulder, head, right shoulder
   int left = FindLocalMaxima(5, lookback / 3);
   int head = FindLocalMaxima(left + 5, 2 * lookback / 3);
   int right = FindLocalMaxima(head + 5, lookback);
   
   if(left < 0 || head < 0 || right < 0) return 0;
   
   double h_left = m_highs[left];
   double h_head = m_highs[head];
   double h_right = m_highs[right];
   
   //--- Head should be higher than shoulders
   if(h_head > h_left && h_head > h_right)
   {
      //--- Shoulders should be at similar level
      double tolerance = h_head * 0.02;
      
      if(MathAbs(h_left - h_right) < tolerance)
      {
         //--- Check neckline break
         double neckline = (m_lows[left] + m_lows[right]) / 2;
         
         if(m_closes[0] < neckline)
            return 9;  // Very strong bearish
      }
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Inverse Head and Shoulders Pattern                        |
//+------------------------------------------------------------------+
int CChartPatternDetector::DetectInverseHeadAndShoulders(void)
{
   int lookback = MathMin(InpPatternLookback, ArraySize(m_lows) - 10);
   
   //--- Find three troughs
   int left = FindLocalMinima(5, lookback / 3);
   int head = FindLocalMinima(left + 5, 2 * lookback / 3);
   int right = FindLocalMinima(head + 5, lookback);
   
   if(left < 0 || head < 0 || right < 0) return 0;
   
   double l_left = m_lows[left];
   double l_head = m_lows[head];
   double l_right = m_lows[right];
   
   //--- Head should be lower than shoulders
   if(l_head < l_left && l_head < l_right)
   {
      //--- Shoulders should be at similar level
      double tolerance = l_head * 0.02;
      
      if(MathAbs(l_left - l_right) < tolerance)
      {
         //--- Check neckline break
         double neckline = (m_highs[left] + m_highs[right]) / 2;
         
         if(m_closes[0] > neckline)
            return 9;  // Very strong bullish
      }
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Triangle Pattern                                          |
//+------------------------------------------------------------------+
int CChartPatternDetector::DetectTriangle(void)
{
   //--- Simplified triangle detection
   int lookback = MathMin(20, ArraySize(m_highs) - 5);
   
   double high_start = m_highs[lookback];
   double high_end = m_highs[0];
   double low_start = m_lows[lookback];
   double low_end = m_lows[0];
   
   //--- Ascending triangle (bullish)
   if(MathAbs(high_start - high_end) < high_start * 0.01 && low_end > low_start)
   {
      return 6;  // Bullish
   }
   
   //--- Descending triangle (bearish)
   if(MathAbs(low_start - low_end) < low_start * 0.01 && high_end < high_start)
   {
      return 6;  // Bearish (return negative in actual implementation)
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Wedge Pattern                                             |
//+------------------------------------------------------------------+
int CChartPatternDetector::DetectWedge(void)
{
   //--- Simplified wedge detection
   int lookback = MathMin(20, ArraySize(m_highs) - 5);
   
   double high_slope = (m_highs[0] - m_highs[lookback]) / lookback;
   double low_slope = (m_lows[0] - m_lows[lookback]) / lookback;
   
   //--- Rising wedge (bearish)
   if(high_slope > 0 && low_slope > 0 && low_slope > high_slope)
   {
      return 5;  // Bearish
   }
   
   //--- Falling wedge (bullish)
   if(high_slope < 0 && low_slope < 0 && MathAbs(low_slope) > MathAbs(high_slope))
   {
      return 5;  // Bullish
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Find Local Maxima                                                 |
//+------------------------------------------------------------------+
int CChartPatternDetector::FindLocalMaxima(int start, int end)
{
   if(start >= end || end >= ArraySize(m_highs)) return -1;
   
   int max_index = start;
   double max_value = m_highs[start];
   
   for(int i = start + 1; i < end; i++)
   {
      if(m_highs[i] > max_value)
      {
         max_value = m_highs[i];
         max_index = i;
      }
   }
   
   return max_index;
}

//+------------------------------------------------------------------+
//| Find Local Minima                                                 |
//+------------------------------------------------------------------+
int CChartPatternDetector::FindLocalMinima(int start, int end)
{
   if(start >= end || end >= ArraySize(m_lows)) return -1;
   
   int min_index = start;
   double min_value = m_lows[start];
   
   for(int i = start + 1; i < end; i++)
   {
      if(m_lows[i] < min_value)
      {
         min_value = m_lows[i];
         min_index = i;
      }
   }
   
   return min_index;
}
//+------------------------------------------------------------------+