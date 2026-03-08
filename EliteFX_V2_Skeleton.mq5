//+------------------------------------------------------------------+
//|                                             EliteFX_V2_Skeleton  |
//|  Minimal end-to-end wiring for V2.0 flow (M15 exec, W1/D1/H4/H1) |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"

#include <Trade/Trade.mqh>

#include <elite\MasterSignalGenerator.mqh>
#include <elite\InstitutionalExitManager.mqh>
#include <elite\RiskManagement.mqh>
#include <elite\NewsManager.mqh>
#include <elite\TradeManagerV2.mqh>
#include <elite\MarketStateV2.mqh>
#include <elite\SignalPerformanceStore.mqh>

#include <elite\chart_pattern.mqh>
#include <elite\candlestick.mqh>

input long   InpMagic              = 20260223;
input int    InpMaxPositions       = 1;
input int    InpNewsBlockMinsAhead = 30;

// Management inputs
input int    InpLossWindowMins     = 45;
input int    InpWeekendCloseMins   = 15;
input int    InpWeekendCloseHour   = 23;   // broker/server time
input int    InpWeekendCloseMinute = 59;   // broker/server time
input int    InpProfitProtectHours = 4;
input double InpMinNetProfit       = 2.0;

input int    InpTrailAfterH1       = 3;
input double InpTrailBufferPips    = 2.0;

// Entry duplicate protection / cooldown
input int    InpSignalCooldownMins   = 30;   // block new entries for this many minutes after a successful open
input bool   InpCooldownAnySignal    = true; // true: cooldown applies to any signal; false: only same signal_name+direction

// Exit sanity tuning (for optimization)
input double InpExitMinRR            = 1.20;
input double InpExitMinSLPips        = 2.0;
input double InpExitMinTPPips        = 2.0;
input double InpExitSpreadBufferPips = 0.5;

CTrade                 g_trade;
CMasterSignalGenerator g_msg;
CExitManager           g_exit;
CDRARiskManager        g_risk;
CNewsManager           g_news;
CTradeManagerV2        g_tm;
CMarketStateV2         g_state;
CSignalPerformanceStore g_perf;


bool IsNewBarM15(const string symbol)
{
   static datetime last_bar_time = 0;
   const datetime t = iTime(symbol, PERIOD_M15, 0); // current bar open time
   if(t == 0) return false;
   if(t == last_bar_time) return false;
   last_bar_time = t;
   return true;
}

bool HasOpenPositionByMagic(const string symbol, const long magic)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      return true;
   }
   return false;
}

int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);

   g_news.Initialize();

   // Risk manager initialize (adjust these as per your system)
   g_risk.SetMagicNumber(InpMagic);
   g_risk.InitializeRiskSystem();

   // Trade manager settings
   g_tm.SetMagic(InpMagic);
   g_tm.AttachNewsManager(g_news);
   g_tm.SetLossWindowMins(InpLossWindowMins);
   g_tm.SetWeekendCloseMins(InpWeekendCloseMins);
   g_tm.SetWeekendCloseClock(InpWeekendCloseHour, InpWeekendCloseMinute);
   g_tm.SetProfitProtectHours(InpProfitProtectHours);
   g_tm.SetMinNetProfit(InpMinNetProfit);
   g_tm.SetTrailing(InpTrailAfterH1, InpTrailBufferPips);

   // ExitManager sanity tuning
   g_exit.SetSanityParams(InpExitMinRR, InpExitMinSLPips, InpExitMinTPPips, InpExitSpreadBufferPips);

   Print("EliteFX V2 Skeleton initialized");
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   const string symbol = _Symbol;

   // Always manage open positions first
   g_tm.ManageOpenPositions(symbol);

   // Gate: max open positions
   if(HasOpenPositionByMagic(symbol, InpMagic)) return;

   // Gate: ENTRY evaluation only once per new M15 bar
   if(!IsNewBarM15(symbol)) return;

   // Gate: high impact news within next X mins
   string ev; datetime et;
   if(g_news.NoNewTradesWindow(InpNewsBlockMinsAhead, ev, et))
   {
      Print("[Gate] No new trades due to upcoming news: ", ev, " at ", TimeToString(et, TIME_DATE|TIME_MINUTES));
      return;
   }

   // -----------------
   // Micro pattern scores (normalize to 0..100)
   // -----------------
   double chart_score = 50.0;
   double candle_score = 50.0;

   // If your pattern libs expose confidence 0..1, scale here.
   // (These files vary by implementation; keep this block as adapter.)
   // TODO: replace with your actual pattern calls.

   // -----------------
   // Market state (Macro/Mid/Micro)
   // -----------------
   MarketStateOut st;
   g_state.Compute(symbol, chart_score, candle_score, st);

   if(st.MacroDirection == SIGNAL_NONE || !st.MidAlignment || !st.MicroEntryPermission)
      return; // V2.0 rule: no trade without all gates

   // -----------------
   // Signal detection (ENTRY ONLY)
   // -----------------
   SignalPack sp;
   if(!g_msg.GenerateSignalPack(symbol, PERIOD_M15, sp))
      return;

   // Must align signal direction with MacroDirection
   if(sp.direction != st.MacroDirection)
      return;

   // Gate: cooldown (prevents rapid re-entries)
   static datetime last_open_time = 0;
   static string   last_open_signal = "";
   static int      last_open_dir = (int)SIGNAL_NONE;

   const datetime now = TimeCurrent();
   if(InpSignalCooldownMins > 0 && last_open_time > 0)
   {
      const int cd_sec = InpSignalCooldownMins * 60;
      const bool in_cd = (now - last_open_time) < cd_sec;

      if(in_cd)
      {
         if(InpCooldownAnySignal)
         {
            Print("[Gate] Cooldown active (any-signal): ", InpSignalCooldownMins, " mins");
            return;
         }
         else
         {
            if(last_open_signal == sp.signal_name && last_open_dir == (int)sp.direction)
            {
               Print("[Gate] Cooldown active (same-signal): ", sp.signal_name, " for ", InpSignalCooldownMins, " mins");
               return;
            }
         }
      }
   }

   // -----------------
   // Exit building (H1 SL, M15 TP)
   // -----------------
   ExitParams ex;
   if(!g_exit.BuildExits(symbol, sp.direction, sp.entry_price, ex))
      return;

   // -----------------
   // Risk sizing mapping (0..100)
   // -----------------
   const double regime_fit = st.MacroScore;

   // credibility = normalize(MidScore + MicroScore) -> 0..100
   double credibility = (st.MidScore + st.MicroScore); // 0..200
   credibility = MathMin(100.0, (credibility/200.0)*100.0);

   // confidence = normalize(chart + candle) -> 0..100
   double confidence = (st.ChartPatternScore + st.CandleScore); // 0..200
   confidence = MathMin(100.0, (confidence/200.0)*100.0);

   const double signal_quality = g_perf.GetSignalQuality(sp.signal_quality_id);

   const double lots = g_risk.CalculateLotSize(symbol, ex.sl_pips, confidence, credibility, signal_quality, regime_fit);
   if(lots <= 0.0)
      return;

   // -----------------
   // Place order
   // -----------------
   bool ok=false;
   if(sp.direction == SIGNAL_BUY)
      ok = g_trade.Buy(lots, symbol, 0.0, ex.sl_price, ex.tp_price, sp.signal_name);
   else if(sp.direction == SIGNAL_SELL)
      ok = g_trade.Sell(lots, symbol, 0.0, ex.sl_price, ex.tp_price, sp.signal_name);

   if(ok)
   {
      // update cooldown trackers
      last_open_time = TimeCurrent();
      last_open_signal = sp.signal_name;
      last_open_dir = (int)sp.direction;

      Print("[OPEN] ", sp.signal_name,
            " dir=", (sp.direction==SIGNAL_BUY?"BUY":"SELL"),
            " entry=", DoubleToString(sp.entry_price,_Digits),
            " SL=", DoubleToString(ex.sl_price,_Digits),
            " TP=", DoubleToString(ex.tp_price,_Digits),
            " sl_pips=", DoubleToString(ex.sl_pips,1),
            " scores: Macro=", DoubleToString(st.MacroScore,1),
            " Mid=", DoubleToString(st.MidScore,1),
            " Micro=", DoubleToString(st.MicroScore,1),
            " conf=", DoubleToString(confidence,1),
            " cred=", DoubleToString(credibility,1),
            " qual=", DoubleToString(signal_quality,1));
   }
   else
   {
      Print("[OPEN-FAIL] err=", GetLastError());
   }
}
