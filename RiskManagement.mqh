//+------------------------------------------------------------------+
//|                               DRA_RiskManagement_Tracked.mqh     |
//|          Enhanced DRA Risk Manager with Complete DLR Tracking    |
//|                    Every rule check and action is logged         |
//|                                                                   |
//| CHANGELOG v3.02:                                                  |
//|   - FIX: pip_value now correctly uses PIPS not POINTS            |
//|   - For 5-digit brokers: 1 pip = 10 points                       |
//|   - This fixes 10x over-leveraging on 5-digit accounts           |
//+------------------------------------------------------------------+
#property copyright "MajorOne DRA Risk Management v4"
#property version   "4.00"
#property strict

#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include "DLRTracker.mqh"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS FOR STRATEGY TESTER OPTIMIZATION                 |
//+------------------------------------------------------------------+
input group "========== RISK MANAGEMENT: DLR SETTINGS =========="
input double InpRiskDailyLossPct = 4.5;          // Daily Loss Risk % (DLR)
input int    InpRiskMaxTradesPerDay = 25;        // Max Trades Per Day
input int    InpRiskMaxOpenPositions = 15;       // Max Open Positions
input bool   InpRiskEnableDLRTracking = true;    // Enable DLR CSV Tracking


//+------------------------------------------------------------------+
//| DRA Risk Manager with Full Tracking                              |
//+------------------------------------------------------------------+
class CDRARiskManager
{
private:
    // Fixed Reference Balance (Anchor)
    double          m_initial_balance;
    
    // Daily Loss Risk Parameters
    double          m_daily_loss_percent;
    double          m_dlr_base;
    double          m_dlr_current;
    
    // DRA Parameters
    int             m_max_trades_per_day;
    int             m_max_open_positions;
    double          m_r_base;
    double          m_r_cap;
    double          m_r_min;
    
    // Profit Buffer
    double          m_closed_profit_today;
    double          m_profit_buffer;
    
    // Daily Tracking
    double          m_closed_pl_today;
    double          m_floating_pl;
    double          m_total_commissions;
    double          m_total_swaps;
    double          m_current_daily_loss;
    
    // Trade Tracking
    int             m_trades_opened_today;
    int             m_current_positions;
    
    // Reset tracking
    datetime        m_last_reset_time;
    
    // DLR TRACKER - NEW
    CDLRTracker     *m_tracker;
    bool            m_tracking_enabled;
    string          m_symbol;
    
    // Helpers
    CAccountInfo    m_account;
    CSymbolInfo     m_symbol_info;
    CPositionInfo   m_position;
    
    // Last block reason for detailed logging
    string          m_last_block_reason;
    
    // Last calculated risk allocation
    double          m_last_risk_allocated;

public:
    //+------------------------------------------------------------------+
    //| Constructor                                                      |
    //+------------------------------------------------------------------+
    CDRARiskManager()
    {
        m_initial_balance = 0;
        m_daily_loss_percent = InpRiskDailyLossPct;
        m_dlr_base = 0;
        m_dlr_current = 0;
        
        m_max_trades_per_day = InpRiskMaxTradesPerDay;
        m_max_open_positions = InpRiskMaxOpenPositions;
        m_r_base = 0;
        m_r_cap = 0;
        m_r_min = 0;
        
        m_closed_profit_today = 0;
        m_profit_buffer = 0;
        
        m_closed_pl_today = 0;
        m_floating_pl = 0;
        m_total_commissions = 0;
        m_total_swaps = 0;
        m_current_daily_loss = 0;
        
        m_trades_opened_today = 0;
        m_current_positions = 0;
        m_last_reset_time = 0;
        
        m_tracker = NULL;
        m_tracking_enabled = false;
        m_symbol = "";
        m_last_block_reason = "";
        m_last_risk_allocated = 0;
    }
    
    //+------------------------------------------------------------------+
    //| Destructor                                                       |
    //+------------------------------------------------------------------+
    ~CDRARiskManager()
    {
        if(m_tracker != NULL)
        {
            // Export final log
            m_tracker.ExportFullLog();
            Print(m_tracker.GetStatisticsReport());
            delete m_tracker;
        }
    }
    
    //+------------------------------------------------------------------+
    //| Initialize with Tracking                                         |
    //+------------------------------------------------------------------+
    bool Initialize(double initial_balance, string symbol = "", bool enable_tracking = true)
    {
        m_initial_balance = initial_balance;
        m_symbol = (symbol == "") ? _Symbol : symbol;
        m_tracking_enabled = enable_tracking;
        
        // Calculate DLR_base = 4.5%  Initial Balance
        m_dlr_base = m_initial_balance * m_daily_loss_percent / 100.0;
        m_dlr_current = m_dlr_base;
        
        // Calculate DRA parameters
        m_r_base = m_dlr_base / m_max_trades_per_day;
        m_r_cap = 2.0 * m_r_base;
        m_r_min = 0.25 * m_r_base;
        
        m_last_reset_time = TimeCurrent();
        
        // Initialize tracker
        if(m_tracking_enabled)
        {
            m_tracker = new CDLRTracker();
            if(!m_tracker.Initialize(m_symbol, true))
            {
                Print("WARNING: DLR Tracker initialization failed");
                m_tracking_enabled = false;
            }
            else
            {
                Print("+ DLR Tracker initialized with full logging");
            }
        }
        
        Print("");
        Print("DRA Risk Manager Initialized (TRACKED)");
        Print("");
        Print("Fixed Reference Balance: $", DoubleToString(m_initial_balance, 2));
        Print("Daily Loss Limit (4.5%): $", DoubleToString(m_dlr_base, 2));
        Print("Max Trades Per Day: ", m_max_trades_per_day);
        Print("Max Open Positions: ", m_max_open_positions);
        Print("");
        Print("Base Risk Per Trade: $", DoubleToString(m_r_base, 2));
        Print("Risk Cap (Max): $", DoubleToString(m_r_cap, 2));
        Print("Risk Min: $", DoubleToString(m_r_min, 2));
        Print("");
        Print("Tracking Enabled: ", m_tracking_enabled ? "YES" : "NO");
        Print("");
        
        return true;
    }
    
    //+------------------------------------------------------------------+
    //| Calculate Lot Size with Full Tracking                            |
    //+------------------------------------------------------------------+
    double CalculateLotSize(string symbol, double sl_pips, double confidence,
                           double credibility, double signal_quality, double regime_fit)
    {
        // Validate SL
        if(sl_pips <= 0)
        {
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogRuleCheck(DLR_RULE_STOP_LOSS_VALID, false, sl_pips, 0,
                                       m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                       m_current_positions, m_r_base, m_r_cap, m_r_min,
                                       "TRADE_REJECTED");
                m_tracker.LogSystemError("Invalid stop loss pips: " + DoubleToString(sl_pips, 2), 
                                        "LOT_SIZE_ZERO");
            }
            Print("ERROR: Invalid stop loss pips: ", sl_pips);
            return 0;
        }
        
        if(!m_symbol_info.Name(symbol))
        {
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogSystemError("Cannot load symbol: " + symbol, "LOT_SIZE_ZERO");
            }
            return 0;
        }
        
        // Check if can trade (with detailed logging)
        if(!CanTrade())
        {
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogTradeBlocked(m_last_block_reason, m_dlr_current, m_current_daily_loss,
                                         m_trades_opened_today, m_current_positions,
                                         m_r_base, m_r_cap, m_r_min);
            }
            return 0;
        }
        
        // Calculate allocated risk for this trade
        double r_trade = CalculateTradeRiskAllocation(confidence, credibility, signal_quality, regime_fit);
        
        // Store for later access
        m_last_risk_allocated = r_trade;
        
        if(r_trade <= 0)
        {
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogSystemError("Risk allocation returned zero", "LOT_SIZE_ZERO");
            }
            return 0;
        }
        
        // Calculate lot size from risk allocation
        // FIX v3.02: Use PIPS not POINTS for pip_value calculation
        // For 5-digit brokers: 1 pip = 10 points
        int digits = m_symbol_info.Digits();
        double pip_multiplier = (digits == 3 || digits == 5) ? 10.0 : 1.0;
        double pip_size = m_symbol_info.Point() * pip_multiplier;
        double pip_value = m_symbol_info.TickValue() * (pip_size / m_symbol_info.TickSize());
        
        // Validate pip_value
        if(pip_value <= 0)
        {
            Print("ERROR: Invalid pip_value calculated: ", pip_value);
            Print("  TickValue: ", m_symbol_info.TickValue());
            Print("  pip_size: ", pip_size);
            Print("  TickSize: ", m_symbol_info.TickSize());
            return 0;
        }
        
        double lot_size = r_trade / (sl_pips * pip_value);
        
        // Normalize to broker specifications
        double min_lot = m_symbol_info.LotsMin();
        double max_lot = m_symbol_info.LotsMax();
        double lot_step = m_symbol_info.LotsStep();
        
        lot_size = MathFloor(lot_size / lot_step) * lot_step;
        
        // Check bounds
        bool lot_valid = true;
        string lot_action = "";
        
        if(lot_size < min_lot)
        {
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogRuleCheck(DLR_RULE_LOT_SIZE_BOUNDS, false, lot_size, min_lot,
                                       m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                       m_current_positions, m_r_base, m_r_cap, m_r_min,
                                       "LOT_BELOW_MIN");
            }
            Print("WARNING: Calculated lot size below minimum: ", lot_size, " < ", min_lot);
            lot_size = min_lot;
            lot_action = "ADJUSTED_TO_MIN";
        }
        
        if(lot_size > max_lot)
        {
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogRuleCheck(DLR_RULE_LOT_SIZE_BOUNDS, false, lot_size, max_lot,
                                       m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                       m_current_positions, m_r_base, m_r_cap, m_r_min,
                                       "LOT_ABOVE_MAX");
            }
            lot_size = max_lot;
            lot_action = "CAPPED_TO_MAX";
        }
        
        // Log successful lot calculation
        if(m_tracking_enabled && m_tracker != NULL && lot_action == "")
        {
            m_tracker.LogRuleCheck(DLR_RULE_LOT_SIZE_BOUNDS, true, lot_size, max_lot,
                                   m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                   m_current_positions, m_r_base, m_r_cap, m_r_min,
                                   "LOT_SIZE_OK");
        }
        
        Print("DRA Lot Calculation:");
        Print("  Risk Allocated: $", DoubleToString(r_trade, 2));
        Print("  SL Pips: ", DoubleToString(sl_pips, 1));
        Print("  Pip Multiplier: ", DoubleToString(pip_multiplier, 0), " (", digits, "-digit broker)");
        Print("  Pip Value: $", DoubleToString(pip_value, 4), " per pip per lot");
        Print("  Expected Risk: $", DoubleToString(lot_size * sl_pips * pip_value, 2));
        Print("  Final Lot Size: ", DoubleToString(lot_size, 2));
        if(lot_action != "")
            Print("  Adjustment: ", lot_action);
        
        return lot_size;
    }
    
    //+------------------------------------------------------------------+
    //| Calculate Trade Risk Allocation with Logging                     |
    //+------------------------------------------------------------------+
    double CalculateTradeRiskAllocation(double confidence, double credibility,
                                        double signal_quality, double regime_fit)
    {
        // Weight distribution
        double weight_confidence = 0.2167;
        double weight_credibility = 0.2;
        double weight_signal = 0.25;
        double weight_regime = 0.3333;
        
        // Inputs are expected normalized 0..100 (V2.0)
        confidence    = MathMax(0.0, MathMin(100.0, confidence));
        credibility   = MathMax(0.0, MathMin(100.0, credibility));
        signal_quality= MathMax(0.0, MathMin(100.0, signal_quality));
        regime_fit    = MathMax(0.0, MathMin(100.0, regime_fit));

        // Calculate composite score in 0..100
        double composite_0_100 =
            (confidence * weight_confidence) +
            (credibility * weight_credibility) +
            (signal_quality * weight_signal) +
            (regime_fit * weight_regime);

        // Convert to 0..1
        double composite_score = MathMax(0.0, MathMin(1.0, composite_0_100/100.0));
        
        // Map composite score to risk allocation range [r_min, r_cap]
        double r_trade = m_r_min + (composite_score * (m_r_cap - m_r_min));
        
        // Validate allocation is within bounds
        bool allocation_valid = (r_trade >= m_r_min && r_trade <= m_r_cap);
        
        if(m_tracking_enabled && m_tracker != NULL)
        {
            m_tracker.LogRuleCheck(DLR_RULE_RISK_ALLOCATION, allocation_valid, r_trade, m_r_cap,
                                   m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                   m_current_positions, m_r_base, m_r_cap, m_r_min,
                                   "COMPOSITE_SCORE:" + DoubleToString(composite_score*100.0, 1) + "%" +
                                   " | inputs(0..100): conf="+DoubleToString(confidence,1)+
                                   ", cred="+DoubleToString(credibility,1)+
                                   ", qual="+DoubleToString(signal_quality,1)+
                                   ", regime="+DoubleToString(regime_fit,1));
        }
        
        Print(" DRA Weight Calculation ");
        Print("Confidence: ", DoubleToString(confidence * 100, 1), "%");
        Print("Credibility: ", DoubleToString(credibility * 100, 1), "%");
        Print("Signal Quality: ", DoubleToString(signal_quality * 100, 1), "%");
        Print("Regime Fit: ", DoubleToString(regime_fit * 100, 1), "%");
        Print("Composite Score: ", DoubleToString(composite_score * 100, 1), "%");
        Print("Risk Allocation: $", DoubleToString(r_trade, 2));
        Print("Range: $", DoubleToString(m_r_min, 2), " - $", DoubleToString(m_r_cap, 2));
        
        return r_trade;
    }
    
    //+------------------------------------------------------------------+
    //| Check if Can Trade (All Safety Checks with Full Logging)        |
    //+------------------------------------------------------------------+
    bool CanTrade()
    {
        m_last_block_reason = "";
        
        // Check daily reset first
        CheckDailyReset();
        
        // Update current state
        UpdateDailyLossConsumption();
        UpdateProfitBuffer();
        UpdatePositionCount();
        
        // CHECK 1: Daily Loss Limit
        bool dlr_passed = (m_current_daily_loss < m_dlr_current);
        if(m_tracking_enabled && m_tracker != NULL)
        {
            m_tracker.LogRuleCheck(DLR_RULE_DAILY_LOSS_LIMIT, dlr_passed, 
                                   m_current_daily_loss, m_dlr_current,
                                   m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                   m_current_positions, m_r_base, m_r_cap, m_r_min,
                                   dlr_passed ? "CONTINUE" : "BLOCK_TRADING");
        }
        
        if(!dlr_passed)
        {
            m_last_block_reason = "Daily loss limit reached ($" + 
                                 DoubleToString(m_current_daily_loss, 2) + " >= $" +
                                 DoubleToString(m_dlr_current, 2) + ")";
            Print(" BLOCKED: ", m_last_block_reason);
            return false;
        }
        
        // CHECK 2: Max trades per day
        bool trades_passed = (m_trades_opened_today < m_max_trades_per_day);
        if(m_tracking_enabled && m_tracker != NULL)
        {
            m_tracker.LogRuleCheck(DLR_RULE_MAX_TRADES_PER_DAY, trades_passed,
                                   m_trades_opened_today, m_max_trades_per_day,
                                   m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                   m_current_positions, m_r_base, m_r_cap, m_r_min,
                                   trades_passed ? "CONTINUE" : "BLOCK_TRADING");
        }
        
        if(!trades_passed)
        {
            m_last_block_reason = "Max trades per day reached (" + 
                                 IntegerToString(m_trades_opened_today) + "/" +
                                 IntegerToString(m_max_trades_per_day) + ")";
            Print(" BLOCKED: ", m_last_block_reason);
            return false;
        }
        
        // CHECK 3: Max open positions
        bool positions_passed = (m_current_positions < m_max_open_positions);
        if(m_tracking_enabled && m_tracker != NULL)
        {
            m_tracker.LogRuleCheck(DLR_RULE_MAX_OPEN_POSITIONS, positions_passed,
                                   m_current_positions, m_max_open_positions,
                                   m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                   m_current_positions, m_r_base, m_r_cap, m_r_min,
                                   positions_passed ? "CONTINUE" : "BLOCK_TRADING");
        }
        
        if(!positions_passed)
        {
            m_last_block_reason = "Max open positions reached (" +
                                 IntegerToString(m_current_positions) + "/" +
                                 IntegerToString(m_max_open_positions) + ")";
            Print(" BLOCKED: ", m_last_block_reason);
            return false;
        }
        
        // CHECK 4: Sufficient margin
        double free_margin = m_account.FreeMargin();
        double margin_requirement = m_initial_balance * 0.20;
        bool margin_passed = (free_margin >= margin_requirement);
        
        if(m_tracking_enabled && m_tracker != NULL)
        {
            m_tracker.LogRuleCheck(DLR_RULE_FREE_MARGIN, margin_passed,
                                   free_margin, margin_requirement,
                                   m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                   m_current_positions, m_r_base, m_r_cap, m_r_min,
                                   margin_passed ? "CONTINUE" : "BLOCK_TRADING");
        }
        
        if(!margin_passed)
        {
            m_last_block_reason = "Insufficient free margin ($" +
                                 DoubleToString(free_margin, 2) + " < $" +
                                 DoubleToString(margin_requirement, 2) + ")";
            Print(" BLOCKED: ", m_last_block_reason);
            return false;
        }
        
        // All checks passed
        if(m_tracking_enabled && m_tracker != NULL)
        {
            m_tracker.LogRuleCheck(DLR_RULE_COMPOSITE, true, 0, 0,
                                   m_dlr_current, m_current_daily_loss, m_trades_opened_today,
                                   m_current_positions, m_r_base, m_r_cap, m_r_min,
                                   "ALL_CHECKS_PASSED");
        }
        
        return true;
    }
    
    //+------------------------------------------------------------------+
    //| On Trade Open - Register New Trade                               |
    //+------------------------------------------------------------------+
    void OnTradeOpen(double lot_size, double risk_allocated)
    {
        m_trades_opened_today++;
        
        if(m_tracking_enabled && m_tracker != NULL)
        {
            m_tracker.LogTradeAllowed(lot_size, risk_allocated, m_dlr_current,
                                     m_current_daily_loss, m_trades_opened_today,
                                     m_current_positions, m_r_base, m_r_cap, m_r_min);
        }
        
        Print("Trade registered. Count today: ", m_trades_opened_today, "/", m_max_trades_per_day);
    }
    
    //+------------------------------------------------------------------+
    //| On Trade Close - Update P/L                                      |
    //+------------------------------------------------------------------+
    void OnTradeClose(double profit, double commission = 0, double swap = 0, ulong ticket = 0)
    {
        double old_closed_pl = m_closed_pl_today;
        double old_profit_buffer = m_profit_buffer;
        double old_dlr = m_dlr_current;
        
        m_closed_pl_today += profit;
        
        // Update profit buffer if positive
        if(profit > 0)
        {
            double old_closed_profit = m_closed_profit_today;
            m_closed_profit_today += profit;
            
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogParameterUpdate("closed_profit_today", old_closed_profit,
                                            m_closed_profit_today, "PROFITABLE_CLOSE");
            }
        }
        
        UpdateDailyLossConsumption();
        UpdateProfitBuffer();
        
        // Log the close with all details
        if(m_tracking_enabled && m_tracker != NULL)
        {
            m_tracker.LogPositionClose(ticket, profit, commission, swap,
                                      m_dlr_current, m_current_daily_loss, m_trades_opened_today);
            
            // Log if DLR was updated
            if(MathAbs(old_dlr - m_dlr_current) > 0.01)
            {
                m_tracker.LogParameterUpdate("DLR_current", old_dlr, m_dlr_current,
                                            "PROFIT_BUFFER_ADJUSTMENT");
            }
        }
        
        Print("Position closed. Closed P/L today: $", DoubleToString(m_closed_pl_today, 2));
    }
    
    //+------------------------------------------------------------------+
    //| Update Daily Loss Consumption                                    |
    //+------------------------------------------------------------------+
    void UpdateDailyLossConsumption()
    {
        m_floating_pl = 0;
        m_total_commissions = 0;
        m_total_swaps = 0;
        
        for(int i = 0; i < PositionsTotal(); i++)
        {
            if(m_position.SelectByIndex(i))
            {
                if(m_position.Symbol() == m_symbol)
                {
                    m_floating_pl += m_position.Profit();
                    m_total_commissions += m_position.Commission();
                    m_total_swaps += m_position.Swap();
                }
            }
        }
        
        // Total consumption (losses are positive)
        m_current_daily_loss = -m_closed_pl_today - m_floating_pl + m_total_commissions + m_total_swaps;
        
        if(m_current_daily_loss < 0) m_current_daily_loss = 0;
    }
    
    //+------------------------------------------------------------------+
    //| Update Profit Buffer (50% of Closed Profits)                    |
    //+------------------------------------------------------------------+
    void UpdateProfitBuffer()
    {
        double old_r_base = m_r_base;
        double old_r_cap = m_r_cap;
        double old_r_min = m_r_min;
        
        if(m_closed_profit_today > 0)
        {
            m_profit_buffer = m_closed_profit_today * 0.5;
            m_dlr_current = m_dlr_base + m_profit_buffer;
            
            // Recalculate DRA parameters
            m_r_base = m_dlr_current / m_max_trades_per_day;
            m_r_cap = 2.0 * m_r_base;
            m_r_min = 0.25 * m_r_base;
            
            // Log parameter changes if significant
            if(m_tracking_enabled && m_tracker != NULL)
            {
                if(MathAbs(old_r_base - m_r_base) > 0.01)
                {
                    m_tracker.LogParameterUpdate("r_base", old_r_base, m_r_base, "PROFIT_BUFFER_UPDATE");
                    m_tracker.LogParameterUpdate("r_cap", old_r_cap, m_r_cap, "PROFIT_BUFFER_UPDATE");
                    m_tracker.LogParameterUpdate("r_min", old_r_min, m_r_min, "PROFIT_BUFFER_UPDATE");
                }
            }
        }
        else
        {
            m_profit_buffer = 0;
            m_dlr_current = m_dlr_base;
            m_r_base = m_dlr_base / m_max_trades_per_day;
            m_r_cap = 2.0 * m_r_base;
            m_r_min = 0.25 * m_r_base;
        }
    }
    
    //+------------------------------------------------------------------+
    //| Update Position Count                                            |
    //+------------------------------------------------------------------+
    void UpdatePositionCount()
    {
        m_current_positions = 0;
        
        for(int i = 0; i < PositionsTotal(); i++)
        {
            if(m_position.SelectByIndex(i))
            {
                if(m_position.Symbol() == m_symbol)
                {
                    m_current_positions++;
                }
            }
        }
    }
    
    //+------------------------------------------------------------------+
    //| Check Daily Reset with Logging                                   |
    //+------------------------------------------------------------------+
    void CheckDailyReset()
    {
        MqlDateTime current_time, last_reset;
        TimeToStruct(TimeCurrent(), current_time);
        TimeToStruct(m_last_reset_time, last_reset);
        
        if(current_time.day != last_reset.day)
        {
            // Store old values for logging
            double old_dlr = m_dlr_current;
            double old_r_base = m_r_base;
            double old_r_cap = m_r_cap;
            double old_r_min = m_r_min;
            
            Print("");
            Print("DAILY RESET - New Trading Day");
            Print("");
            
            // Reset DLR
            m_dlr_base = m_initial_balance * m_daily_loss_percent / 100.0;
            m_dlr_current = m_dlr_base;
            
            // Clear profit buffer
            m_closed_profit_today = 0;
            m_profit_buffer = 0;
            
            // Reset daily counters
            m_closed_pl_today = 0;
            m_floating_pl = 0;
            m_total_commissions = 0;
            m_total_swaps = 0;
            m_current_daily_loss = 0;
            
            m_trades_opened_today = 0;
            
            // Reset DRA parameters
            m_r_base = m_dlr_base / m_max_trades_per_day;
            m_r_cap = 2.0 * m_r_base;
            m_r_min = 0.25 * m_r_base;
            
            m_last_reset_time = TimeCurrent();
            
            // Log the reset
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogDailyReset(m_dlr_current, m_r_base, m_r_cap, m_r_min);
            }
            
            Print("DLR Base Reset: $", DoubleToString(m_dlr_base, 2));
            Print("Trades Counter Reset: 0/", m_max_trades_per_day);
            Print("DRA Parameters Reset:");
            Print("  r_base: $", DoubleToString(m_r_base, 2));
            Print("  r_cap: $", DoubleToString(m_r_cap, 2));
            Print("  r_min: $", DoubleToString(m_r_min, 2));
            Print("");
        }
    }
    
    //+------------------------------------------------------------------+
    //| Emergency Stop Check with Logging                                |
    //+------------------------------------------------------------------+
    bool IsEmergencyStop()
    {
        UpdateDailyLossConsumption();
        
        double emergency_threshold = m_dlr_base * 1.5;
        
        if(m_current_daily_loss > emergency_threshold)
        {
            if(m_tracking_enabled && m_tracker != NULL)
            {
                m_tracker.LogEmergencyStop(m_current_daily_loss, emergency_threshold, m_dlr_current);
            }
            
            Print(" EMERGENCY STOP ACTIVATED ");
            Print("Daily loss ($", DoubleToString(m_current_daily_loss, 2), 
                  ") exceeds emergency threshold ($", DoubleToString(emergency_threshold, 2), ")");
            return true;
        }
        
        return false;
    }
    
    //+------------------------------------------------------------------+
    //| Get Risk Status                                                  |
    //+------------------------------------------------------------------+
    string GetRiskStatus()
    {
        UpdateDailyLossConsumption();
        UpdateProfitBuffer();
        UpdatePositionCount();
        
        double risk_used_percent = (m_current_daily_loss / m_dlr_current) * 100;
        double remaining_risk = m_dlr_current - m_current_daily_loss;
        
        string status = "\n\n";
        status += "       DRA RISK STATUS REPORT\n";
        status += "\n";
        status += "Fixed Reference Balance: $" + DoubleToString(m_initial_balance, 2) + "\n";
        status += "Current Account Balance: $" + DoubleToString(m_account.Balance(), 2) + "\n";
        status += "\n";
        status += "Daily Loss Limit (DLR):\n";
        status += "  Base (4.5%): $" + DoubleToString(m_dlr_base, 2) + "\n";
        status += "  Profit Buffer: $" + DoubleToString(m_profit_buffer, 2) + "\n";
        status += "  Current DLR: $" + DoubleToString(m_dlr_current, 2) + "\n";
        status += "\n";
        status += "Daily Consumption:\n";
        status += "  Closed P/L: $" + DoubleToString(m_closed_pl_today, 2) + "\n";
        status += "  Floating P/L: $" + DoubleToString(m_floating_pl, 2) + "\n";
        status += "  Commissions: $" + DoubleToString(m_total_commissions, 2) + "\n";
        status += "  Swaps: $" + DoubleToString(m_total_swaps, 2) + "\n";
        status += "  Total Loss: $" + DoubleToString(m_current_daily_loss, 2) + "\n";
        status += "\n";
        status += "Risk Used: " + DoubleToString(risk_used_percent, 1) + "%\n";
        status += "Remaining Risk: $" + DoubleToString(remaining_risk, 2) + "\n";
        status += "\n";
        status += "DRA Parameters (Current):\n";
        status += "  r_base: $" + DoubleToString(m_r_base, 2) + "\n";
        status += "  r_cap: $" + DoubleToString(m_r_cap, 2) + "\n";
        status += "  r_min: $" + DoubleToString(m_r_min, 2) + "\n";
        status += "\n";
        status += "Trades Today: " + IntegerToString(m_trades_opened_today) + "/" + IntegerToString(m_max_trades_per_day) + "\n";
        status += "Open Positions: " + IntegerToString(m_current_positions) + "/" + IntegerToString(m_max_open_positions) + "\n";
        status += "\n";
        status += "Can Trade: " + (CanTrade() ? " YES" : " NO") + "\n";
        status += "\n";
        
        return status;
    }
    
    //+------------------------------------------------------------------+
    //| Get DRA Parameters                                               |
    //+------------------------------------------------------------------+
    string GetDRAParameters()
    {
        string params = "\n\n";
        params += "     DRA ALLOCATION PARAMETERS\n";
        params += "\n";
        params += "Base Risk per Trade: $" + DoubleToString(m_r_base, 2) + "\n";
        params += "Risk Cap (2): $" + DoubleToString(m_r_cap, 2) + "\n";
        params += "Risk Min (0.25): $" + DoubleToString(m_r_min, 2) + "\n";
        params += "\n";
        params += "Distribution: 25 trades max per day\n";
        params += "Max Open: 15 positions simultaneously\n";
        params += "\n";
        
        return params;
    }
    
    //+------------------------------------------------------------------+
    //| Get Tracker Report                                               |
    //+------------------------------------------------------------------+
    string GetTrackerReport()
    {
        if(m_tracker != NULL)
        {
            return m_tracker.GetStatisticsReport();
        }
        return "Tracking disabled";
    }
    
    //+------------------------------------------------------------------+
    //| Get Recent Violations                                            |
    //+------------------------------------------------------------------+
    string GetRecentViolations(int count = 10)
    {
        if(m_tracker != NULL)
        {
            return m_tracker.GetRecentViolations(count);
        }
        return "Tracking disabled";
    }
    
    //+------------------------------------------------------------------+
    //| Export Tracker Log                                               |
    //+------------------------------------------------------------------+
    bool ExportTrackerLog()
    {
        if(m_tracker != NULL)
        {
            return m_tracker.ExportFullLog();
        }
        return false;
    }
    
    // Getters
    double GetInitialBalance() { return m_initial_balance; }
    double GetDLRBase() { return m_dlr_base; }
    double GetDLRCurrent() { return m_dlr_current; }
    double GetRBase() { return m_r_base; }
    double GetRCap() { return m_r_cap; }
    double GetRMin() { return m_r_min; }
    double GetCurrentDailyLoss() { return m_current_daily_loss; }
    int GetTradesOpenedToday() { return m_trades_opened_today; }
    int GetCurrentPositions() { return m_current_positions; }
    double GetLastRiskAllocated() { return m_last_risk_allocated; }
    CDLRTracker* GetTracker() { return m_tracker; }
    
    // Additional Getters for Diagnostic Integration
    double GetClosedProfitToday() { return m_closed_profit_today; }
    double GetProfitBuffer() { return m_profit_buffer; }
    int GetTradesToday() { return m_trades_opened_today; }
    int GetMaxTradesPerDay() { return m_max_trades_per_day; }
    int GetMaxOpenPositions() { return m_max_open_positions; }
    double GetFreeMargin() { return AccountInfoDouble(ACCOUNT_MARGIN_FREE); }
    double GetFloatingPL() { return m_floating_pl; }
    double GetTotalCommissions() { return m_total_commissions; }
    double GetTotalSwaps() { return m_total_swaps; }

    // Setters for External Configuration
    void SetDailyLossPercent(double pct) { m_daily_loss_percent = pct; RecalculateDRA(); }
    void SetRiskBase(double r) { m_r_base = m_initial_balance * r / 100.0; }
    void SetRiskCap(double r) { m_r_cap = m_initial_balance * r / 100.0; }
    void SetRiskMin(double r) { m_r_min = m_initial_balance * r / 100.0; }
    void SetMaxTradesPerDay(int n) { m_max_trades_per_day = n; RecalculateDRA(); }
    void SetMaxOpenPositions(int n) { m_max_open_positions = n; }
    
    void RecalculateDRA()
    {
        m_dlr_base = m_initial_balance * m_daily_loss_percent / 100.0;
        m_dlr_current = m_dlr_base + m_profit_buffer;
        m_r_base = m_dlr_base / m_max_trades_per_day;
        m_r_cap = 2.0 * m_r_base;
        m_r_min = 0.25 * m_r_base;
    }
};
//+------------------------------------------------------------------+