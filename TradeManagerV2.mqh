//+------------------------------------------------------------------+
//|                                                TradeManagerV2.mqh|
//|                 V2.0 - Open Position Governance & Forced Closes  |
//| Responsibilities:
//|  - Profit protect close before big news / weekend
//|  - Loss time-window close (30-60 mins)
//|  - H1 candle-count trailing (never loosen risk)
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "NewsManager.mqh"

enum ENUM_CLOSE_REASON
{
   CLOSE_NONE = 0,
   CLOSE_SL,
   CLOSE_TP,
   CLOSE_PROFIT_PROTECT,
   CLOSE_LOSS_WINDOW,
   CLOSE_WEEKEND_CLOSE,
   CLOSE_TRAILING
};

struct PositionMeta
{
   ulong    ticket;
   datetime opened_time;
   double   last_sl;
};

class CTradeManagerV2
{
private:
   CTrade       m_trade;
   CNewsManager *m_news;

   long   m_magic;
   int    m_loss_window_mins;      // 30-60
   int    m_weekend_close_mins;    // 15
   int    m_weekend_close_hour;    // broker/server time
   int    m_weekend_close_minute;  // broker/server time
   int    m_profit_protect_hours;  // 2-6
   double m_min_net_profit;        // in account currency

   int    m_trail_after_h1_candles;
   double m_trail_buffer_pips;

   PositionMeta m_meta[];

   // helpers
   int FindMetaIndex(const ulong ticket);
   void UpsertMeta(const ulong ticket, const datetime opened, const double last_sl);
   bool IsWeekendApproaching(const int minutes_before_close) const;
   int  ClosedH1CandlesSince(const string symbol, const datetime since_time) const;
   double PipSize(const string symbol) const;

   bool ClosePosition(const ulong ticket, const string reason);
   bool ModifySLTP(const string symbol, const ulong ticket, const double new_sl, const double tp);

public:
   CTradeManagerV2()
   {
      m_news = NULL;
      m_magic = 20260223;
      m_loss_window_mins = 45;
      m_weekend_close_mins = 15;
      m_weekend_close_hour = 23;
      m_weekend_close_minute = 59;
      m_profit_protect_hours = 4;
      m_min_net_profit = 2.0;

      m_trail_after_h1_candles = 3;
      m_trail_buffer_pips = 2.0;

      ArrayResize(m_meta, 0);
   }

   void SetMagic(const long magic) { m_magic = magic; }
   void AttachNewsManager(CNewsManager &news) { m_news = &news; }

   void SetLossWindowMins(const int mins) { m_loss_window_mins = MathMax(5, mins); }
   void SetWeekendCloseMins(const int mins) { m_weekend_close_mins = MathMax(1, mins); }
   void SetWeekendCloseClock(const int hour, const int minute)
   {
      m_weekend_close_hour = (int)MathMax(0, MathMin(23, hour));
      m_weekend_close_minute = (int)MathMax(0, MathMin(59, minute));
   }
   void SetProfitProtectHours(const int hours) { m_profit_protect_hours = MathMax(1, hours); }
   void SetMinNetProfit(const double amount) { m_min_net_profit = MathMax(0.0, amount); }

   void SetTrailing(const int h1_candles, const double buffer_pips)
   {
      m_trail_after_h1_candles = MathMax(1, h1_candles);
      m_trail_buffer_pips = MathMax(0.0, buffer_pips);
   }

   // Call this on every tick (or timer)
   void ManageOpenPositions(const string symbol_filter = "")
   {
      const int total = PositionsTotal();
      for(int i=total-1; i>=0; i--)
      {
         if(!PositionSelectByIndex(i)) continue;

         const string sym = PositionGetString(POSITION_SYMBOL);
         if(symbol_filter != "" && sym != symbol_filter) continue;

         const long magic = (long)PositionGetInteger(POSITION_MAGIC);
         if(magic != m_magic) continue;

         const ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
         const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         const double profit = PositionGetDouble(POSITION_PROFIT);
         const double sl = PositionGetDouble(POSITION_SL);
         const double tp = PositionGetDouble(POSITION_TP);
         const long type = (long)PositionGetInteger(POSITION_TYPE); // buy/sell

         UpsertMeta(ticket, opened, sl);

         // ---------------------
         // 1) Weekend protection
         // ---------------------
         if(IsWeekendApproaching(m_weekend_close_mins))
         {
            if(profit < 0)
            {
               ClosePosition(ticket, "WeekendClose");
               continue;
            }
            // if profit and approaching close: close if net profit threshold reached
            if(profit >= m_min_net_profit)
            {
               ClosePosition(ticket, "WeekendClose(Profit)" );
               continue;
            }
         }

         // ---------------------
         // 2) Profit-protect close before big news
         // ---------------------
         if(m_news != NULL && profit > 0)
         {
            string ev; datetime et;
            if(m_news.HasHighImpactNewsWithinHours(m_profit_protect_hours, ev, et))
            {
               if(profit >= m_min_net_profit)
               {
                  ClosePosition(ticket, "ProfitProtect-News:" + ev);
                  continue;
               }
            }
         }

         // ---------------------
         // 3) Loss time-window close (30-60 mins)
         // ---------------------
         if(profit < 0)
         {
            const int alive_mins = (int)((TimeCurrent() - opened) / 60);
            if(alive_mins >= m_loss_window_mins)
            {
               ClosePosition(ticket, "LossWindow");
               continue;
            }
         }

         // ---------------------
         // 4) H1 candle-count trailing (structure-lite)
         //    We trail behind last H1 swing (local min/max) with buffer
         // ---------------------
         const int closed_h1 = ClosedH1CandlesSince(sym, opened);
         if(closed_h1 >= m_trail_after_h1_candles)
         {
            // build a simple trail based on last closed H1 candle low/high
            double new_sl = sl;
            if(type == POSITION_TYPE_BUY)
            {
               double last_low = iLow(sym, PERIOD_H1, 1);
               new_sl = last_low - (m_trail_buffer_pips * PipSize(sym));
               // never loosen
               if(new_sl > sl && new_sl < SymbolInfoDouble(sym, SYMBOL_BID))
               {
                  if(ModifySLTP(sym, ticket, new_sl, tp))
                     Print("[Trailing] BUY ticket=",ticket," newSL=",DoubleToString(new_sl,_Digits));
               }
            }
            else if(type == POSITION_TYPE_SELL)
            {
               double last_high = iHigh(sym, PERIOD_H1, 1);
               new_sl = last_high + (m_trail_buffer_pips * PipSize(sym));
               // never loosen
               if((sl==0.0 || new_sl < sl) && new_sl > SymbolInfoDouble(sym, SYMBOL_ASK))
               {
                  if(ModifySLTP(sym, ticket, new_sl, tp))
                     Print("[Trailing] SELL ticket=",ticket," newSL=",DoubleToString(new_sl,_Digits));
               }
            }
         }
      }
   }
};

// ------------------------
// Implementation helpers
// ------------------------
int CTradeManagerV2::FindMetaIndex(const ulong ticket)
{
   for(int i=0;i<ArraySize(m_meta);i++) if(m_meta[i].ticket==ticket) return i;
   return -1;
}

void CTradeManagerV2::UpsertMeta(const ulong ticket, const datetime opened, const double last_sl)
{
   const int idx = FindMetaIndex(ticket);
   if(idx >= 0)
   {
      m_meta[idx].opened_time = opened;
      m_meta[idx].last_sl = last_sl;
      return;
   }
   const int n = ArraySize(m_meta);
   ArrayResize(m_meta, n+1);
   m_meta[n].ticket = ticket;
   m_meta[n].opened_time = opened;
   m_meta[n].last_sl = last_sl;
}

bool CTradeManagerV2::IsWeekendApproaching(const int minutes_before_close) const
{
   // Broker time
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   // dt.day_of_week: 0=Sun .. 5=Fri .. 6=Sat
   if(dt.day_of_week != 5) return false; // only Friday

   // Broker close time (configurable)
   const int now_minutes = dt.hour*60 + dt.min;
   const int close_minutes = m_weekend_close_hour*60 + m_weekend_close_minute;
   return (close_minutes - now_minutes) <= minutes_before_close;
}

int CTradeManagerV2::ClosedH1CandlesSince(const string symbol, const datetime since_time) const
{
   // Count closed H1 candles whose close time > since_time
   datetime times[];
   const int copied = CopyTime(symbol, PERIOD_H1, since_time, TimeCurrent(), times);
   if(copied <= 0) return 0;

   // CopyTime includes bars that start at/after since_time; we want CLOSED candles count
   // so subtract 1 for the currently forming candle if included.
   int count = copied;
   // If the latest time equals current H1 bar open, reduce
   datetime cur_open = iTime(symbol, PERIOD_H1, 0);
   if(copied > 0 && times[0] == cur_open) count -= 1;
   return MathMax(0, count);
}

double CTradeManagerV2::PipSize(const string symbol) const
{
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5) return point * 10.0;
   return point;
}

bool CTradeManagerV2::ClosePosition(const ulong ticket, const string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   const string sym = PositionGetString(POSITION_SYMBOL);

   m_trade.SetExpertMagicNumber(m_magic);
   const bool ok = m_trade.PositionClose(sym);
   if(ok)
      Print("[Close] ticket=",ticket," reason=",reason);
   else
      Print("[Close-Fail] ticket=",ticket," reason=",reason," err=",GetLastError());
   return ok;
}

bool CTradeManagerV2::ModifySLTP(const string symbol, const ulong ticket, const double new_sl, const double tp)
{
   if(!PositionSelectByTicket(ticket)) return false;
   m_trade.SetExpertMagicNumber(m_magic);
   const bool ok = m_trade.PositionModify(symbol, new_sl, tp);
   if(!ok)
      Print("[Modify-Fail] ticket=",ticket," err=",GetLastError());
   return ok;
}
