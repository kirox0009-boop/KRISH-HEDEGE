//+------------------------------------------------------------------+
//| UniversalSMCConfluenceEA.mq5                                     |
//| Closed-bar confluence EA: SMC, FVG, order block, liquidity       |
//| sweep, breakout and confirmed-pivot trend line.                  |
//+------------------------------------------------------------------+
#property copyright "KRISH-HEDEGE"
#property version   "1.00"
#property strict
#property description "Multi-asset confluence EA with risk-based sizing and automatic SL/TP."

#include <Trade/Trade.mqh>

enum SignalDirection
{
   SIGNAL_SELL = -1,
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1
};

input group "Core settings"
input ulong           InpMagicNumber             = 26090601;
input ENUM_TIMEFRAMES InpSignalTimeframe         = PERIOD_M15;
input ENUM_TIMEFRAMES InpTrendTimeframe          = PERIOD_H1;
input int             InpHistoryBars             = 300;
input int             InpMinimumConfluence       = 3;
input bool            InpRequireHTFBias          = true;
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
input int             InpHTFMeanPeriod            = 50;

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

struct TradeSetup
{
   int    direction;
   int    buy_votes;
   int    sell_votes;
   int    winning_votes;
   double stop_reference;
   string reasons;
};

CTrade   g_trade;
int      g_atr_handle       = INVALID_HANDLE;
datetime g_last_bar_time    = 0;
datetime g_last_entry_time  = 0;
string   g_status           = "Starting";
string   g_feature_summary  = "No analysis yet";
int      g_last_buy_votes   = 0;
int      g_last_sell_votes  = 0;
int      g_last_htf_bias    = SIGNAL_NONE;
double   g_last_atr         = 0.0;
ulong    g_emergency_ticket = 0;
bool     g_ownership_conflict = false;
bool     g_expected_position_active = false;

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

int EnabledFeatureCount()
{
   int count = 0;
   if(InpUseSMCStructure)   count++;
   if(InpUseFairValueGap)   count++;
   if(InpUseOrderBlock)     count++;
   if(InpUseLiquiditySweep) count++;
   if(InpUseBreakout)       count++;
   if(InpUseTrendLine)      count++;
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

int HigherTimeframeBias()
{
   MqlRates trend_rates[];
   ArraySetAsSeries(trend_rates, true);
   const int wanted = MathMax(InpHistoryBars, InpHTFMeanPeriod + 20);
   const int copied = CopyRates(_Symbol, InpTrendTimeframe, 0, wanted, trend_rates);
   if(copied < InpHTFMeanPeriod + 5)
      return SIGNAL_NONE;

   double high1, high2, low1, low2;
   int hi1, hi2, lo1, lo2;
   const bool highs = FindTwoSwings(trend_rates, copied, true, high1, hi1, high2, hi2);
   const bool lows  = FindTwoSwings(trend_rates, copied, false, low1, lo1, low2, lo2);
   if(highs && lows)
   {
      if(high1 > high2 && low1 > low2) return SIGNAL_BUY;
      if(high1 < high2 && low1 < low2) return SIGNAL_SELL;
   }

   double mean = 0.0;
   for(int i = 1; i <= InpHTFMeanPeriod; i++)
      mean += trend_rates[i].close;
   mean /= InpHTFMeanPeriod;
   if(trend_rates[1].close > mean) return SIGNAL_BUY;
   if(trend_rates[1].close < mean) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

void AddFeatureVote(const FeatureSignal &feature, TradeSetup &setup,
                    double &buy_reference, double &sell_reference)
{
   if(feature.direction == SIGNAL_BUY)
   {
      setup.buy_votes++;
      if(feature.invalidation > 0.0 &&
         (buy_reference == 0.0 || feature.invalidation < buy_reference))
         buy_reference = feature.invalidation;
   }
   else if(feature.direction == SIGNAL_SELL)
   {
      setup.sell_votes++;
      if(feature.invalidation > 0.0 && feature.invalidation > sell_reference)
         sell_reference = feature.invalidation;
   }
}

void AppendReason(const FeatureSignal &feature, const int direction, string &reasons)
{
   if(feature.direction != direction)
      return;
   if(StringLen(reasons) > 0)
      reasons += ",";
   reasons += feature.label;
}

bool BuildSetup(const MqlRates &rates[], const int total, const double atr,
                TradeSetup &setup)
{
   setup.direction = SIGNAL_NONE;
   setup.buy_votes = setup.sell_votes = setup.winning_votes = 0;
   setup.stop_reference = 0.0;
   setup.reasons = "";

   FeatureSignal smc, fvg, ob, sweep, breakout, trendline;
   ResetFeature(smc, "SMC");
   ResetFeature(fvg, "FVG");
   ResetFeature(ob, "OB");
   ResetFeature(sweep, "SWEEP");
   ResetFeature(breakout, "BREAKOUT");
   ResetFeature(trendline, "TRENDLINE");

   if(InpUseSMCStructure)   DetectSMC(rates, total, smc);
   if(InpUseFairValueGap)   DetectFVG(rates, total, atr, fvg);
   if(InpUseOrderBlock)     DetectOrderBlock(rates, total, atr, ob);
   if(InpUseLiquiditySweep) DetectLiquiditySweep(rates, total, atr, sweep);
   if(InpUseBreakout)       DetectBreakout(rates, total, atr, breakout);
   if(InpUseTrendLine)      DetectTrendLine(rates, total, atr, trendline);

   double buy_reference = 0.0;
   double sell_reference = 0.0;
   AddFeatureVote(smc, setup, buy_reference, sell_reference);
   AddFeatureVote(fvg, setup, buy_reference, sell_reference);
   AddFeatureVote(ob, setup, buy_reference, sell_reference);
   AddFeatureVote(sweep, setup, buy_reference, sell_reference);
   AddFeatureVote(breakout, setup, buy_reference, sell_reference);
   AddFeatureVote(trendline, setup, buy_reference, sell_reference);

   g_last_buy_votes  = setup.buy_votes;
   g_last_sell_votes = setup.sell_votes;
   g_last_htf_bias   = HigherTimeframeBias();
   g_feature_summary = StringFormat("SMC:%s FVG:%s OB:%s Sweep:%s Break:%s TL:%s",
                                    DirectionText(smc.direction), DirectionText(fvg.direction),
                                    DirectionText(ob.direction), DirectionText(sweep.direction),
                                    DirectionText(breakout.direction), DirectionText(trendline.direction));

   if(setup.buy_votes >= InpMinimumConfluence && setup.buy_votes > setup.sell_votes)
      setup.direction = SIGNAL_BUY;
   else if(setup.sell_votes >= InpMinimumConfluence && setup.sell_votes > setup.buy_votes)
      setup.direction = SIGNAL_SELL;
   else
   {
      g_status = StringFormat("No entry: BUY %d / SELL %d votes",
                              setup.buy_votes, setup.sell_votes);
      return false;
   }

   if((setup.direction == SIGNAL_BUY && !InpEnableLongTrades) ||
      (setup.direction == SIGNAL_SELL && !InpEnableShortTrades))
   {
      g_status = "Confluence rejected: selected direction is disabled";
      return false;
   }
   if(InpRequireHTFBias && g_last_htf_bias != setup.direction)
   {
      g_status = "Confluence rejected: higher-timeframe bias disagrees";
      return false;
   }

   setup.winning_votes = setup.direction == SIGNAL_BUY ? setup.buy_votes : setup.sell_votes;
   setup.stop_reference = setup.direction == SIGNAL_BUY ? buy_reference : sell_reference;
   AppendReason(smc, setup.direction, setup.reasons);
   AppendReason(fvg, setup.direction, setup.reasons);
   AppendReason(ob, setup.direction, setup.reasons);
   AppendReason(sweep, setup.direction, setup.reasons);
   AppendReason(breakout, setup.direction, setup.reasons);
   AppendReason(trendline, setup.direction, setup.reasons);
   return true;
}

//+------------------------------------------------------------------+
//| Position ownership and safety filters                            |
//+------------------------------------------------------------------+
int ManagedPositionCount()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

bool FindManagedPosition(ulong &ticket)
{
   ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong current = PositionGetTicket(i);
      if(current == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ticket = current;
         return true;
      }
   }
   return false;
}

bool SymbolHasForeignPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         return true;
   }
   return false;
}

bool HasManagedActiveOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong order = OrderGetTicket(i);
      if(order == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         return true;
   }
   return false;
}

string RiskKey(const ulong ticket)
{
   return StringFormat("USMC.R.%I64d.%I64u",
                       AccountInfoInteger(ACCOUNT_LOGIN), ticket);
}

string EmergencyKey()
{
   return StringFormat("USMC.E.%I64d.%I64u",
                       AccountInfoInteger(ACCOUNT_LOGIN), InpMagicNumber);
}

void ClearEmergencyState()
{
   g_emergency_ticket = 0;
   if(GlobalVariableCheck(EmergencyKey()))
      GlobalVariableDel(EmergencyKey());
}

double InitialRiskForPosition(const ulong ticket, const double open_price)
{
   const string key = RiskKey(ticket);
   if(GlobalVariableCheck(key))
      return GlobalVariableGet(key);

   if(!PositionSelectByTicket(ticket))
      return 0.0;
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
      if((ulong)HistoryOrderGetInteger(order, ORDER_MAGIC) != InpMagicNumber) continue;
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

bool FindUnsafeManagedPosition(ulong &ticket, string &reason)
{
   ticket = 0;
   reason = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong current = PositionGetTicket(i);
      if(current == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if(!ManagedPositionSafetyValid(current, reason))
      {
         ticket = current;
         return true;
      }
   }
   return false;
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
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) continue;
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

void LoadLastEntryTime()
{
   g_last_entry_time = 0;
   const datetime from = TimeTradeServer() - 90 * 24 * 60 * 60;
   if(!HistorySelect(from, TimeTradeServer()))
      return;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) continue;
      const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
      {
         g_last_entry_time = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         return;
      }
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

bool EntryFiltersPass(const double atr)
{
   if(g_ownership_conflict)
   {
      g_status = "Entry blocked: netting ownership conflict";
      return false;
   }
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      g_status = "Entry blocked: trading/connection permission";
      return false;
   }
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      g_status = "Entry blocked: symbol trading disabled";
      return false;
   }
   if(!WithinTradingHours())
   {
      g_status = "Entry blocked: session/weekend filter";
      return false;
   }
   if(SymbolHasForeignPosition())
   {
      g_status = "Entry blocked: another strategy/manual position uses this symbol";
      return false;
   }

   if(HasManagedActiveOrder())
   {
      g_status = "Entry blocked: prior order is still active";
      return false;
   }
   if(ManagedPositionCount() > 0)
   {
      g_status = "Entry blocked: managed position already open";
      return false;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= tick.bid || tick.time <= 0)
   {
      g_status = "Entry blocked: invalid quote";
      return false;
   }
   const double spread = tick.ask - tick.bid;
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(InpMaximumSpreadPoints > 0 && spread > InpMaximumSpreadPoints * point)
   {
      g_status = "Entry blocked: fixed spread limit";
      return false;
   }
   if(InpMaximumSpreadATR > 0.0 && atr > 0.0 && spread > atr * InpMaximumSpreadATR)
   {
      g_status = "Entry blocked: volatility-adjusted spread limit";
      return false;
   }

   const double daily_limit = AccountInfoDouble(ACCOUNT_BALANCE) *
                              InpMaxDailyLossPercent / 100.0;
   if(InpMaxDailyLossPercent > 0.0 && TodayRealizedResult() <= -daily_limit)
   {
      g_status = "Entry blocked: daily realized-loss limit";
      return false;
   }

   const int seconds = PeriodSeconds(InpSignalTimeframe);
   if(g_last_entry_time > 0 && seconds > 0 &&
      TimeTradeServer() < g_last_entry_time + InpCooldownBars * seconds)
   {
      g_status = "Entry blocked: cooldown";
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

bool BuildOrderPrices(const TradeSetup &setup, const double atr,
                      double &entry, double &stop, double &target,
                      ENUM_ORDER_TYPE &order_type)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double minimum_distance = BrokerMinimumDistance();
   double reference = setup.stop_reference;
   if(setup.direction == SIGNAL_BUY)
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
   else if(setup.direction == SIGNAL_SELL)
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

bool ClosePositionConfirmed(const ulong ticket)
{
   const bool submitted = g_trade.PositionClose(ticket);
   const bool accepted = submitted && TradeRetcodeSucceeded();
   if(accepted && !PositionSelectByTicket(ticket))
      return true;
   return false;
}

void MarkEmergencyClose(const ulong ticket, const string reason)
{
   g_emergency_ticket = ticket;
   GlobalVariableSet(EmergencyKey(), (double)ticket);
   g_status = "CRITICAL: closing position - " + reason;
   Print(g_status, ". Retcode=", g_trade.ResultRetcode(), " ",
         g_trade.ResultRetcodeDescription());
   if(ClosePositionConfirmed(ticket))
   {
      ClearEmergencyState();
      g_expected_position_active = false;
      g_status = "Unsafe position closed";
   }
}

bool HandleEmergencyClose()
{
   if(g_emergency_ticket == 0)
      return false;
   if(!PositionSelectByTicket(g_emergency_ticket))
   {
      ClearEmergencyState();
      g_expected_position_active = false;
      g_status = "Unsafe position confirmed closed";
      return false;
   }
   if(ClosePositionConfirmed(g_emergency_ticket))
   {
      ClearEmergencyState();
      g_expected_position_active = false;
      g_status = "Unsafe position closed on retry";
      return false;
   }
   g_status = "CRITICAL: retrying emergency position close";
   return true;
}

bool EnforcePostFillRewardRisk(const ulong ticket, const int direction,
                               const double stop, const double requested_target)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   const double actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double current_sl   = PositionGetDouble(POSITION_SL);
   const double current_tp   = PositionGetDouble(POSITION_TP);
   const double protected_sl = current_sl > 0.0 ? current_sl : stop;
   const double initial_risk = MathAbs(actual_entry - protected_sl);
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
   const double verified_risk = MathAbs(actual_entry - verified_sl);
   const double reward = MathAbs(verified_tp - actual_entry);
   const bool correct_side = direction == SIGNAL_BUY
                             ? (verified_sl < actual_entry && verified_tp > actual_entry)
                             : (verified_sl > actual_entry && verified_tp < actual_entry);
   if(verified_sl <= 0.0 || verified_tp <= 0.0 || verified_risk <= 0.0 ||
      !correct_side || reward + TickSize() * 1e-6 < verified_risk * InpMinimumRewardRisk)
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

   GlobalVariableSet(RiskKey(ticket), verified_risk);
   return true;
}

bool PlaceSetup(const TradeSetup &setup, const double atr)
{
   double entry, stop, target;
   ENUM_ORDER_TYPE order_type;
   if(!BuildOrderPrices(setup, atr, entry, stop, target, order_type))
   {
      g_status = "Signal rejected: structural stop outside configured range";
      return false;
   }

   const double volume = RiskBasedVolume(order_type, entry, stop);
   if(volume <= 0.0)
   {
      g_status = "Signal rejected: broker minimum lot exceeds risk or sizing failed";
      return false;
   }
   if(!MarginIsSafe(order_type, volume, entry))
   {
      g_status = "Signal rejected: free-margin reserve";
      return false;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   const string comment = StringFormat("USMC|%s|%d", DirectionText(setup.direction),
                                       setup.winning_votes);
   bool sent = false;
   if(setup.direction == SIGNAL_BUY)
      sent = g_trade.Buy(volume, _Symbol, 0.0, stop, target, comment);
   else
      sent = g_trade.Sell(volume, _Symbol, 0.0, stop, target, comment);

   if(!sent || !TradeRetcodeSucceeded())
   {
      g_status = StringFormat("Order failed: %u %s", g_trade.ResultRetcode(),
                              g_trade.ResultRetcodeDescription());
      Print(g_status);
      return false;
   }

   ulong ticket;
   if(!FindManagedPosition(ticket))
   {
      if(g_trade.ResultRetcode() == TRADE_RETCODE_PLACED)
      {
         g_expected_position_active = true;
         g_last_entry_time = TimeTradeServer();
         g_status = "Order accepted; awaiting broker fill and safety verification";
         return true;
      }
      g_status = "Order reported success but no filled position was found";
      return false;
   }
   if(!EnforcePostFillRewardRisk(ticket, setup.direction, stop, target))
   {
      if(g_emergency_ticket == 0)
         g_status = "Order protection verification failed";
      return false;
   }

   g_expected_position_active = true;
   g_last_entry_time = TimeTradeServer();
   g_status = StringFormat("%s opened: %.2f lots, %d votes, %s",
                           DirectionText(setup.direction), volume,
                           setup.winning_votes, setup.reasons);
   Print(g_status, " SL=", DoubleToString(stop, (int)_Digits),
         " TP=", DoubleToString(target, (int)_Digits),
         " minimum RR=", DoubleToString(InpMinimumRewardRisk, 2));
   if(InpEnableAlerts)
      Alert(_Symbol, " ", g_status);
   return true;
}

//+------------------------------------------------------------------+
//| Break-even and one-way ATR trailing                              |
//+------------------------------------------------------------------+
void ManagePosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

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
      return;
   }
   const double verified_sl = PositionGetDouble(POSITION_SL);
   const bool applied = buy ? verified_sl >= candidate - TickSize() * 0.5
                            : verified_sl <= candidate + TickSize() * 0.5;
   if(applied)
      g_status = StringFormat("Managing %s: %.2fR, SL tightened",
                              buy ? "BUY" : "SELL", profit_r);
   else
      g_status = "Stop update not confirmed";
}

void ManageOpenPositions()
{
   int managed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      managed++;
      ManagePosition(ticket);
   }
   if(managed == 0 && g_emergency_ticket == 0 && !HasManagedActiveOrder())
      g_expected_position_active = false;
}

void DrawDashboard()
{
   if(!InpShowDashboard)
   {
      Comment("");
      return;
   }
   ulong ticket;
   const bool has_position = FindManagedPosition(ticket);
   const double daily = TodayRealizedResult();
   Comment("Universal SMC Confluence EA\n",
           "Symbol: ", _Symbol, " | Signal TF: ", EnumToString(InpSignalTimeframe),
           " | Trend TF: ", EnumToString(InpTrendTimeframe), "\n",
           "Votes BUY/SELL: ", g_last_buy_votes, "/", g_last_sell_votes,
           " | HTF: ", DirectionText(g_last_htf_bias), "\n",
           g_feature_summary, "\n",
           "ATR: ", DoubleToString(g_last_atr, (int)_Digits),
           " | Daily result: ", DoubleToString(daily, 2),
           " | Position: ", has_position ? "OPEN" : "FLAT", "\n",
           "Status: ", g_status);
}

//+------------------------------------------------------------------+
//| Expert lifecycle                                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   const int enabled = EnabledFeatureCount();
   if(InpMagicNumber == 0 || InpHistoryBars < 100 ||
      InpSwingStrength < 1 || InpFeatureLookback < 5 ||
      InpBreakoutLookback < 3 || InpHTFMeanPeriod < 2 ||
      InpCooldownBars < 0 || InpMaxDeviationPoints < 0 ||
      InpFVGMinimumATR < 0.0 || InpZoneProximityATR < 0.0 ||
      InpDisplacementATR <= 0.0 || InpSweepToleranceATR < 0.0 ||
      InpTrendLineToleranceATR < 0.0 || InpMinimumConfluence < 1 ||
      InpMinimumConfluence > enabled)
   {
      Print("Invalid analysis/core inputs. Minimum confluence must be 1..", enabled);
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

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();
   g_last_bar_time = iTime(_Symbol, InpSignalTimeframe, 0);
   LoadLastEntryTime();
   if(GlobalVariableCheck(EmergencyKey()))
   {
      g_emergency_ticket = (ulong)GlobalVariableGet(EmergencyKey());
      g_expected_position_active = true;
      g_status = "CRITICAL: recovered pending emergency close";
   }
   else if(ManagedPositionCount() > 0)
   {
      g_expected_position_active = true;
      g_status = "Existing managed position recovered; safety check pending";
   }
   else
      g_status = "Ready; waiting for next closed signal bar";
   Print("Universal SMC Confluence EA ready on ", _Symbol,
         ". Attach one instance per symbol. Enabled features=", enabled,
         ", minimum confluence=", InpMinimumConfluence,
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
   const ulong deal_magic = (ulong)HistoryDealGetInteger(transaction.deal, DEAL_MAGIC);
   if(deal_magic == InpMagicNumber)
   {
      const long entry = HistoryDealGetInteger(transaction.deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
      {
         g_expected_position_active = true;
         g_status = "Fill received; safety verification pending";
      }
      return;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return;

   if(g_expected_position_active)
   {
      g_ownership_conflict = true;
      g_status = "CRITICAL: foreign deal merged with netting symbol; management paused";
      Print(g_status, ". Deal=", transaction.deal);
      if(InpEnableAlerts)
         Alert(_Symbol, " ", g_status);
   }
}

void OnTick()
{
   if(HandleEmergencyClose())
   {
      DrawDashboard();
      return;
   }
   if(g_ownership_conflict)
   {
      DrawDashboard();
      return;
   }

   ulong unsafe_ticket;
   string unsafe_reason;
   if(FindUnsafeManagedPosition(unsafe_ticket, unsafe_reason))
   {
      MarkEmergencyClose(unsafe_ticket, unsafe_reason);
      DrawDashboard();
      return;
   }

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
   const int minimum_bars = MathMax(InpHTFMeanPeriod,
                                    MathMax(InpFeatureLookback, InpBreakoutLookback)) +
                            InpSwingStrength * 2 + 10;
   if(copied < minimum_bars)
   {
      g_status = StringFormat("Waiting for price history: %d/%d", copied, minimum_bars);
      DrawDashboard();
      return;
   }

   TradeSetup setup;
   if(!BuildSetup(rates, copied, atr, setup))
   {
      DrawDashboard();
      return;
   }

   if(EntryFiltersPass(atr))
      PlaceSetup(setup, atr);
   DrawDashboard();
}
