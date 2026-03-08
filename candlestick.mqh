//+------------------------------------------------------------------+
//|                                          candlestick.mqh         |
//|                       Candlestick Pattern Detection              |
//|                     ALL 10 PATTERNS IMPLEMENTED                |
//+------------------------------------------------------------------+
#ifndef _MICRO_CANDLESTICK_MQH_
#define _MICRO_CANDLESTICK_MQH_

enum ENUM_CANDLE_PATTERN {
    CANDLE_NONE = 0,
    CANDLE_HAMMER = 1,
    CANDLE_SHOOTING_STAR = 2,
    CANDLE_DOJI = 3,
    CANDLE_ENGULFING_BULL = 4,
    CANDLE_ENGULFING_BEAR = 5,
    CANDLE_MORNING_STAR = 6,
    CANDLE_EVENING_STAR = 7,
    CANDLE_HARAMI = 8,
    CANDLE_PIERCING = 9,
    CANDLE_DARK_CLOUD = 10
};

// Main candlestick result structure
struct MicroCandlestickResult {
    ENUM_CANDLE_PATTERN pattern;
    string pattern_name;
    double confidence;
    int direction;
    datetime time;
    double level;
    bool confirmed;
};

// Forward declaration for multi-timeframe use
// (Full definition in multi_tf_candlestick.mqh)
struct TimeframeCandleResult;

//+------------------------------------------------------------------+
//| Main Detection Function - Scans for all patterns                |
//+------------------------------------------------------------------+
bool DetectMicroCandlesticks(string symbol, ENUM_TIMEFRAMES tf, MicroCandlestickResult &out)
{
    out.pattern = CANDLE_NONE;
    out.pattern_name = "None";
    out.confidence = 0.0;
    out.direction = 0;
    out.time = 0;
    out.level = 0.0;
    out.confirmed = false;
    
    double open[], high[], low[], close[];
    ArraySetAsSeries(open, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);
    
    // Get at least 5 candles for pattern detection
    if(CopyOpen(symbol, tf, 0, 5, open) != 5 ||
       CopyHigh(symbol, tf, 0, 5, high) != 5 ||
       CopyLow(symbol, tf, 0, 5, low) != 5 ||
       CopyClose(symbol, tf, 0, 5, close) != 5)
    {
        return false;
    }
    
    // Check 3-candle patterns first (higher priority)
    
    // Morning Star (3-candle bullish reversal)
    if(IsMorningStar(open[3], high[3], low[3], close[3],
                     open[2], high[2], low[2], close[2],
                     open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_MORNING_STAR;
        out.pattern_name = "Morning Star";
        out.confidence = 0.80;
        out.direction = 1;
        out.time = iTime(symbol, tf, 1);
        out.level = low[2];
        out.confirmed = (close[0] > close[1]);
        return true;
    }
    
    // Evening Star (3-candle bearish reversal)
    if(IsEveningStar(open[3], high[3], low[3], close[3],
                     open[2], high[2], low[2], close[2],
                     open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_EVENING_STAR;
        out.pattern_name = "Evening Star";
        out.confidence = 0.80;
        out.direction = -1;
        out.time = iTime(symbol, tf, 1);
        out.level = high[2];
        out.confirmed = (close[0] < close[1]);
        return true;
    }
    
    // Check 2-candle patterns
    
    // Bullish Engulfing
    if(IsBullishEngulfing(open[2], high[2], low[2], close[2],
                          open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_ENGULFING_BULL;
        out.pattern_name = "Bullish Engulfing";
        out.confidence = 0.75;
        out.direction = 1;
        out.time = iTime(symbol, tf, 1);
        out.level = low[1];
        out.confirmed = (close[0] > close[1]);
        return true;
    }
    
    // Bearish Engulfing
    if(IsBearishEngulfing(open[2], high[2], low[2], close[2],
                          open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_ENGULFING_BEAR;
        out.pattern_name = "Bearish Engulfing";
        out.confidence = 0.75;
        out.direction = -1;
        out.time = iTime(symbol, tf, 1);
        out.level = high[1];
        out.confirmed = (close[0] < close[1]);
        return true;
    }
    
    // Piercing Line (bullish)
    if(IsPiercingLine(open[2], high[2], low[2], close[2],
                      open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_PIERCING;
        out.pattern_name = "Piercing Line";
        out.confidence = 0.72;
        out.direction = 1;
        out.time = iTime(symbol, tf, 1);
        out.level = low[1];
        out.confirmed = (close[0] > close[1]);
        return true;
    }
    
    // Dark Cloud Cover (bearish)
    if(IsDarkCloudCover(open[2], high[2], low[2], close[2],
                        open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_DARK_CLOUD;
        out.pattern_name = "Dark Cloud Cover";
        out.confidence = 0.72;
        out.direction = -1;
        out.time = iTime(symbol, tf, 1);
        out.level = high[1];
        out.confirmed = (close[0] < close[1]);
        return true;
    }
    
    // Bullish Harami
    if(IsBullishHarami(open[2], high[2], low[2], close[2],
                       open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_HARAMI;
        out.pattern_name = "Bullish Harami";
        out.confidence = 0.68;
        out.direction = 1;
        out.time = iTime(symbol, tf, 1);
        out.level = low[1];
        out.confirmed = (close[0] > close[1]);
        return true;
    }
    
    // Bearish Harami
    if(IsBearishHarami(open[2], high[2], low[2], close[2],
                       open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_HARAMI;
        out.pattern_name = "Bearish Harami";
        out.confidence = 0.68;
        out.direction = -1;
        out.time = iTime(symbol, tf, 1);
        out.level = high[1];
        out.confirmed = (close[0] < close[1]);
        return true;
    }
    
    // Check single candle patterns
    
    // Hammer
    if(IsHammer(open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_HAMMER;
        out.pattern_name = "Hammer";
        out.confidence = 0.70;
        out.direction = 1;
        out.time = iTime(symbol, tf, 1);
        out.level = low[1];
        out.confirmed = (close[0] > close[1]);
        return true;
    }
    
    // Shooting Star
    if(IsShootingStar(open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_SHOOTING_STAR;
        out.pattern_name = "Shooting Star";
        out.confidence = 0.70;
        out.direction = -1;
        out.time = iTime(symbol, tf, 1);
        out.level = high[1];
        out.confirmed = (close[0] < close[1]);
        return true;
    }
    
    // Doji
    if(IsDoji(open[1], high[1], low[1], close[1]))
    {
        out.pattern = CANDLE_DOJI;
        out.pattern_name = "Doji";
        out.confidence = 0.60;
        out.direction = 0;
        out.time = iTime(symbol, tf, 1);
        out.level = close[1];
        out.confirmed = true;
        return true;
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| SINGLE CANDLE PATTERNS                                           |
//+------------------------------------------------------------------+

bool IsHammer(double open, double high, double low, double close)
{
    double body = MathAbs(close - open);
    if(body <= 0) return false;
    
    double lower_shadow = MathMin(open, close) - low;
    double upper_shadow = high - MathMax(open, close);
    
    // Long lower shadow (2 body), small upper shadow
    if(lower_shadow > body * 2.0 && upper_shadow < body * 0.3)
        return true;
    
    return false;
}

bool IsShootingStar(double open, double high, double low, double close)
{
    double body = MathAbs(close - open);
    if(body <= 0) return false;
    
    double lower_shadow = MathMin(open, close) - low;
    double upper_shadow = high - MathMax(open, close);
    
    // Long upper shadow (2 body), small lower shadow
    if(upper_shadow > body * 2.0 && lower_shadow < body * 0.3)
        return true;
    
    return false;
}

bool IsDoji(double open, double high, double low, double close)
{
    double body = MathAbs(close - open);
    double total_range = high - low;
    
    if(total_range <= 0) return false;
    
    // Body is less than 10% of total range
    if(body / total_range < 0.1)
        return true;
    
    return false;
}

//+------------------------------------------------------------------+
//| TWO CANDLE PATTERNS                                              |
//+------------------------------------------------------------------+

bool IsBullishEngulfing(double open1, double high1, double low1, double close1,
                        double open2, double high2, double low2, double close2)
{
    // First candle is bearish
    if(close1 >= open1) return false;
    
    // Second candle is bullish
    if(close2 <= open2) return false;
    
    // Second candle engulfs first
    if(open2 < close1 && close2 > open1)
        return true;
    
    return false;
}

bool IsBearishEngulfing(double open1, double high1, double low1, double close1,
                        double open2, double high2, double low2, double close2)
{
    // First candle is bullish
    if(close1 <= open1) return false;
    
    // Second candle is bearish
    if(close2 >= open2) return false;
    
    // Second candle engulfs first
    if(open2 > close1 && close2 < open1)
        return true;
    
    return false;
}

bool IsPiercingLine(double open1, double high1, double low1, double close1,
                    double open2, double high2, double low2, double close2)
{
    // First candle is bearish
    if(close1 >= open1) return false;
    
    // Second candle is bullish
    if(close2 <= open2) return false;
    
    double body1 = open1 - close1;
    
    // Second candle opens below first candle's close
    if(open2 >= close1) return false;
    
    // Second candle closes above midpoint of first candle
    if(close2 > close1 + body1 * 0.5)
        return true;
    
    return false;
}

bool IsDarkCloudCover(double open1, double high1, double low1, double close1,
                      double open2, double high2, double low2, double close2)
{
    // First candle is bullish
    if(close1 <= open1) return false;
    
    // Second candle is bearish
    if(close2 >= open2) return false;
    
    double body1 = close1 - open1;
    
    // Second candle opens above first candle's close
    if(open2 <= close1) return false;
    
    // Second candle closes below midpoint of first candle
    if(close2 < open1 + body1 * 0.5)
        return true;
    
    return false;
}

bool IsBullishHarami(double open1, double high1, double low1, double close1,
                     double open2, double high2, double low2, double close2)
{
    // First candle is bearish (larger body)
    if(close1 >= open1) return false;
    
    // Second candle is bullish (smaller body)
    if(close2 <= open2) return false;
    
    // Second candle is contained within first candle's body
    if(open2 > close1 && close2 < open1)
        return true;
    
    return false;
}

bool IsBearishHarami(double open1, double high1, double low1, double close1,
                     double open2, double high2, double low2, double close2)
{
    // First candle is bullish (larger body)
    if(close1 <= open1) return false;
    
    // Second candle is bearish (smaller body)
    if(close2 >= open2) return false;
    
    // Second candle is contained within first candle's body
    if(open2 < close1 && close2 > open1)
        return true;
    
    return false;
}

//+------------------------------------------------------------------+
//| THREE CANDLE PATTERNS                                            |
//+------------------------------------------------------------------+

bool IsMorningStar(double open1, double high1, double low1, double close1,
                   double open2, double high2, double low2, double close2,
                   double open3, double high3, double low3, double close3)
{
    // First candle: Large bearish
    if(close1 >= open1) return false;
    double body1 = open1 - close1;
    
    // Second candle: Small body (star)
    double body2 = MathAbs(close2 - open2);
    if(body2 > body1 * 0.3) return false;
    
    // Star gaps down
    if(MathMax(open2, close2) >= close1) return false;
    
    // Third candle: Large bullish
    if(close3 <= open3) return false;
    double body3 = close3 - open3;
    
    // Third candle closes well into first candle's body
    if(close3 > close1 + body1 * 0.5)
        return true;
    
    return false;
}

bool IsEveningStar(double open1, double high1, double low1, double close1,
                   double open2, double high2, double low2, double close2,
                   double open3, double high3, double low3, double close3)
{
    // First candle: Large bullish
    if(close1 <= open1) return false;
    double body1 = close1 - open1;
    
    // Second candle: Small body (star)
    double body2 = MathAbs(close2 - open2);
    if(body2 > body1 * 0.3) return false;
    
    // Star gaps up
    if(MathMin(open2, close2) <= close1) return false;
    
    // Third candle: Large bearish
    if(close3 >= open3) return false;
    double body3 = open3 - close3;
    
    // Third candle closes well into first candle's body
    if(close3 < open1 + body1 * 0.5)
        return true;
    
    return false;
}

#endif // _MICRO_CANDLESTICK_MQH_
