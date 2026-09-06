//+------------------------------------------------------------------+
//| UniversalSMCConfluenceEA.mq5                                     |
//| Six independent engines: SMC, FVG, order block, liquidity       |
//| sweep, breakout and confirmed-pivot trend line.                  |
//+------------------------------------------------------------------+
#property copyright "KRISH-HEDEGE"
#property version   "2.00"
#property strict
#property description "Six independent strategy orders with separate risk-based SL/TP."

#include <Trade/Trade.mqh>

enum SignalDirection
{
   SIGNAL_SELL = -1,
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1
};

enum StrategyId
{
   STRATEGY_SMC       = 0,
   STRATEGY_FVG       = 1,
   STRATEGY_OB        = 2,
   STRATEGY_SWEEP     = 3,
   STRATEGY_BREAKOUT  = 4,
   STRATEGY_TRENDLINE = 5,
   STRATEGY_COUNT     = 6
};

input group "Core settings"
input ulong           InpMagicNumber             = 26090601;
input ENUM_TIMEFRAMES InpSignalTimeframe         = PERIOD_M15;
input int             InpHistoryBars             = 300;
input int             InpCooldownBars            = 2;
input int             InpMaxDeviationPoints      = 20;

input group "Six analysis families"
input bool            InpUseSMCStructure         = true;
input bool            InpUseFairValueGap         = true;
input bool            InpUseOrderBlock           = true;
input bool            InpUseLiquiditySweep       = true;
input bool            InpUseBreakout             = true;
input bool            InpUseTrendLine            = true;
input int             InpSwingStrength           = 3;
input int             InpFeatureLookback         = 24;
input int             InpBreakoutLookback        = 20;
input double          InpFVGMinimumATR            = 0.08;
input double          InpZoneProximityATR         = 0.20;
input double          InpDisplacementATR          = 0.50;
input double          InpSweepToleranceATR        = 0.03;
input double          InpTrendLineToleranceATR    = 0.15;

input group "Risk and exits"
input double          InpRiskPercent              = 0.50;
input bool            InpUseEquityForRisk         = true;
input double          InpMinimumRewardRisk        = 2.00;
input int             InpATRPeriod                = 14;
input double          InpStopBufferATR            = 0.15;
input double          InpMinimumStopATR           = 0.50;
input double          InpMaximumStopATR           = 4.00;
input double          InpMaximumVolume            = 10.00;
input double          InpMaximumRiskOvershootPct  = 10.00;
input double          InpMaxDailyLossPercent      = 2.00;
input double          InpMinFreeMarginPercent     = 25.00;

input group "Trade management"
input bool            InpUseBreakEven             = true;
input double          InpBreakEvenAtR             = 1.00;
input int             InpBreakEvenOffsetPoints    = 2;
input bool            InpUseATRTrailing           = true;
input double          InpTrailStartR              = 1.50;
input double          InpTrailATRMultiplier       = 1.20;

input group "Execution filters"
input int             InpTradingStartHour         = 0;
input int             InpTradingEndHour           = 24;
input int             InpMaximumSpreadPoints      = 0;
input double          InpMaximumSpreadATR         = 0.15;
input bool            InpBlockLateFriday          = true;
input int             InpFridayCutoffHour         = 20;
input bool            InpEnableLongTrades         = true;
input bool            InpEnableShortTrades        = true;

input group "Display"
input bool            InpShowDashboard            = true;
input bool            InpEnableAlerts             = false;

struct FeatureSignal
{
   int    direction;
   double invalidation;
   string label;
};

CTrade   g_trade;
int      g_atr_handle       = INVALID_HANDLE;
datetime g_last_bar_time    = 0;
datetime g_last_entry_time[STRATEGY_COUNT];
string   g_status           = "Starting";
string   g_feature_summary  = "No analysis yet";
string   g_strategy_status[STRATEGY_COUNT];
int      g_last_direction[STRATEGY_COUNT];
double   g_last_atr         = 0.0;

//+------------------------------------------------------------------+
//| Utility helpers                                                  |
//+------------------------------------------------------------------+
string DirectionText(const int direction)
{
   if(direction == SIGNAL_BUY)  return "BUY";
   if(direction == SIGNAL_SELL) return "SELL";
   return "NEUTRAL";
}

void ResetFeature(FeatureSignal &signal, const string label)
{
   signal.direction    = SIGNAL_NONE;
   signal.invalidation = 0.0;
   signal.label        = label;
}

string StrategyName(const int strategy_id)
{
   switch(strategy_id)
   {
      case STRATEGY_SMC:       return "SMC";
      case STRATEGY_FVG:       return "FVG";
      case STRATEGY_OB:        return "ORDER_BLOCK";
      case STRATEGY_SWEEP:     return "LIQUIDITY_SWEEP";
      case STRATEGY_BREAKOUT:  return "BREAKOUT";
      case STRATEGY_TRENDLINE: return "TRENDLINE";
   }
   return "UNKNOWN";
}

ulong StrategyMagic(const int strategy_id)
{
   return InpMagicNumber + (ulong)strategy_id;
}

int StrategyIdFromMagic(const ulong magic)
{
   if(magic < InpMagicNumber || magic >= InpMagicNumber + (ulong)STRATEGY_COUNT)
      return -1;
   return (int)(magic - InpMagicNumber);
}

bool IsStrategyMagic(const ulong magic)
{
   return StrategyIdFromMagic(magic) >= 0;
}

bool StrategyEnabled(const int strategy_id)
{
   switch(strategy_id)
   {
      case STRATEGY_SMC:       return InpUseSMCStructure;
      case STRATEGY_FVG:       return InpUseFairValueGap;
      case STRATEGY_OB:        return InpUseOrderBlock;
      case STRATEGY_SWEEP:     return InpUseLiquiditySweep;
      case STRATEGY_BREAKOUT:  return InpUseBreakout;
      case STRATEGY_TRENDLINE: return InpUseTrendLine;
   }
   return false;
}

int EnabledStrategyCount()
{
   int count = 0;
   for(int i = 0; i < STRATEGY_COUNT; i++)
      if(StrategyEnabled(i)) count++;
   return count;
}

int VolumeDigits(const double step)
{
   int digits = 0;
   double scaled = step;
   while(digits < 8 && MathAbs(scaled - MathRound(scaled)) > 1e-8)
   {
      scaled *= 10.0;
      digits++;
   }
   return digits;
}

double TickSize()
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0)
      tick_size = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return tick_size;
}

double NormalizePriceToTick(const double price, const int round_mode)
{
   const double tick_size = TickSize();
   if(tick_size <= 0.0)
      return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   double units = price / tick_size;
   if(round_mode < 0)
      units = MathFloor(units + 1e-9);
   else if(round_mode > 0)
      units = MathCeil(units - 1e-9);
   else
      units = MathRound(units);

   return NormalizeDouble(units * tick_size,
                          (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double FloorVolume(const double requested)
{
   const double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maximum = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
                                  InpMaximumVolume);
   const double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || requested < minimum || maximum < minimum)
      return 0.0;

   double volume = MathFloor((MathMin(requested, maximum) + 1e-12) / step) * step;
   volume = NormalizeDouble(volume, VolumeDigits(step));
   if(volume < minimum - 1e-12)
      return 0.0;
   return volume;
}

double BrokerMinimumDistance()
{
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const long stops   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax((double)MathMax(stops, freeze) * point, TickSize());
}

bool TradeRetcodeSucceeded()
{
   const uint retcode = g_trade.ResultRetcode();
   return retcode == TRADE_RETCODE_DONE ||
          retcode == TRADE_RETCODE_DONE_PARTIAL ||
          retcode == TRADE_RETCODE_PLACED ||
          retcode == TRADE_RETCODE_NO_CHANGES;
}

bool IsSwingHigh(const MqlRates &rates[], const int index,
                 const int strength, const int total)
{
   if(index - strength < 1 || index + strength >= total)
      return false;
   for(int j = 1; j <= strength; j++)
      if(rates[index].high <= rates[index-j].high ||
         rates[index].high <= rates[index+j].high)
         return false;
   return true;
}

bool IsSwingLow(const MqlRates &rates[], const int index,
                const int strength, const int total)
{
   if(index - strength < 1 || index + strength >= total)
      return false;
   for(int j = 1; j <= strength; j++)
      if(rates[index].low >= rates[index-j].low ||
         rates[index].low >= rates[index+j].low)
         return false;
   return true;
}

bool FindTwoSwings(const MqlRates &rates[], const int total, const bool highs,
                   double &recent_price, int &recent_index,
                   double &older_price, int &older_index)
{
   recent_price = older_price = 0.0;
   recent_index = older_index = -1;
   const int limit = MathMin(total - InpSwingStrength - 1, InpHistoryBars - 1);

   for(int i = InpSwingStrength + 1; i <= limit; i++)
   {
      bool swing = highs ? IsSwingHigh(rates, i, InpSwingStrength, total)
                         : IsSwingLow(rates, i, InpSwingStrength, total);
      if(!swing)
         continue;

      if(recent_index < 0)
      {
         recent_index = i;
         recent_price = highs ? rates[i].high : rates[i].low;
      }
      else
      {
         older_index = i;
         older_price = highs ? rates[i].high : rates[i].low;
         return true;
      }
   }
   return false;
}

bool ReadATR(const int shift, double &atr)
{
   atr = 0.0;
   if(g_atr_handle == INVALID_HANDLE)
      return false;
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(g_atr_handle, 0, shift, 1, values) != 1 || values[0] <= 0.0)
      return false;
   atr = values[0];
   return true;
}

//+------------------------------------------------------------------+
//| Six deterministic closed-bar feature detectors                   |
//+------------------------------------------------------------------+
void DetectSMC(const MqlRates &rates[], const int total, FeatureSignal &signal)
{
   ResetFeature(signal, "SMC");
   double high1, high2, low1, low2;
   int hi1, hi2, lo1, lo2;
   const bool have_highs = FindTwoSwings(rates, total, true, high1, hi1, high2, hi2);
   const bool have_lows  = FindTwoSwings(rates, total, false, low1, lo1, low2, lo2);
   if(!have_highs || !have_lows)
      return;

   const bool bullish_structure = (high1 > high2 && low1 > low2);
   const bool bearish_structure = (high1 < high2 && low1 < low2);
   const bool bullish_bos = (rates[1].close > high1 && rates[2].close <= high1);
   const bool bearish_bos = (rates[1].close < low1 && rates[2].close >= low1);

   if(bullish_bos || (bullish_structure && rates[1].close > low1))
   {
      signal.direction = SIGNAL_BUY;
      signal.invalidation = low1;
   }
   else if(bearish_bos || (bearish_structure && rates[1].close < high1))
   {
      signal.direction = SIGNAL_SELL;
      signal.invalidation = high1;
   }
}

void DetectFVG(const MqlRates &rates[], const int total, const double atr,
               FeatureSignal &signal)
{
   ResetFeature(signal, "FVG");
   const int limit = MathMin(InpFeatureLookback, total - 3);
   const double minimum_gap = atr * InpFVGMinimumATR;
   const double proximity   = atr * InpZoneProximityATR;

   for(int i = 1; i <= limit; i++)
   {
      // Bullish imbalance between the newest candle's low and oldest high.
      if(rates[i].low > rates[i+2].high + minimum_gap)
      {
         const double zone_low  = rates[i+2].high;
         const double zone_high = rates[i].low;
         bool invalidated = false;
         for(int j = 1; j < i; j++)
            if(rates[j].close < zone_low) invalidated = true;
         if(!invalidated && rates[1].low <= zone_high + proximity &&
            rates[1].close >= zone_low)
         {
            signal.direction = SIGNAL_BUY;
            signal.invalidation = zone_low;
            return;
         }
      }

      if(rates[i].high < rates[i+2].low - minimum_gap)
      {
         const double zone_low  = rates[i].high;
         const double zone_high = rates[i+2].low;
         bool invalidated = false;
         for(int j = 1; j < i; j++)
            if(rates[j].close > zone_high) invalidated = true;
         if(!invalidated && rates[1].high >= zone_low - proximity &&
            rates[1].close <= zone_high)
         {
            signal.direction = SIGNAL_SELL;
            signal.invalidation = zone_high;
            return;
         }
      }
   }
}

void DetectOrderBlock(const MqlRates &rates[], const int total, const double atr,
                      FeatureSignal &signal)
{
   ResetFeature(signal, "OB");
   const int limit = MathMin(InpFeatureLookback, total - 2);
   const double displacement = atr * InpDisplacementATR;
   const double proximity    = atr * InpZoneProximityATR;

   for(int i = 2; i <= limit; i++)
   {
      const double next_body = MathAbs(rates[i-1].close - rates[i-1].open);
      bool bullish_invalidated = false;
      bool bearish_invalidated = false;
      for(int j = 1; j <= i - 2; j++)
      {
         if(rates[j].close < rates[i].low)  bullish_invalidated = true;
         if(rates[j].close > rates[i].high) bearish_invalidated = true;
      }

      if(!bullish_invalidated && rates[i].close < rates[i].open &&
         rates[i-1].close > rates[i].high && next_body >= displacement &&
         rates[1].low <= rates[i].high + proximity && rates[1].close > rates[i].low)
      {
         signal.direction = SIGNAL_BUY;
         signal.invalidation = rates[i].low;
         return;
      }
      if(!bearish_invalidated && rates[i].close > rates[i].open &&
         rates[i-1].close < rates[i].low && next_body >= displacement &&
         rates[1].high >= rates[i].low - proximity && rates[1].close < rates[i].high)
      {
         signal.direction = SIGNAL_SELL;
         signal.invalidation = rates[i].high;
         return;
      }
   }
}

void DetectLiquiditySweep(const MqlRates &rates[], const int total, const double atr,
                          FeatureSignal &signal)
{
   ResetFeature(signal, "SWEEP");
   const int limit = MathMin(InpFeatureLookback + 1, total - 1);
   if(limit < 4)
      return;

   double prior_high = rates[2].high;
   double prior_low  = rates[2].low;
   for(int i = 3; i <= limit; i++)
   {
      prior_high = MathMax(prior_high, rates[i].high);
      prior_low  = MathMin(prior_low, rates[i].low);
   }

   const double tolerance = atr * InpSweepToleranceATR;
   if(rates[1].low < prior_low - tolerance && rates[1].close > prior_low)
   {
      signal.direction = SIGNAL_BUY;
      signal.invalidation = rates[1].low;
   }
   else if(rates[1].high > prior_high + tolerance && rates[1].close < prior_high)
   {
      signal.direction = SIGNAL_SELL;
      signal.invalidation = rates[1].high;
   }
}

void DetectBreakout(const MqlRates &rates[], const int total, const double atr,
                    FeatureSignal &signal)
{
   ResetFeature(signal, "BREAKOUT");
   const int limit = MathMin(InpBreakoutLookback + 1, total - 1);
   if(limit < 4)
      return;

   double range_high = rates[2].high;
   double range_low  = rates[2].low;
   for(int i = 3; i <= limit; i++)
   {
      range_high = MathMax(range_high, rates[i].high);
      range_low  = MathMin(range_low, rates[i].low);
   }

   const double body = MathAbs(rates[1].close - rates[1].open);
   const double buffer = atr * 0.03;
   if(rates[1].close > range_high + buffer && body >= atr * 0.20)
   {
      signal.direction = SIGNAL_BUY;
      signal.invalidation = range_high;
   }
   else if(rates[1].close < range_low - buffer && body >= atr * 0.20)
   {
      signal.direction = SIGNAL_SELL;
      signal.invalidation = range_low;
   }
}

void DetectTrendLine(const MqlRates &rates[], const int total, const double atr,
                     FeatureSignal &signal)
{
   ResetFeature(signal, "TRENDLINE");
   double high1, high2, low1, low2;
   int hi1, hi2, lo1, lo2;
   const bool have_highs = FindTwoSwings(rates, total, true, high1, hi1, high2, hi2);
   const bool have_lows  = FindTwoSwings(rates, total, false, low1, lo1, low2, lo2);
   const double tolerance = atr * InpTrendLineToleranceATR;

   if(have_lows && rates[lo1].time > rates[lo2].time)
   {
      const double seconds = (double)(rates[lo1].time - rates[lo2].time);
      const double slope = (low1 - low2) / seconds;
      const double projected = low1 + slope * (double)(rates[1].time - rates[lo1].time);
      if(slope > 0.0 && rates[1].low <= projected + tolerance &&
         rates[1].close > projected && rates[1].close > rates[1].open)
      {
         signal.direction = SIGNAL_BUY;
         signal.invalidation = MathMin(rates[1].low, projected);
         return;
      }
   }

   if(have_highs && rates[hi1].time > rates[hi2].time)
   {
      const double seconds = (double)(rates[hi1].time - rates[hi2].time);
      const double slope = (high1 - high2) / seconds;
      const double projected = high1 + slope * (double)(rates[1].time - rates[hi1].time);
      if(slope < 0.0 && rates[1].high >= projected - tolerance &&
         rates[1].close < projected && rates[1].close < rates[1].open)
      {
         signal.direction = SIGNAL_SELL;
         signal.invalidation = MathMax(rates[1].high, projected);
      }
   }
}

void AnalyzeStrategies(const MqlRates &rates[], const int total,
                       const double atr, FeatureSignal &signals[])
{
   for(int i = 0; i < STRATEGY_COUNT; i++)
   {
      ResetFeature(signals[i], StrategyName(i));
      g_last_direction[i] = SIGNAL_NONE;
      if(!StrategyEnabled(i))
         g_strategy_status[i] = "DISABLED";
      else
         g_strategy_status[i] = "Waiting for signal";
   }

   if(InpUseSMCStructure)
      DetectSMC(rates, total, signals[STRATEGY_SMC]);
   if(InpUseFairValueGap)
      DetectFVG(rates, total, atr, signals[STRATEGY_FVG]);
   if(InpUseOrderBlock)
      DetectOrderBlock(rates, total, atr, signals[STRATEGY_OB]);
   if(InpUseLiquiditySweep)
      DetectLiquiditySweep(rates, total, atr, signals[STRATEGY_SWEEP]);
   if(InpUseBreakout)
      DetectBreakout(rates, total, atr, signals[STRATEGY_BREAKOUT]);
   if(InpUseTrendLine)
      DetectTrendLine(rates, total, atr, signals[STRATEGY_TRENDLINE]);

   for(int i = 0; i < STRATEGY_COUNT; i++)
   {
      g_last_direction[i] = signals[i].direction;
      if(StrategyEnabled(i) && signals[i].direction == SIGNAL_NONE)
         g_strategy_status[i] = ManagedPositionCount(i) > 0
                                ? "Position open; managed independently"
                                : "No signal";
   }

   g_feature_summary = StringFormat("SMC:%s FVG:%s OB:%s Sweep:%s Break:%s TL:%s",
                                    DirectionText(signals[STRATEGY_SMC].direction),
                                    DirectionText(signals[STRATEGY_FVG].direction),
                                    DirectionText(signals[STRATEGY_OB].direction),
                                    DirectionText(signals[STRATEGY_SWEEP].direction),
                                    DirectionText(signals[STRATEGY_BREAKOUT].direction),
                                    DirectionText(signals[STRATEGY_TRENDLINE].direction));
}

//+------------------------------------------------------------------+
//| Position ownership and safety filters                            |
//+------------------------------------------------------------------+
int ManagedPositionCount(const int strategy_id = -1)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      const ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(strategy_id >= 0 ? magic == StrategyMagic(strategy_id) : IsStrategyMagic(magic))
         count++;
   }
   return count;
}

bool FindStrategyPosition(const int strategy_id, ulong &ticket)
{
   ticket = 0;
   const ulong strategy_magic = StrategyMagic(strategy_id);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong current = PositionGetTicket(i);
      if(current == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == strategy_magic)
      {
         ticket = current;
         return true;
      }
   }
   return false;
}

bool HasStrategyActiveOrder(const int strategy_id)
{
   const ulong strategy_magic = StrategyMagic(strategy_id);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong order = OrderGetTicket(i);
      if(order == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == strategy_magic)
         return true;
   }
   return false;
}

string RiskKey(const ulong ticket)
{
   return StringFormat("USMC.R.%I64d.%I64u",
                       AccountInfoInteger(ACCOUNT_LOGIN), ticket);
}

double InitialRiskForPosition(const ulong ticket, const double open_price)
{
   const string key = RiskKey(ticket);
   if(GlobalVariableCheck(key))
      return GlobalVariableGet(key);

   if(!PositionSelectByTicket(ticket))
      return 0.0;
   const ulong position_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   const long position_id = PositionGetInteger(POSITION_IDENTIFIER);
   if(position_id <= 0 || !HistorySelectByPosition(position_id))
      return 0.0;

   double initial_sl = 0.0;
   long earliest_time = 0;
   for(int i = 0; i < HistoryOrdersTotal(); i++)
   {
      const ulong order = HistoryOrderGetTicket(i);
      if(order == 0) continue;
      if(HistoryOrderGetString(order, ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryOrderGetInteger(order, ORDER_MAGIC) != position_magic) continue;
      const double order_sl = HistoryOrderGetDouble(order, ORDER_SL);
      const long setup_time = HistoryOrderGetInteger(order, ORDER_TIME_SETUP_MSC);
      if(order_sl > 0.0 && (earliest_time == 0 || setup_time < earliest_time))
      {
         initial_sl = order_sl;
         earliest_time = setup_time;
      }
   }

   const double recovered = MathAbs(open_price - initial_sl);
   if(initial_sl > 0.0 && recovered > 0.0)
   {
      GlobalVariableSet(key, recovered);
      return recovered;
   }

   g_status = "Management paused: initial R could not be recovered";
   return 0.0;
}

bool ManagedPositionSafetyValid(const ulong ticket, string &reason)
{
   reason = "";
   if(!PositionSelectByTicket(ticket))
      return true;

   const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   const double stop = PositionGetDouble(POSITION_SL);
   const double target = PositionGetDouble(POSITION_TP);
   const double volume = PositionGetDouble(POSITION_VOLUME);
   if(stop <= 0.0 || target <= 0.0)
   {
      reason = "server-side SL or TP is missing";
      return false;
   }

   const double initial_risk = InitialRiskForPosition(ticket, open_price);
   if(initial_risk <= 0.0)
   {
      reason = "initial risk cannot be verified";
      return false;
   }

   const bool buy = type == POSITION_TYPE_BUY;
   const double reward = buy ? target - open_price : open_price - target;
   if(reward + TickSize() * 1e-6 < initial_risk * InpMinimumRewardRisk)
   {
      reason = "target is below configured reward:risk";
      return false;
   }

   double stop_result = 0.0;
   const ENUM_ORDER_TYPE order_type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(order_type, _Symbol, volume, open_price, stop, stop_result))
   {
      reason = "money risk cannot be calculated";
      return false;
   }
   const double current_loss = stop_result < 0.0 ? MathAbs(stop_result) : 0.0;
   const double basis = InpUseEquityForRisk ? AccountInfoDouble(ACCOUNT_EQUITY)
                                             : AccountInfoDouble(ACCOUNT_BALANCE);
   const double allowed_loss = basis * InpRiskPercent / 100.0 *
                               (1.0 + InpMaximumRiskOvershootPct / 100.0);
   if(current_loss > allowed_loss)
   {
      reason = "money risk exceeds configured tolerance";
      return false;
   }
   return true;
}

datetime StartOfServerDay()
{
   MqlDateTime parts;
   TimeToStruct(TimeTradeServer(), parts);
   parts.hour = 0;
   parts.min  = 0;
   parts.sec  = 0;
   return StructToTime(parts);
}

double TodayRealizedResult()
{
   if(!HistorySelect(StartOfServerDay(), TimeTradeServer()))
      return 0.0;
   double result = 0.0;
   const int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if(!IsStrategyMagic((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC))) continue;
      const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      result += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      result += HistoryDealGetDouble(deal, DEAL_FEE);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
      {
         result += HistoryDealGetDouble(deal, DEAL_PROFIT);
         result += HistoryDealGetDouble(deal, DEAL_SWAP);
      }
   }
   return result;
}

void LoadLastEntryTimes()
{
   for(int strategy_id = 0; strategy_id < STRATEGY_COUNT; strategy_id++)
      g_last_entry_time[strategy_id] = 0;

   const datetime from = TimeTradeServer() - 90 * 24 * 60 * 60;
   if(!HistorySelect(from, TimeTradeServer()))
      return;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      const int strategy_id = StrategyIdFromMagic(
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC));
      if(strategy_id < 0 || g_last_entry_time[strategy_id] > 0) continue;
      const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         g_last_entry_time[strategy_id] =
            (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   }
}

bool WithinTradingHours()
{
   MqlDateTime parts;
   TimeToStruct(TimeTradeServer(), parts);
   if(InpBlockLateFriday && parts.day_of_week == 5 && parts.hour >= InpFridayCutoffHour)
      return false;
   if(parts.day_of_week == 6 || parts.day_of_week == 0)
      return false;
   if(InpTradingStartHour == 0 && InpTradingEndHour == 24)
      return true;
   if(InpTradingStartHour < InpTradingEndHour)
      return parts.hour >= InpTradingStartHour && parts.hour < InpTradingEndHour;
   return parts.hour >= InpTradingStartHour || parts.hour < InpTradingEndHour;
}

bool EntryFiltersPass(const int strategy_id, const double atr)
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      g_strategy_status[strategy_id] = "Blocked: trading/connection permission";
      return false;
   }
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      g_strategy_status[strategy_id] = "Blocked: symbol trading disabled";
      return false;
   }
   if(!WithinTradingHours())
   {
      g_strategy_status[strategy_id] = "Blocked: session/weekend filter";
      return false;
   }
   if(HasStrategyActiveOrder(strategy_id))
   {
      g_strategy_status[strategy_id] = "Blocked: own prior order is active";
      return false;
   }
   if(ManagedPositionCount(strategy_id) > 0)
   {
      g_strategy_status[strategy_id] = "Blocked: own position already open";
      return false;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= tick.bid || tick.time <= 0)
   {
      g_strategy_status[strategy_id] = "Blocked: invalid quote";
      return false;
   }
   const double spread = tick.ask - tick.bid;
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(InpMaximumSpreadPoints > 0 && spread > InpMaximumSpreadPoints * point)
   {
      g_strategy_status[strategy_id] = "Blocked: fixed spread limit";
      return false;
   }
   if(InpMaximumSpreadATR > 0.0 && atr > 0.0 && spread > atr * InpMaximumSpreadATR)
   {
      g_strategy_status[strategy_id] = "Blocked: ATR spread limit";
      return false;
   }

   const double daily_limit = AccountInfoDouble(ACCOUNT_BALANCE) *
                              InpMaxDailyLossPercent / 100.0;
   if(InpMaxDailyLossPercent > 0.0 && TodayRealizedResult() <= -daily_limit)
   {
      g_strategy_status[strategy_id] = "Blocked: combined daily loss limit";
      return false;
   }

   const int seconds = PeriodSeconds(InpSignalTimeframe);
   if(g_last_entry_time[strategy_id] > 0 && seconds > 0 &&
      TimeTradeServer() < g_last_entry_time[strategy_id] + InpCooldownBars * seconds)
   {
      g_strategy_status[strategy_id] = "Blocked: own cooldown";
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Risk-based order placement                                       |
//+------------------------------------------------------------------+
double RiskBasedVolume(const ENUM_ORDER_TYPE order_type, const double entry,
                       const double stop)
{
   const double basis = InpUseEquityForRisk ? AccountInfoDouble(ACCOUNT_EQUITY)
                                             : AccountInfoDouble(ACCOUNT_BALANCE);
   const double risk_money = basis * InpRiskPercent / 100.0;
   double one_lot_result = 0.0;
   if(risk_money <= 0.0 ||
      !OrderCalcProfit(order_type, _Symbol, 1.0, entry, stop, one_lot_result))
      return 0.0;
   const double one_lot_loss = MathAbs(one_lot_result);
   if(one_lot_loss <= 0.0)
      return 0.0;
   return FloorVolume(risk_money / one_lot_loss);
}

bool BuildOrderPrices(const FeatureSignal &signal, const double atr,
                      double &entry, double &stop, double &target,
                      ENUM_ORDER_TYPE &order_type)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double minimum_distance = BrokerMinimumDistance();
   double reference = signal.invalidation;
   if(signal.direction == SIGNAL_BUY)
   {
      order_type = ORDER_TYPE_BUY;
      entry = tick.ask;
      if(reference <= 0.0 || reference >= entry)
         reference = entry - atr * InpMinimumStopATR;
      stop = reference - atr * InpStopBufferATR;
      stop = MathMin(stop, entry - atr * InpMinimumStopATR);
      stop = MathMin(stop, tick.bid - minimum_distance);
      stop = NormalizePriceToTick(stop, -1);
      const double risk = entry - stop;
      if(risk <= 0.0 || risk > atr * InpMaximumStopATR)
         return false;
      target = NormalizePriceToTick(entry + risk * InpMinimumRewardRisk, 1);
   }
   else if(signal.direction == SIGNAL_SELL)
   {
      order_type = ORDER_TYPE_SELL;
      entry = tick.bid;
      if(reference <= entry)
         reference = entry + atr * InpMinimumStopATR;
      stop = reference + atr * InpStopBufferATR;
      stop = MathMax(stop, entry + atr * InpMinimumStopATR);
      stop = MathMax(stop, tick.ask + minimum_distance);
      stop = NormalizePriceToTick(stop, 1);
      const double risk = stop - entry;
      if(risk <= 0.0 || risk > atr * InpMaximumStopATR)
         return false;
      target = NormalizePriceToTick(entry - risk * InpMinimumRewardRisk, -1);
   }
   else
      return false;

   return true;
}

bool MarginIsSafe(const ENUM_ORDER_TYPE order_type, const double volume,
                  const double entry)
{
   double margin = 0.0;
   if(!OrderCalcMargin(order_type, _Symbol, volume, entry, margin))
      return false;
   const double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin <= 0.0 || free_margin <= margin)
      return false;
   const double remaining_percent = 100.0 * (free_margin - margin) /
                                    MathMax(AccountInfoDouble(ACCOUNT_EQUITY), 1.0);
   return remaining_percent >= InpMinFreeMarginPercent;
}

bool SetTradeMagicFromPosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   const ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(!IsStrategyMagic(magic))
      return false;
   g_trade.SetExpertMagicNumber(magic);
   return true;
}

bool ClosePositionConfirmed(const ulong ticket)
{
   if(!SetTradeMagicFromPosition(ticket))
      return !PositionSelectByTicket(ticket);
   const bool submitted = g_trade.PositionClose(ticket);
   const bool accepted = submitted && TradeRetcodeSucceeded();
   if(accepted && !PositionSelectByTicket(ticket))
      return true;
   return false;
}

void MarkEmergencyClose(const ulong ticket, const string reason)
{
   int strategy_id = -1;
   if(PositionSelectByTicket(ticket))
      strategy_id = StrategyIdFromMagic((ulong)PositionGetInteger(POSITION_MAGIC));

   const string message = "Unsafe ticket containment: " + reason;
   if(ClosePositionConfirmed(ticket))
   {
      g_status = message + "; closed";
      if(strategy_id >= 0)
         g_strategy_status[strategy_id] = "Unsafe own ticket closed";
   }
   else
   {
      g_status = message + "; close will retry next tick";
      if(strategy_id >= 0)
         g_strategy_status[strategy_id] = "Unsafe own ticket: close retry pending";
      Print(g_status, ". Ticket=", ticket, " Retcode=", g_trade.ResultRetcode(),
            " ", g_trade.ResultRetcodeDescription());
   }
}

void ContainUnsafePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsStrategyMagic((ulong)PositionGetInteger(POSITION_MAGIC)))
         continue;

      string reason;
      if(!ManagedPositionSafetyValid(ticket, reason))
         MarkEmergencyClose(ticket, reason);
   }
}

bool EnforcePostFillRewardRisk(const ulong ticket, const int direction,
                               const double stop, const double requested_target)
{
   if(!PositionSelectByTicket(ticket) || !SetTradeMagicFromPosition(ticket))
      return false;
   const double actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double current_sl   = PositionGetDouble(POSITION_SL);
   const double current_tp   = PositionGetDouble(POSITION_TP);
   const double protected_sl = current_sl > 0.0 ? current_sl : stop;
   double initial_risk = InitialRiskForPosition(ticket, actual_entry);
   if(initial_risk <= 0.0)
      initial_risk = MathAbs(actual_entry - protected_sl);
   if(initial_risk <= 0.0)
      return false;

   double required_target = requested_target;
   if(direction == SIGNAL_BUY)
      required_target = MathMax(required_target,
                                NormalizePriceToTick(actual_entry + initial_risk * InpMinimumRewardRisk, 1));
   else
      required_target = MathMin(required_target,
                                NormalizePriceToTick(actual_entry - initial_risk * InpMinimumRewardRisk, -1));

   bool needs_modify = current_sl <= 0.0;
   if(direction == SIGNAL_BUY && current_tp + TickSize() * 0.5 < required_target)
      needs_modify = true;
   if(direction == SIGNAL_SELL && (current_tp <= 0.0 ||
                                   current_tp - TickSize() * 0.5 > required_target))
      needs_modify = true;

   if(needs_modify)
   {
      const bool submitted = g_trade.PositionModify(ticket, protected_sl, required_target);
      if(!submitted || !TradeRetcodeSucceeded())
      {
         MarkEmergencyClose(ticket, "broker rejected post-fill protection");
         return false;
      }
   }

   if(!PositionSelectByTicket(ticket))
      return false;
   const double verified_sl = PositionGetDouble(POSITION_SL);
   const double verified_tp = PositionGetDouble(POSITION_TP);
   const double volume      = PositionGetDouble(POSITION_VOLUME);
   const double reward = MathAbs(verified_tp - actual_entry);
   const bool correct_side = direction == SIGNAL_BUY
                             ? (verified_tp > actual_entry && verified_sl < verified_tp)
                             : (verified_tp < actual_entry && verified_sl > verified_tp);
   if(verified_sl <= 0.0 || verified_tp <= 0.0 ||
      !correct_side || reward + TickSize() * 1e-6 < initial_risk * InpMinimumRewardRisk)
   {
      MarkEmergencyClose(ticket, "SL/TP verification failed");
      return false;
   }

   double actual_loss = 0.0;
   const ENUM_ORDER_TYPE order_type = direction == SIGNAL_BUY ? ORDER_TYPE_BUY
                                                               : ORDER_TYPE_SELL;
   const double basis = InpUseEquityForRisk ? AccountInfoDouble(ACCOUNT_EQUITY)
                                             : AccountInfoDouble(ACCOUNT_BALANCE);
   const double allowed_loss = basis * InpRiskPercent / 100.0 *
                               (1.0 + InpMaximumRiskOvershootPct / 100.0);
   if(!OrderCalcProfit(order_type, _Symbol, volume, actual_entry, verified_sl, actual_loss) ||
      MathAbs(actual_loss) > allowed_loss)
   {
      MarkEmergencyClose(ticket, "post-fill money risk exceeds allowed tolerance");
      return false;
   }

   GlobalVariableSet(RiskKey(ticket), initial_risk);
   return true;
}

void ReconcileUnverifiedPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsStrategyMagic((ulong)PositionGetInteger(POSITION_MAGIC)))
         continue;
      if(GlobalVariableCheck(RiskKey(ticket)))
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      const ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const int direction = type == POSITION_TYPE_BUY ? SIGNAL_BUY : SIGNAL_SELL;
      const double stop = PositionGetDouble(POSITION_SL);
      const double target = PositionGetDouble(POSITION_TP);
      if(!EnforcePostFillRewardRisk(ticket, direction, stop, target))
         Print("Delayed/recovered fill safety reconciliation failed. Ticket=", ticket);
   }
}

bool PlaceStrategySignal(const int strategy_id, const FeatureSignal &signal,
                         const double atr)
{
   double entry, stop, target;
   ENUM_ORDER_TYPE order_type;
   if(!BuildOrderPrices(signal, atr, entry, stop, target, order_type))
   {
      g_strategy_status[strategy_id] = "Rejected: invalid structural/ATR stop";
      return false;
   }

   const double volume = RiskBasedVolume(order_type, entry, stop);
   if(volume <= 0.0)
   {
      g_strategy_status[strategy_id] = "Rejected: lot sizing/minimum lot";
      return false;
   }
   if(!MarginIsSafe(order_type, volume, entry))
   {
      g_strategy_status[strategy_id] = "Rejected: free-margin reserve";
      return false;
   }

   const ulong strategy_magic = StrategyMagic(strategy_id);
   g_trade.SetExpertMagicNumber(strategy_magic);
   g_trade.SetDeviationInPoints(InpMaxDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   const string comment = StringFormat("USMC|%s|%s", StrategyName(strategy_id),
                                       DirectionText(signal.direction));
   bool sent = false;
   if(signal.direction == SIGNAL_BUY)
      sent = g_trade.Buy(volume, _Symbol, 0.0, stop, target, comment);
   else
      sent = g_trade.Sell(volume, _Symbol, 0.0, stop, target, comment);

   if(!sent || !TradeRetcodeSucceeded())
   {
      g_strategy_status[strategy_id] = StringFormat("Order failed: %u %s",
                                                    g_trade.ResultRetcode(),
                                                    g_trade.ResultRetcodeDescription());
      Print(StrategyName(strategy_id), ": ", g_strategy_status[strategy_id]);
      return false;
   }

   ulong ticket;
   if(!FindStrategyPosition(strategy_id, ticket))
   {
      if(g_trade.ResultRetcode() == TRADE_RETCODE_PLACED)
      {
         g_last_entry_time[strategy_id] = TimeTradeServer();
         g_strategy_status[strategy_id] = "Order accepted; awaiting fill";
         return true;
      }
      g_strategy_status[strategy_id] = "Success reported but position not found";
      return false;
   }
   if(!EnforcePostFillRewardRisk(ticket, signal.direction, stop, target))
   {
      g_strategy_status[strategy_id] = "Protection failed; own ticket containment started";
      return false;
   }

   g_last_entry_time[strategy_id] = TimeTradeServer();
   g_strategy_status[strategy_id] = StringFormat("%s OPEN %.2f lots",
                                                 DirectionText(signal.direction), volume);
   g_status = StrategyName(strategy_id) + " opened independently";
   Print(StrategyName(strategy_id), " ", DirectionText(signal.direction),
         " opened. Magic=", strategy_magic,
         " Volume=", DoubleToString(volume, 2),
         " SL=", DoubleToString(stop, (int)_Digits),
         " TP=", DoubleToString(target, (int)_Digits),
         " RR>=", DoubleToString(InpMinimumRewardRisk, 2));
   if(InpEnableAlerts)
      Alert(_Symbol, " ", StrategyName(strategy_id), " ",
            g_strategy_status[strategy_id]);
   return true;
}

//+------------------------------------------------------------------+
//| Break-even and one-way ATR trailing                              |
//+------------------------------------------------------------------+
void ManagePosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket) || !SetTradeMagicFromPosition(ticket))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   const int strategy_id = StrategyIdFromMagic(
      (ulong)PositionGetInteger(POSITION_MAGIC));
   const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   const double current_sl = PositionGetDouble(POSITION_SL);
   const double current_tp = PositionGetDouble(POSITION_TP);
   const double initial_risk = InitialRiskForPosition(ticket, open_price);
   if(initial_risk <= 0.0)
      return;

   const bool buy = (type == POSITION_TYPE_BUY);
   const double market_price = buy ? tick.bid : tick.ask;
   const double profit_r = buy ? (market_price - open_price) / initial_risk
                               : (open_price - market_price) / initial_risk;
   double candidate = current_sl;

   if(InpUseBreakEven && profit_r >= InpBreakEvenAtR)
   {
      const double offset = InpBreakEvenOffsetPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      const double breakeven = buy ? open_price + offset : open_price - offset;
      if(buy && (candidate <= 0.0 || breakeven > candidate)) candidate = breakeven;
      if(!buy && (candidate <= 0.0 || breakeven < candidate)) candidate = breakeven;
   }

   double atr = 0.0;
   if(InpUseATRTrailing && profit_r >= InpTrailStartR && ReadATR(0, atr))
   {
      const double trailing = buy ? tick.bid - atr * InpTrailATRMultiplier
                                  : tick.ask + atr * InpTrailATRMultiplier;
      if(buy && trailing > candidate) candidate = trailing;
      if(!buy && (candidate <= 0.0 || trailing < candidate)) candidate = trailing;
   }

   if(candidate <= 0.0)
      return;
   const double minimum_distance = BrokerMinimumDistance();
   if(buy)
   {
      candidate = MathMin(candidate, tick.bid - minimum_distance);
      candidate = NormalizePriceToTick(candidate, -1);
      if(current_sl > 0.0 && candidate <= current_sl + TickSize() * 0.5) return;
   }
   else
   {
      candidate = MathMax(candidate, tick.ask + minimum_distance);
      candidate = NormalizePriceToTick(candidate, 1);
      if(current_sl > 0.0 && candidate >= current_sl - TickSize() * 0.5) return;
   }

   const bool submitted = g_trade.PositionModify(ticket, candidate, current_tp);
   if(!submitted || !TradeRetcodeSucceeded() || !PositionSelectByTicket(ticket))
   {
      g_status = "Stop update rejected by broker";
      if(strategy_id >= 0)
         g_strategy_status[strategy_id] = g_status;
      return;
   }
   const double verified_sl = PositionGetDouble(POSITION_SL);
   const bool applied = buy ? verified_sl >= candidate - TickSize() * 0.5
                            : verified_sl <= candidate + TickSize() * 0.5;
   if(applied)
   {
      g_status = StringFormat("Managing %s: %.2fR, SL tightened",
                              buy ? "BUY" : "SELL", profit_r);
      if(strategy_id >= 0)
         g_strategy_status[strategy_id] = StringFormat("%s open, %.2fR, SL tightened",
                                                       buy ? "BUY" : "SELL", profit_r);
   }
   else
   {
      g_status = "Stop update not confirmed";
      if(strategy_id >= 0)
         g_strategy_status[strategy_id] = g_status;
   }
}

void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsStrategyMagic((ulong)PositionGetInteger(POSITION_MAGIC)))
         continue;
      ManagePosition(ticket);
   }
}

void DrawDashboard()
{
   if(!InpShowDashboard)
   {
      Comment("");
      return;
   }

   string strategy_lines = "";
   for(int strategy_id = 0; strategy_id < STRATEGY_COUNT; strategy_id++)
   {
      strategy_lines += StringFormat("%s [%I64u] %s | positions=%d | %s\n",
                                     StrategyName(strategy_id),
                                     StrategyMagic(strategy_id),
                                     DirectionText(g_last_direction[strategy_id]),
                                     ManagedPositionCount(strategy_id),
                                     g_strategy_status[strategy_id]);
   }

   Comment("Universal Independent Strategy EA\n",
           "Symbol: ", _Symbol, " | Signal TF: ", EnumToString(InpSignalTimeframe), "\n",
           "Each enabled strategy trades independently; no voting/confluence.\n",
           g_feature_summary, "\n",
           strategy_lines,
           "ATR: ", DoubleToString(g_last_atr, (int)_Digits),
           " | Combined daily result: ", DoubleToString(TodayRealizedResult(), 2),
           " | Total strategy positions: ", ManagedPositionCount(), "\n",
           "Status: ", g_status);
}

//+------------------------------------------------------------------+
//| Expert lifecycle                                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   const int enabled = EnabledStrategyCount();
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("Independent per-strategy positions require an MT5 hedging account. ",
            "Netting accounts merge same-symbol orders and cannot keep separate SL/TP.");
      return INIT_FAILED;
   }
   if(InpMagicNumber == 0 || enabled < 1 || InpHistoryBars < 100 ||
      InpSwingStrength < 1 || InpFeatureLookback < 5 ||
      InpBreakoutLookback < 3 || InpCooldownBars < 0 ||
      InpMaxDeviationPoints < 0 || InpFVGMinimumATR < 0.0 ||
      InpZoneProximityATR < 0.0 || InpDisplacementATR <= 0.0 ||
      InpSweepToleranceATR < 0.0 || InpTrendLineToleranceATR < 0.0)
   {
      Print("Invalid strategy/core inputs or no strategy is enabled.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0 ||
      InpMinimumRewardRisk < 2.0 || InpATRPeriod < 2 ||
      InpStopBufferATR < 0.0 || InpMinimumStopATR <= 0.0 ||
      InpMaximumStopATR < InpMinimumStopATR ||
      InpMaximumVolume <= 0.0 || InpMaximumRiskOvershootPct < 0.0 ||
      InpMaximumRiskOvershootPct > 100.0 || InpMaxDailyLossPercent < 0.0 ||
      InpMinFreeMarginPercent < 0.0)
   {
      Print("Invalid risk inputs. Reward:risk cannot be below 2.0.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTradingStartHour < 0 || InpTradingStartHour > 23 ||
      InpTradingEndHour < 1 || InpTradingEndHour > 24 ||
      InpFridayCutoffHour < 0 || InpFridayCutoffHour > 23 ||
      InpMaximumSpreadPoints < 0 || InpMaximumSpreadATR < 0.0 ||
      InpBreakEvenAtR < 0.0 || InpBreakEvenOffsetPoints < 0 ||
      InpTrailStartR < 0.0 || InpTrailATRMultiplier <= 0.0)
   {
      Print("Invalid session or management inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!SymbolSelect(_Symbol, true))
      return INIT_FAILED;
   g_atr_handle = iATR(_Symbol, InpSignalTimeframe, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("Could not create ATR handle. Error=", GetLastError());
      return INIT_FAILED;
   }

   for(int strategy_id = 0; strategy_id < STRATEGY_COUNT; strategy_id++)
   {
      g_last_direction[strategy_id] = SIGNAL_NONE;
      g_strategy_status[strategy_id] = StrategyEnabled(strategy_id)
                                               ? "Ready" : "DISABLED";
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();
   g_last_bar_time = iTime(_Symbol, InpSignalTimeframe, 0);
   LoadLastEntryTimes();
   if(ManagedPositionCount() > 0)
      g_status = "Existing independent positions recovered; safety reconciliation pending";
   else
      g_status = "Ready; waiting for independent strategy signals";

   Print("Universal Independent Strategy EA ready on ", _Symbol,
         ". Enabled strategies=", enabled,
         ", magic range=", InpMagicNumber, "..",
         InpMagicNumber + (ulong)STRATEGY_COUNT - 1,
         ", per-strategy risk=", DoubleToString(InpRiskPercent, 2), "%",
         ", minimum RR=", DoubleToString(InpMinimumRewardRisk, 2));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   Comment("");
}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD || transaction.deal == 0)
      return;
   if(!HistoryDealSelect(transaction.deal))
      return;
   if(HistoryDealGetString(transaction.deal, DEAL_SYMBOL) != _Symbol)
      return;

   const int strategy_id = StrategyIdFromMagic(
      (ulong)HistoryDealGetInteger(transaction.deal, DEAL_MAGIC));
   if(strategy_id < 0)
      return;

   const long entry = HistoryDealGetInteger(transaction.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
   {
      g_last_entry_time[strategy_id] =
         (datetime)HistoryDealGetInteger(transaction.deal, DEAL_TIME);
      g_strategy_status[strategy_id] = "Fill received; safety check pending";

      ulong ticket;
      if(FindStrategyPosition(strategy_id, ticket) &&
         !GlobalVariableCheck(RiskKey(ticket)) && PositionSelectByTicket(ticket))
      {
         const ENUM_POSITION_TYPE type =
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         const int direction = type == POSITION_TYPE_BUY ? SIGNAL_BUY : SIGNAL_SELL;
         EnforcePostFillRewardRisk(ticket, direction,
                                   PositionGetDouble(POSITION_SL),
                                   PositionGetDouble(POSITION_TP));
      }
   }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      g_strategy_status[strategy_id] = "Position closed; ready after cooldown";
}

void OnTick()
{
   ReconcileUnverifiedPositions();
   ContainUnsafePositions();
   ManageOpenPositions();

   const datetime current_bar = iTime(_Symbol, InpSignalTimeframe, 0);
   if(current_bar <= 0 || current_bar == g_last_bar_time)
   {
      DrawDashboard();
      return;
   }
   g_last_bar_time = current_bar;

   double atr = 0.0;
   if(!ReadATR(1, atr))
   {
      g_status = "Waiting for ATR data";
      DrawDashboard();
      return;
   }
   g_last_atr = atr;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   const int copied = CopyRates(_Symbol, InpSignalTimeframe, 0, InpHistoryBars, rates);
   const int minimum_bars = MathMax(InpFeatureLookback, InpBreakoutLookback) +
                            InpSwingStrength * 2 + 10;
   if(copied < minimum_bars)
   {
      g_status = StringFormat("Waiting for price history: %d/%d", copied, minimum_bars);
      DrawDashboard();
      return;
   }

   FeatureSignal signals[STRATEGY_COUNT];
   AnalyzeStrategies(rates, copied, atr, signals);

   int signal_count = 0;
   int order_count = 0;
   for(int strategy_id = 0; strategy_id < STRATEGY_COUNT; strategy_id++)
   {
      if(!StrategyEnabled(strategy_id) || signals[strategy_id].direction == SIGNAL_NONE)
         continue;

      signal_count++;
      if((signals[strategy_id].direction == SIGNAL_BUY && !InpEnableLongTrades) ||
         (signals[strategy_id].direction == SIGNAL_SELL && !InpEnableShortTrades))
      {
         g_strategy_status[strategy_id] = "Blocked: signal direction disabled";
         continue;
      }

      if(EntryFiltersPass(strategy_id, atr) &&
         PlaceStrategySignal(strategy_id, signals[strategy_id], atr))
         order_count++;
   }

   if(order_count > 0)
      g_status = StringFormat("Independent orders opened this bar: %d", order_count);
   else if(signal_count > 0)
      g_status = StringFormat("Independent signals this bar: %d; see strategy status", signal_count);
   else
      g_status = "No independent strategy signal on the closed bar";
   DrawDashboard();
}
