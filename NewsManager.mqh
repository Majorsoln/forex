//+------------------------------------------------------------------+
//|                                                 NewsManager.mqh  |
//|                        News Event Management System              |
//|                    Economic Calendar Integration                 |
//|                     FIXED: Proper date handling for backtest   |
//+------------------------------------------------------------------+
#property copyright "MajorOne News Manager"
#property version   "1.10"
#property strict

#include <Arrays\ArrayObj.mqh>

//+------------------------------------------------------------------+
//| News Impact Levels                                               |
//+------------------------------------------------------------------+
enum ENUM_NEWS_IMPACT
{
    NEWS_IMPACT_LOW,      // Low impact
    NEWS_IMPACT_MEDIUM,   // Medium impact
    NEWS_IMPACT_HIGH      // High impact
};

//+------------------------------------------------------------------+
//| News Event Structure                                             |
//+------------------------------------------------------------------+
struct NewsEvent
{
    datetime time;           // Event time
    string   currency;       // Currency affected
    string   title;          // Event title
    ENUM_NEWS_IMPACT impact; // Impact level
    string   actual;         // Actual value
    string   forecast;       // Forecast value
    string   previous;       // Previous value
};

//+------------------------------------------------------------------+
//| News Manager Class                                               |
//+------------------------------------------------------------------+
class CNewsManager
{
private:
    // Configuration
    int         m_high_impact_mins_before;
    int         m_high_impact_mins_after;
    int         m_medium_impact_mins_before;
    int         m_medium_impact_mins_after;
    int         m_low_impact_mins_before;
    int         m_low_impact_mins_after;
    
    // News events
    NewsEvent   m_events[];
    int         m_event_count;
    
    // Current status
    bool        m_is_news_time;
    string      m_current_news_event;
    datetime    m_last_check_time;
    
    // Currency filter
    string      m_watched_currencies;
    
    //  NEW: Backtest mode flag
    bool        m_is_backtesting;
    
public:
    //+------------------------------------------------------------------+
    //| Constructor                                                      |
    //+------------------------------------------------------------------+
    CNewsManager()
    {
        m_high_impact_mins_before = 30;
        m_high_impact_mins_after = 30;
        m_medium_impact_mins_before = 15;
        m_medium_impact_mins_after = 15;
        m_low_impact_mins_before = 0;
        m_low_impact_mins_after = 0;
        
        m_event_count = 0;
        m_is_news_time = false;
        m_current_news_event = "";
        m_last_check_time = 0;
        
        // Watch major currencies
        m_watched_currencies = "USD,EUR,GBP,JPY,CHF,CAD,AUD,NZD";
        
        ArrayResize(m_events, 0);
        
        //  Detect backtest mode
        #ifdef __MQL5__
        m_is_backtesting = (MQLInfoInteger(MQL_TESTER) != 0);
        #else
        m_is_backtesting = IsTesting();
        #endif

    }
    
    //+------------------------------------------------------------------+
    //| Initialize News Manager                                          |
    //+------------------------------------------------------------------+
    void Initialize()
    {
        LoadNewsEvents();
        
        if(m_is_backtesting)
        {
            Print("");
            Print("NEWS MANAGER - BACKTEST MODE");
            Print("");
            Print("Total Events Loaded: ", m_event_count);
            Print("Events will be properly filtered by date");
            Print("");
        }
        else
        {
            Print("News Manager initialized with ", m_event_count, " events");
        }
    }
    
    //+------------------------------------------------------------------+
    //| Load News Events -  FIXED: Realistic dates                    |
    //+------------------------------------------------------------------+
    void LoadNewsEvents()
    {
        // Clear existing events
        ArrayResize(m_events, 0);
        m_event_count = 0;
        
        //  In production, this would connect to an economic calendar API
        //  For backtest/demo: Create realistic events based on typical schedule
        
        datetime current_time = TimeCurrent();
        MqlDateTime dt;
        TimeToStruct(current_time, dt);
        
        //  Create events for the CURRENT WEEK ONLY (not future offsets)
        // This simulates a real calendar that only has events for specific dates
        
        // Get Monday of current week
        int day_of_week = dt.day_of_week;  // 0=Sunday, 1=Monday, etc.
        datetime week_start = current_time - (day_of_week * 86400);  // Go back to Sunday
        
        //  Add realistic weekly events
        
        // MONDAY - Asian Session
        AddEventOnDay(week_start, 1, 1, 30, "JPY", "BoJ Monetary Policy", NEWS_IMPACT_HIGH);
        
        // TUESDAY - European Session  
        AddEventOnDay(week_start, 2, 9, 0, "EUR", "German CPI", NEWS_IMPACT_MEDIUM);
        AddEventOnDay(week_start, 2, 14, 30, "USD", "CB Consumer Confidence", NEWS_IMPACT_MEDIUM);
        
        // WEDNESDAY - US Session
        AddEventOnDay(week_start, 3, 14, 15, "USD", "ADP Employment", NEWS_IMPACT_HIGH);
        AddEventOnDay(week_start, 3, 19, 0, "USD", "FOMC Minutes", NEWS_IMPACT_HIGH);
        
        // THURSDAY - Multiple Sessions
        AddEventOnDay(week_start, 4, 8, 30, "GBP", "UK GDP", NEWS_IMPACT_HIGH);
        AddEventOnDay(week_start, 4, 13, 30, "USD", "Jobless Claims", NEWS_IMPACT_MEDIUM);
        AddEventOnDay(week_start, 4, 19, 0, "USD", "Fed Chair Speech", NEWS_IMPACT_HIGH);
        
        // FRIDAY - Major US Data
        AddEventOnDay(week_start, 5, 13, 30, "USD", "Non-Farm Payrolls", NEWS_IMPACT_HIGH);
        AddEventOnDay(week_start, 5, 13, 30, "USD", "Unemployment Rate", NEWS_IMPACT_HIGH);
        
        //  Add next week's events too (for lookahead)
        datetime next_week = week_start + (7 * 86400);
        
        AddEventOnDay(next_week, 1, 1, 30, "JPY", "BoJ Monetary Policy", NEWS_IMPACT_HIGH);
        AddEventOnDay(next_week, 3, 14, 15, "USD", "ADP Employment", NEWS_IMPACT_HIGH);
        AddEventOnDay(next_week, 4, 8, 30, "GBP", "UK GDP", NEWS_IMPACT_HIGH);
        AddEventOnDay(next_week, 5, 13, 30, "USD", "Non-Farm Payrolls", NEWS_IMPACT_HIGH);
        
        // Sort events by time
        SortEventsByTime();
        
        Print(" Loaded ", m_event_count, " realistic news events");
        Print("   Week Start: ", TimeToString(week_start, TIME_DATE));
        Print("   Current Time: ", TimeToString(current_time, TIME_DATE|TIME_MINUTES));
    }
    
    //+------------------------------------------------------------------+
    //|  NEW: Add event on specific day/time                          |
    //+------------------------------------------------------------------+
    void AddEventOnDay(datetime week_start, int day_offset, int hour, int minute, 
                       string currency, string title, ENUM_NEWS_IMPACT impact)
    {
        MqlDateTime dt;
        TimeToStruct(week_start, dt);
        
        // Add day offset
        dt.day += day_offset;
        dt.hour = hour;
        dt.min = minute;
        dt.sec = 0;
        
        datetime event_time = StructToTime(dt);
        
        // Only add if event is in the future or recent past (within 1 week)
        datetime current_time = TimeCurrent();
        if(event_time > current_time - (7 * 86400))  // Within last week or future
        {
            int size = ArraySize(m_events);
            ArrayResize(m_events, size + 1);
            
            m_events[size].time = event_time;
            m_events[size].currency = currency;
            m_events[size].title = title;
            m_events[size].impact = impact;
            m_events[size].actual = "";
            m_events[size].forecast = "";
            m_events[size].previous = "";
            
            m_event_count++;
        }
    }
    
    //+------------------------------------------------------------------+
    //| Check if News Time                                               |
    //+------------------------------------------------------------------+
    bool IsNewsTime()
    {
        datetime current_time = TimeCurrent();
        
        // Check only once per minute
        if(current_time - m_last_check_time < 60)
            return m_is_news_time;
        
        m_last_check_time = current_time;
        m_is_news_time = false;
        m_current_news_event = "";
        
        // Get current symbol currencies
        string symbol = _Symbol;
        string base_currency = StringSubstr(symbol, 0, 3);
        string quote_currency = StringSubstr(symbol, 3, 3);
        
        // Check each event
        for(int i = 0; i < m_event_count; i++)
        {
            // Check if event affects our currencies
            if(StringFind(m_events[i].currency, base_currency) == -1 &&
               StringFind(m_events[i].currency, quote_currency) == -1)
                continue;
            
            // Get time window based on impact
            int mins_before = 0, mins_after = 0;
            
            switch(m_events[i].impact)
            {
                case NEWS_IMPACT_HIGH:
                    mins_before = m_high_impact_mins_before;
                    mins_after = m_high_impact_mins_after;
                    break;
                    
                case NEWS_IMPACT_MEDIUM:
                    mins_before = m_medium_impact_mins_before;
                    mins_after = m_medium_impact_mins_after;
                    break;
                    
                case NEWS_IMPACT_LOW:
                    mins_before = m_low_impact_mins_before;
                    mins_after = m_low_impact_mins_after;
                    break;
            }
            
            // Check if within news window
            datetime event_start = m_events[i].time - mins_before * 60;
            datetime event_end = m_events[i].time + mins_after * 60;
            
            if(current_time >= event_start && current_time <= event_end)
            {
                m_is_news_time = true;
                m_current_news_event = m_events[i].title;
                
                //  Log occasionally (not every tick)
                static datetime last_log = 0;
                if(current_time - last_log > 300)  // Every 5 minutes
                {
                    Print(" News Filter Active: ", m_current_news_event, 
                          " (", m_events[i].currency, ") at ", 
                          TimeToString(m_events[i].time, TIME_DATE|TIME_MINUTES));
                    last_log = current_time;
                }
                
                return true;
            }
        }
        
        return false;
    }
    
    //+------------------------------------------------------------------+
    //| Get Next News Event                                              |
    //+------------------------------------------------------------------+
    bool GetNextNewsEvent(NewsEvent &event)
    {
        datetime current_time = TimeCurrent();
        
        for(int i = 0; i < m_event_count; i++)
        {
            if(m_events[i].time > current_time)
            {
                event = m_events[i];
                return true;
            }
        }
        
        return false;
    }
    
    //+------------------------------------------------------------------+
    //| Get Time Until Next Event                                        |
    //+------------------------------------------------------------------+
    int GetMinutesUntilNextEvent()
    {
        NewsEvent next_event;
        if(GetNextNewsEvent(next_event))
        {
            datetime current_time = TimeCurrent();
            return (int)((next_event.time - current_time) / 60);
        }
        
        return 999999;
    }
    
    //+------------------------------------------------------------------+
    //| Sort Events by Time                                              |
    //+------------------------------------------------------------------+
    void SortEventsByTime()
    {
        for(int i = 0; i < m_event_count - 1; i++)
        {
            for(int j = 0; j < m_event_count - i - 1; j++)
            {
                if(m_events[j].time > m_events[j + 1].time)
                {
                    NewsEvent temp = m_events[j];
                    m_events[j] = m_events[j + 1];
                    m_events[j + 1] = temp;
                }
            }
        }
    }
    
    //+------------------------------------------------------------------+
    //| Set Impact Filters                                               |
    //+------------------------------------------------------------------+
    void SetImpactFilters(int high_before, int high_after, 
                          int medium_before, int medium_after,
                          int low_before, int low_after)
    {
        m_high_impact_mins_before = high_before;
        m_high_impact_mins_after = high_after;
        m_medium_impact_mins_before = medium_before;
        m_medium_impact_mins_after = medium_after;
        m_low_impact_mins_before = low_before;
        m_low_impact_mins_after = low_after;
    }
    
    //+------------------------------------------------------------------+
    //| Get Current News Status                                          |
    //+------------------------------------------------------------------+
    string GetNewsStatus()
    {
        if(m_is_news_time)
            return "News Filter Active: " + m_current_news_event;
        
        int mins_until = GetMinutesUntilNextEvent();
        if(mins_until < 60)
        {
            NewsEvent next_event;
            GetNextNewsEvent(next_event);
            return "Next Event in " + IntegerToString(mins_until) + " mins: " + next_event.title;
        }
        
        return "No news events in next hour";
    }
    
    //+------------------------------------------------------------------+
    //| Clean Old Events                                                 |
    //+------------------------------------------------------------------+
    void CleanOldEvents()
    {
        datetime current_time = TimeCurrent();
        datetime cutoff_time = current_time - 86400;
        
        NewsEvent temp[];
        ArrayResize(temp, 0);
        int new_count = 0;
        
        for(int i = 0; i < m_event_count; i++)
        {
            if(m_events[i].time > cutoff_time)
            {
                int size = ArraySize(temp);
                ArrayResize(temp, size + 1);
                temp[size] = m_events[i];
                new_count++;
            }
        }
        
        ArrayResize(m_events, new_count);
        for(int i = 0; i < new_count; i++)
        {
            m_events[i] = temp[i];
        }
        
        m_event_count = new_count;
    }
    
    //+------------------------------------------------------------------+
    //| Reload Events (Called periodically)                              |
    //+------------------------------------------------------------------+
    void ReloadEvents()
    {
        static datetime last_reload = 0;
        datetime current_time = TimeCurrent();
        
        if(current_time - last_reload > 3600)
        {
            CleanOldEvents();
            LoadNewsEvents();
            last_reload = current_time;
        }
    }

    //+------------------------------------------------------------------+
    //| V2.0 Helpers: Pre-trade gate and Profit-Protect lookahead      |
    //+------------------------------------------------------------------+

    // Return true if there is any HIGH impact event within the next N minutes
    bool NoNewTradesWindow(const int minutes_ahead, string &event_title, datetime &event_time)
    {
        event_title = "";
        event_time  = 0;
        if(minutes_ahead <= 0) return false;

        datetime now = TimeCurrent();
        datetime end = now + (minutes_ahead * 60);

        for(int i=0; i<m_event_count; i++)
        {
            if(m_events[i].impact != NEWS_IMPACT_HIGH) continue;
            if(m_events[i].time >= now && m_events[i].time <= end)
            {
                event_title = m_events[i].title + " (" + m_events[i].currency + ")";
                event_time  = m_events[i].time;
                return true;
            }
        }
        return false;
    }

    // Return true if there is a HIGH impact event within the next N hours (used for profit-protect close)
    bool HasHighImpactNewsWithinHours(const int hours_ahead, string &event_title, datetime &event_time)
    {
        event_title = "";
        event_time  = 0;
        if(hours_ahead <= 0) return false;

        datetime now = TimeCurrent();
        datetime end = now + (hours_ahead * 3600);

        for(int i=0; i<m_event_count; i++)
        {
            if(m_events[i].impact != NEWS_IMPACT_HIGH) continue;
            if(m_events[i].time >= now && m_events[i].time <= end)
            {
                event_title = m_events[i].title + " (" + m_events[i].currency + ")";
                event_time  = m_events[i].time;
                return true;
            }
        }
        return false;
    }

};
