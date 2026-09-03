//+------------------------------------------------------------------+
//|                                       GoldDualBasketGridEA.mq5   |
//|                                                                  |
//|  Dual-Basket Hedge Grid Expert Advisor (XAUUSD / M1 oriented)     |
//|                                                                  |
//|  CORE LOGIC                                                      |
//|  ----------                                                      |
//|  1. EA opens ONE buy and ONE sell at the same time.               |
//|  2. Buy positions and sell positions live in two COMPLETELY       |
//|     SEPARATE baskets (separate magic numbers). Overall / combined |
//|     equity is never used as a close trigger.                      |
//|  3. Whichever basket's TOTAL floating money reaches its target    |
//|     (default 1.00 account currency) is closed ENTIRELY - all      |
//|     positions of that side at once, not one by one.               |
//|  4. After a basket closes in profit, a fresh level-1 position is  |
//|     re-opened on that same side, so the winning side keeps        |
//|     harvesting while the trend continues.                         |
//|  5. The losing side does NOT close. Every time price moves        |
//|     against it by the grid step, one averaging position is added  |
//|     with a SMOOTH lot progression (additive by default, e.g.      |
//|     0.01 / 0.02 / 0.03 / 0.04 / 0.05) - not aggressive doubling.  |
//|  6. When price bounces back, the averaged basket reaches its      |
//|     money target and closes as a whole, then the cycle mirrors    |
//|     to the other side.                                            |
//|                                                                  |
//|  REQUIREMENTS: a HEDGING MT5 account (both directions open at     |
//|  once). Netting accounts are rejected in OnInit.                  |
//|                                                                  |
//|  RISK WARNING: grid / averaging strategies carry unbounded        |
//|  drawdown risk if price trends without retracement. Always test   |
//|  in the Strategy Tester and on a demo account first, and keep     |
//|  the equity protection enabled.                                   |
//+------------------------------------------------------------------+
#property copyright "KRISH-HEDEGE"
#property link      "https://github.com/kirox0009-boop/KRISH-HEDEGE"
#property version   "1.00"
#property description "Dual-basket hedge grid EA for Gold (XAUUSD) on M1."
#property description "Buy and sell baskets are managed independently."
#property description "Winning basket closes at a money target, losing basket averages with a smooth lot step."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_FIXED     = 0, // Fixed - same lot on every grid level
   LOT_ADDITIVE  = 1, // Additive - 0.01, 0.02, 0.03, 0.04 ... (smooth)
   LOT_MULTIPLY  = 2  // Multiplier - base * mult^(level-1)
  };

enum ENUM_STEP_MODE
  {
   STEP_PRICE  = 0, // Fixed price distance (e.g. 3.0 = $3 gold move) - broker safe
   STEP_POINTS = 1, // Fixed points (depends on broker digits)
   STEP_ATR    = 2  // ATR based (auto adapts to volatility)
  };

enum ENUM_TARGET_MODE
  {
   TARGET_FIXED_MONEY = 0, // Fixed money per basket
   TARGET_PER_LOT     = 1  // Money per 1.00 lot of basket volume
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Identification ==="
input long             InpMagicBuy              = 20260901;   // Magic number - BUY basket
input long             InpMagicSell             = 20260902;   // Magic number - SELL basket
input string           InpTradeComment          = "GDBG";     // Order comment

input group "=== Lot sizing (smooth averaging) ==="
input double           InpBaseLot               = 0.01;       // Base lot (grid level 1)
input ENUM_LOT_MODE    InpLotMode               = LOT_ADDITIVE; // Lot progression mode
input double           InpLotIncrement          = 0.01;       // Additive mode: lot added per level
input double           InpLotMultiplier         = 1.20;       // Multiply mode: factor per level (keep <= 1.3)
input double           InpMaxLotPerOrder        = 0.50;       // Max lot for a single order
input double           InpMaxLotsPerBasket      = 3.00;       // Max total volume per basket (0 = off)

input group "=== Grid / averaging distance ==="
input ENUM_STEP_MODE   InpStepMode              = STEP_PRICE; // Grid step mode
input double           InpGridStepPrice         = 3.00;       // PRICE mode: distance in price units ($3 for gold)
input double           InpGridStepPoints        = 300;        // POINTS mode: distance in points
input int              InpATRPeriod             = 14;         // ATR period (ATR mode)
input double           InpATRMultiplier         = 1.50;       // ATR multiplier (ATR mode)
input double           InpStepWidenFactor       = 1.00;       // Step widening per level (1.0 = constant)
input double           InpMinStepPrice          = 1.00;       // Hard floor for the step, in price units
input int              InpMaxPositionsPerBasket = 15;         // Max grid levels per basket
input int              InpMinSecondsBetweenAdds = 20;         // Min seconds between two grid adds

input group "=== Basket take profit ==="
input ENUM_TARGET_MODE InpTargetMode            = TARGET_FIXED_MONEY; // Target mode
input double           InpBuyTargetMoney        = 1.00;       // BUY basket target (money, or money/lot)
input double           InpSellTargetMoney       = 1.00;       // SELL basket target (money, or money/lot)
input double           InpCommissionPerLotRT    = 0.00;       // Est. round-turn commission per 1.00 lot
input bool             InpUseBasketTrailing     = false;      // Trail basket profit once target is hit
input double           InpBasketTrailMoney      = 0.50;       // Trail distance in money

input group "=== Cycle behaviour ==="
input bool             InpOpenBothOnStart       = true;       // Open buy + sell together when flat
input bool             InpReopenAfterProfit     = true;       // Re-open level 1 after a basket closes
input int              InpReopenDelaySeconds    = 3;          // Delay before re-opening
input double           InpReopenPullbackPoints  = 0;          // Wait for this pullback before re-open (0 = instant)
input bool             InpAllowNewCycles        = true;       // Master switch: false = wind down only

input group "=== Filters ==="
input double           InpMaxSpreadPoints       = 60;         // Max allowed spread in points (0 = off)
input bool             InpUseTimeFilter         = false;      // Enable trading hour filter (server time)
input int              InpStartHour             = 1;          // Start hour
input int              InpEndHour               = 23;         // End hour
input bool             InpCloseBeforeWeekend    = false;      // Flatten everything Friday
input int              InpFridayCloseHour       = 21;         // Friday flatten hour

input group "=== Protection ==="
input bool             InpUseEquityStop         = true;       // Enable floating drawdown protection
input double           InpEquityStopPercent     = 30.0;       // Max floating DD as % of balance
input bool             InpHaltAfterEquityStop   = true;       // Stop trading after equity stop fires
input int              InpSlippagePoints        = 30;         // Max deviation in points

input group "=== Display ==="
input bool             InpShowDashboard         = true;       // Show on-chart dashboard

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         Trade;
CPositionInfo  Pos;
CSymbolInfo    Sym;

int      g_atrHandle      = INVALID_HANDLE;
int      g_volumeDigits   = 2;
bool     g_halted         = false;

datetime g_buyClosedAt    = 0;      // when the buy basket was last flattened in profit
datetime g_sellClosedAt   = 0;
double   g_buyClosePrice  = 0.0;    // price at that moment (for pullback re-entry)
double   g_sellClosePrice = 0.0;

double   g_buyPeakProfit  = 0.0;    // for basket trailing
double   g_sellPeakProfit = 0.0;

string   g_lastError      = "";

//+------------------------------------------------------------------+
//| Basket snapshot                                                  |
//+------------------------------------------------------------------+
struct BasketInfo
  {
   int      count;         // number of open positions
   double   lots;          // total volume
   double   profit;        // floating money incl. swap, minus commission estimate
   double   minPrice;      // lowest open price
   double   maxPrice;      // highest open price
   double   avgPrice;      // volume weighted average price
   datetime lastOpenTime;  // newest position open time
  };

//+------------------------------------------------------------------+
//| Forward declarations                                             |
//+------------------------------------------------------------------+
void   ResetBasket(BasketInfo &b);
void   ScanBasket(const long magic, const ENUM_POSITION_TYPE type, BasketInfo &b);
double BasketTarget(const BasketInfo &b, const bool isBuy);
bool   BasketShouldClose(const BasketInfo &b, const bool isBuy);
bool   CloseBasket(const long magic);
double CurrentStepPoints(const int level);
double ATRPoints(void);
double LotForLevel(const int level);
double NormalizeLot(double lot);
void   ManageGrid(const BasketInfo &b, const bool isBuy);
void   ManageReopen(const BasketInfo &b, const bool isBuy);
bool   OpenLevel(const bool isBuy, const int level);
bool   OpenPosition(const bool isBuy, const double lot, const string comment);
bool   TradingAllowed(void);
bool   CheckEquityStop(const BasketInfo &buy, const BasketInfo &sell);
bool   CheckWeekendFlatten(const BasketInfo &buy, const BasketInfo &sell);
void   DrawDashboard(const bool force = false);

//+------------------------------------------------------------------+
//| Reset helper                                                     |
//+------------------------------------------------------------------+
void ResetBasket(BasketInfo &b)
  {
   b.count        = 0;
   b.lots         = 0.0;
   b.profit       = 0.0;
   b.minPrice     = 0.0;
   b.maxPrice     = 0.0;
   b.avgPrice     = 0.0;
   b.lastOpenTime = 0;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- hedging account is mandatory: we hold buy and sell at once
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("GoldDualBasketGridEA needs a HEDGING account. This account is netting - cannot run.");
      return(INIT_FAILED);
     }

   if(InpMagicBuy == InpMagicSell)
     {
      Alert("Magic numbers for buy and sell must be DIFFERENT so the baskets stay separate.");
      return(INIT_FAILED);
     }

   if(InpBaseLot <= 0.0)
     {
      Alert("Base lot must be greater than zero.");
      return(INIT_FAILED);
     }

   if(!Sym.Name(_Symbol))
     {
      Alert("Cannot select symbol ", _Symbol);
      return(INIT_FAILED);
     }
   Sym.RefreshRates();

//--- symbol must be tradable
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_DISABLED)
     {
      Alert("Trading is disabled for ", _Symbol);
      return(INIT_FAILED);
     }

//--- volume digits from the broker's volume step
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      vstep = 0.01;
   g_volumeDigits = 0;
   double tmp = vstep;
   while(tmp < 1.0 - 1e-9 && g_volumeDigits < 8)
     {
      tmp *= 10.0;
      g_volumeDigits++;
     }

//--- trade object
   Trade.SetExpertMagicNumber(InpMagicBuy);
   Trade.SetDeviationInPoints((ulong)MathMax(1, InpSlippagePoints));
   Trade.SetTypeFillingBySymbol(_Symbol);
   Trade.SetMarginMode();

//--- ATR handle for the adaptive grid step
   if(InpStepMode == STEP_ATR)
     {
      g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, MathMax(1, InpATRPeriod));
      if(g_atrHandle == INVALID_HANDLE)
        {
         Alert("Failed to create ATR indicator handle.");
         return(INIT_FAILED);
        }
     }

//--- soft advisories
   if(Period() != PERIOD_M1)
      Print("NOTE: this EA is tuned for the M1 timeframe. Current timeframe: ", EnumToString((ENUM_TIMEFRAMES)Period()));

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0 && StringFind(_Symbol, "Gold") < 0)
      Print("NOTE: symbol ", _Symbol, " does not look like gold. Re-check the grid step setting.");

   PrintFormat("GoldDualBasketGridEA started | symbol=%s digits=%d point=%.5f volumeStep=%.2f",
               _Symbol, _Digits, _Point, vstep);
   double step1 = CurrentStepPoints(1);
   PrintFormat("Grid step (level 1) = %.0f points = %.2f price units | step mode=%s",
               step1, step1 * _Point, EnumToString(InpStepMode));
   PrintFormat("Lot plan: %s | L1=%.2f L2=%.2f L3=%.2f L4=%.2f L5=%.2f",
               EnumToString(InpLotMode), LotForLevel(1), LotForLevel(2),
               LotForLevel(3), LotForLevel(4), LotForLevel(5));
   PrintFormat("Basket targets: BUY %.2f | SELL %.2f (%s)",
               InpBuyTargetMoney, InpSellTargetMoney, EnumToString(InpTargetMode));

//--- sanity: a step smaller than a few spreads turns the grid into noise
   double spreadNow = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadNow > 0.0 && step1 < spreadNow * 5.0)
      PrintFormat("WARNING: grid step (%.0f pts) is close to the current spread (%.0f pts). Consider a wider step.",
                  step1, spreadNow);

   DrawDashboard(true);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!Sym.RefreshRates())
      return;

   BasketInfo buy, sell;
   ScanBasket(InpMagicBuy, POSITION_TYPE_BUY, buy);
   ScanBasket(InpMagicSell, POSITION_TYPE_SELL, sell);

//--- 1) hard protections first ------------------------------------
   if(CheckEquityStop(buy, sell))
     {
      DrawDashboard(true);
      return;
     }

   if(CheckWeekendFlatten(buy, sell))
     {
      DrawDashboard(true);
      return;
     }

//--- 2) basket take profit - each side judged on its OWN money -----
   bool didClose = false;

   if(buy.count > 0 && BasketShouldClose(buy, true))
     {
      if(CloseBasket(InpMagicBuy))
        {
         PrintFormat("BUY basket closed in profit: %d position(s), %.2f lots, %.2f %s",
                     buy.count, buy.lots, buy.profit, AccountInfoString(ACCOUNT_CURRENCY));
         g_buyClosedAt   = TimeCurrent();
         g_buyClosePrice = Sym.Bid();
         g_buyPeakProfit = 0.0;
         didClose = true;
        }
     }

   if(sell.count > 0 && BasketShouldClose(sell, false))
     {
      if(CloseBasket(InpMagicSell))
        {
         PrintFormat("SELL basket closed in profit: %d position(s), %.2f lots, %.2f %s",
                     sell.count, sell.lots, sell.profit, AccountInfoString(ACCOUNT_CURRENCY));
         g_sellClosedAt   = TimeCurrent();
         g_sellClosePrice = Sym.Ask();
         g_sellPeakProfit = 0.0;
         didClose = true;
        }
     }

   if(didClose)
     {
      // the snapshot is stale now - force a redraw and let the next tick
      // handle the re-entry
      DrawDashboard(true);
      return;
     }

//--- 3) entry / averaging is subject to the soft filters -----------
   if(TradingAllowed())
     {
      //--- 3a) cold start only: nothing open AND nothing harvested pending re-entry
      bool coldStart = (buy.count == 0 && sell.count == 0 &&
                        g_buyClosedAt == 0 && g_sellClosedAt == 0);

      if(InpOpenBothOnStart && InpAllowNewCycles && !g_halted && coldStart)
        {
         OpenLevel(true, 1);
         OpenLevel(false, 1);
        }
      else
        {
         //--- 3b) averaging on the losing side
         ManageGrid(buy,  true);
         ManageGrid(sell, false);

         //--- 3c) re-open the harvested side so it keeps riding the move
         ManageReopen(buy,  true);
         ManageReopen(sell, false);
        }
     }

   DrawDashboard();
  }

//+------------------------------------------------------------------+
//| Collect a per-side snapshot (one magic = one basket)             |
//+------------------------------------------------------------------+
void ScanBasket(const long magic, const ENUM_POSITION_TYPE type, BasketInfo &b)
  {
   ResetBasket(b);

   double weighted = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!Pos.SelectByIndex(i))
         continue;
      if(Pos.Symbol() != _Symbol)
         continue;
      if(Pos.Magic() != magic)
         continue;
      if(Pos.PositionType() != type)
         continue;

      double lot   = Pos.Volume();
      double price = Pos.PriceOpen();

      b.count++;
      b.lots   += lot;
      b.profit += Pos.Profit() + Pos.Swap();
      weighted += price * lot;

      if(b.minPrice == 0.0 || price < b.minPrice)
         b.minPrice = price;
      if(price > b.maxPrice)
         b.maxPrice = price;
      if(Pos.Time() > b.lastOpenTime)
         b.lastOpenTime = Pos.Time();
     }

   if(b.lots > 0.0)
      b.avgPrice = weighted / b.lots;

//--- subtract an estimated round-turn commission so the target is honest
   if(InpCommissionPerLotRT > 0.0)
      b.profit -= InpCommissionPerLotRT * b.lots;
  }

//+------------------------------------------------------------------+
//| Money target for a basket                                        |
//+------------------------------------------------------------------+
double BasketTarget(const BasketInfo &b, const bool isBuy)
  {
   double base = isBuy ? InpBuyTargetMoney : InpSellTargetMoney;
   if(base <= 0.0)
      base = 1.0;

   if(InpTargetMode == TARGET_PER_LOT)
      return base * MathMax(b.lots, 0.01);

   return base;
  }

//+------------------------------------------------------------------+
//| Should this basket be flattened now?                             |
//| Only ever true while the basket is in positive money.            |
//+------------------------------------------------------------------+
bool BasketShouldClose(const BasketInfo &b, const bool isBuy)
  {
   double target = BasketTarget(b, isBuy);

   if(!InpUseBasketTrailing)
      return (b.profit >= target);

//--- trailing variant: once the target is reached, ride it a bit further
   double peak = isBuy ? g_buyPeakProfit : g_sellPeakProfit;

   if(b.profit >= target)
     {
      if(b.profit > peak)
        {
         peak = b.profit;
         if(isBuy)
            g_buyPeakProfit = peak;
         else
            g_sellPeakProfit = peak;
        }
     }

   if(peak >= target)
     {
      double giveBack = MathMax(0.01, InpBasketTrailMoney);
      //--- lock in: never let it drop below the target itself
      double stopLevel = MathMax(target, peak - giveBack);
      if(b.profit <= stopLevel)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Close every position of one basket (all at once, with retries)   |
//+------------------------------------------------------------------+
bool CloseBasket(const long magic)
  {
   Trade.SetExpertMagicNumber(magic);

   for(int attempt = 0; attempt < 5; attempt++)
     {
      bool anyLeft = false;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!Pos.SelectByIndex(i))
            continue;
         if(Pos.Symbol() != _Symbol)
            continue;
         if(Pos.Magic() != magic)
            continue;

         anyLeft = true;
         if(!Trade.PositionClose(Pos.Ticket(), (ulong)MathMax(1, InpSlippagePoints)))
            g_lastError = StringFormat("close #%I64u failed: %d %s",
                                       Pos.Ticket(), Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
        }

      if(!anyLeft)
         return true;

      Sleep(150);
      Sym.RefreshRates();
     }

//--- still something left: report and retry on the next tick
   Print("WARNING: basket ", magic, " not fully closed. ", g_lastError);
   return false;
  }

//+------------------------------------------------------------------+
//| Grid step in points for the level that is about to be added      |
//| level = number of positions already open in that basket          |
//+------------------------------------------------------------------+
double CurrentStepPoints(const int level)
  {
   double stepPts;

   switch(InpStepMode)
     {
      case STEP_ATR:
         stepPts = ATRPoints() * MathMax(0.1, InpATRMultiplier);
         if(stepPts <= 0.0)                          // ATR not ready yet
            stepPts = InpGridStepPrice / _Point;
         break;

      case STEP_POINTS:
         stepPts = InpGridStepPoints;
         break;

      default: // STEP_PRICE - independent of the broker's digit count
         stepPts = InpGridStepPrice / _Point;
         break;
     }

//--- widen deeper levels so the grid does not choke in a strong trend
   if(InpStepWidenFactor > 1.0 && level > 1)
      stepPts *= MathPow(InpStepWidenFactor, level - 1);

//--- never go below the floor, and never below a few spreads
   double spreadPts  = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double floorPts   = MathMax(0.0, InpMinStepPrice) / _Point;
   double minAllowed = MathMax(floorPts, spreadPts * 3.0);

   return MathMax(stepPts, minAllowed);
  }

//+------------------------------------------------------------------+
//| ATR value expressed in points                                    |
//+------------------------------------------------------------------+
double ATRPoints()
  {
   if(g_atrHandle == INVALID_HANDLE)
      return 0.0;

   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) < 1)
      return 0.0;
   if(buf[0] <= 0.0)
      return 0.0;

   return buf[0] / _Point;
  }

//+------------------------------------------------------------------+
//| Lot for a given grid level (1 based) - smooth by design          |
//+------------------------------------------------------------------+
double LotForLevel(const int level)
  {
   int lv = MathMax(1, level);
   double lot;

   switch(InpLotMode)
     {
      case LOT_ADDITIVE:
         lot = InpBaseLot + (lv - 1) * MathMax(0.0, InpLotIncrement);
         break;

      case LOT_MULTIPLY:
         // computed from the level (not from the previous rounded lot) so a
         // gentle factor like 1.2 still grows instead of stalling on rounding
         lot = InpBaseLot * MathPow(MathMax(1.0, InpLotMultiplier), lv - 1);
         break;

      default: // LOT_FIXED
         lot = InpBaseLot;
         break;
     }

   if(InpMaxLotPerOrder > 0.0)
      lot = MathMin(lot, InpMaxLotPerOrder);

   return NormalizeLot(lot);
  }

//+------------------------------------------------------------------+
//| Round a volume to the broker's constraints                       |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   lot = MathFloor(lot / step + 0.5) * step;

   if(lot < minLot)
      lot = minLot;
   if(maxLot > 0.0 && lot > maxLot)
      lot = maxLot;

   return NormalizeDouble(lot, g_volumeDigits);
  }

//+------------------------------------------------------------------+
//| Averaging: add one level when price runs against the basket      |
//+------------------------------------------------------------------+
void ManageGrid(const BasketInfo &b, const bool isBuy)
  {
   if(b.count <= 0)
      return;
   if(g_halted)
      return;

//--- level caps
   if(InpMaxPositionsPerBasket > 0 && b.count >= InpMaxPositionsPerBasket)
      return;
   if(InpMaxLotsPerBasket > 0.0 && b.lots >= InpMaxLotsPerBasket)
      return;

//--- do not stack several levels inside one spike
   if(InpMinSecondsBetweenAdds > 0 &&
      (TimeCurrent() - b.lastOpenTime) < InpMinSecondsBetweenAdds)
      return;

   double stepPrice = CurrentStepPoints(b.count) * _Point;
   if(stepPrice <= 0.0)
      return;

   bool trigger = false;

   if(isBuy)
     {
      // buy hurts when price falls: measure from the LOWEST buy entry
      double reference = b.minPrice - stepPrice;
      trigger = (Sym.Ask() <= reference);
     }
   else
     {
      // sell hurts when price rises: measure from the HIGHEST sell entry
      double reference = b.maxPrice + stepPrice;
      trigger = (Sym.Bid() >= reference);
     }

   if(!trigger)
      return;

//--- would the next level break the basket volume cap?
   int    nextLevel = b.count + 1;
   double nextLot   = LotForLevel(nextLevel);

   if(InpMaxLotsPerBasket > 0.0 && (b.lots + nextLot) > InpMaxLotsPerBasket)
     {
      double room = NormalizeLot(InpMaxLotsPerBasket - b.lots);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(room < minLot)
         return;
      nextLot = room;
     }

   if(OpenPosition(isBuy, nextLot, StringFormat("%s-%s-L%d", InpTradeComment, (isBuy ? "B" : "S"), nextLevel)))
      PrintFormat("%s averaging level %d added: %.2f lots (step %.0f pts, basket avg %.*f)",
                  (isBuy ? "BUY" : "SELL"), nextLevel, nextLot,
                  CurrentStepPoints(b.count), _Digits, b.avgPrice);
  }

//+------------------------------------------------------------------+
//| Re-open level 1 on a side that was just harvested                |
//+------------------------------------------------------------------+
void ManageReopen(const BasketInfo &b, const bool isBuy)
  {
   if(b.count > 0)
      return;
   if(!InpReopenAfterProfit || !InpAllowNewCycles || g_halted)
      return;

   datetime closedAt = isBuy ? g_buyClosedAt : g_sellClosedAt;
   if(closedAt == 0)
      return;   // nothing was harvested on this side yet

   if(InpReopenDelaySeconds > 0 && (TimeCurrent() - closedAt) < InpReopenDelaySeconds)
      return;

//--- optionally wait for a small pullback so we do not re-enter at the extreme
   if(InpReopenPullbackPoints > 0.0)
     {
      double pull = InpReopenPullbackPoints * _Point;
      if(isBuy)
        {
         // buy was closed after an up move: wait for price to dip back
         if(g_buyClosePrice > 0.0 && Sym.Ask() > (g_buyClosePrice - pull))
            return;
        }
      else
        {
         if(g_sellClosePrice > 0.0 && Sym.Bid() < (g_sellClosePrice + pull))
            return;
        }
     }

   if(OpenLevel(isBuy, 1))
     {
      if(isBuy)
         g_buyClosedAt = 0;
      else
         g_sellClosedAt = 0;
     }
  }

//+------------------------------------------------------------------+
//| Open one grid level                                              |
//+------------------------------------------------------------------+
bool OpenLevel(const bool isBuy, const int level)
  {
   double lot = LotForLevel(level);
   return OpenPosition(isBuy, lot,
                       StringFormat("%s-%s-L%d", InpTradeComment, (isBuy ? "B" : "S"), level));
  }

//+------------------------------------------------------------------+
//| Raw order send with margin check and one retry                   |
//+------------------------------------------------------------------+
bool OpenPosition(const bool isBuy, const double lot, const string comment)
  {
   if(lot <= 0.0)
      return false;

   Sym.RefreshRates();

   ENUM_ORDER_TYPE type  = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double          price = isBuy ? Sym.Ask() : Sym.Bid();

   if(price <= 0.0)
      return false;

//--- margin sanity check
   double margin = 0.0;
   if(OrderCalcMargin(type, _Symbol, lot, price, margin))
     {
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
        {
         PrintFormat("Skipped %s %.2f lots: needs %.2f margin, only %.2f free",
                     (isBuy ? "BUY" : "SELL"), lot, margin, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
         return false;
        }
     }

   Trade.SetExpertMagicNumber(isBuy ? InpMagicBuy : InpMagicSell);
   Trade.SetDeviationInPoints((ulong)MathMax(1, InpSlippagePoints));

   for(int attempt = 0; attempt < 3; attempt++)
     {
      bool ok = isBuy
                ? Trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, comment)
                : Trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, comment);

      if(ok)
        {
         uint rc = Trade.ResultRetcode();
         if(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED ||
            rc == TRADE_RETCODE_DONE_PARTIAL)
            return true;
        }

      g_lastError = StringFormat("%s %.2f failed: %d %s",
                                 (isBuy ? "BUY" : "SELL"), lot,
                                 Trade.ResultRetcode(), Trade.ResultRetcodeDescription());

      uint rc = Trade.ResultRetcode();
      //--- only transient problems are worth a retry
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
         rc != TRADE_RETCODE_PRICE_OFF && rc != TRADE_RETCODE_TIMEOUT &&
         rc != TRADE_RETCODE_CONNECTION)
         break;

      Sleep(200);
      Sym.RefreshRates();
     }

   Print("Order error: ", g_lastError);
   return false;
  }

//+------------------------------------------------------------------+
//| Soft filters that gate NEW orders only                           |
//+------------------------------------------------------------------+
bool TradingAllowed()
  {
   if(g_halted)
      return false;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return false;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
      return false;

//--- spread guard: gold spreads blow out around news and rollover
   if(InpMaxSpreadPoints > 0.0)
     {
      double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spreadPts > InpMaxSpreadPoints)
         return false;
     }

//--- trading window
   if(InpUseTimeFilter)
     {
      MqlDateTime st;
      TimeToStruct(TimeCurrent(), st);
      int h = st.hour;

      if(InpStartHour <= InpEndHour)
        {
         if(h < InpStartHour || h > InpEndHour)
            return false;
        }
      else
        {
         // window wraps midnight
         if(h < InpStartHour && h > InpEndHour)
            return false;
        }
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Floating drawdown protection                                     |
//+------------------------------------------------------------------+
bool CheckEquityStop(const BasketInfo &buy, const BasketInfo &sell)
  {
   if(!InpUseEquityStop)
      return false;
   if(buy.count == 0 && sell.count == 0)
      return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return false;

   double floating = buy.profit + sell.profit;
   if(floating >= 0.0)
      return false;

   double ddPercent = (-floating / balance) * 100.0;
   if(ddPercent < InpEquityStopPercent)
      return false;

   PrintFormat("EQUITY STOP: floating %.2f = %.2f%% of balance %.2f - flattening everything.",
               floating, ddPercent, balance);

   CloseBasket(InpMagicBuy);
   CloseBasket(InpMagicSell);

   g_buyPeakProfit  = 0.0;
   g_sellPeakProfit = 0.0;
   g_buyClosedAt    = 0;
   g_sellClosedAt   = 0;

   if(InpHaltAfterEquityStop)
     {
      g_halted = true;
      Print("EA halted after equity stop. Remove and re-attach the EA to resume.");
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Optional Friday flatten                                          |
//+------------------------------------------------------------------+
bool CheckWeekendFlatten(const BasketInfo &buy, const BasketInfo &sell)
  {
   if(!InpCloseBeforeWeekend)
      return false;
   if(buy.count == 0 && sell.count == 0)
      return false;

   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);

   if(st.day_of_week != 5 || st.hour < InpFridayCloseHour)
      return false;

   Print("Friday flatten: closing both baskets before the weekend.");
   CloseBasket(InpMagicBuy);
   CloseBasket(InpMagicSell);
   g_buyClosedAt  = 0;
   g_sellClosedAt = 0;
   return true;
  }

//+------------------------------------------------------------------+
//| On-chart dashboard                                               |
//+------------------------------------------------------------------+
void DrawDashboard(const bool force)   // default value is on the prototype
  {
   if(!InpShowDashboard)
      return;

//--- throttle to once per second: M1 gold delivers a lot of ticks and the
//--- refresh needs its own position scan
   static datetime lastDraw = 0;
   datetime now = TimeCurrent();
   if(!force && now == lastDraw)
      return;
   lastDraw = now;

   BasketInfo buy, sell;
   ScanBasket(InpMagicBuy, POSITION_TYPE_BUY, buy);
   ScanBasket(InpMagicSell, POSITION_TYPE_SELL, sell);

   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   string txt = "==== Gold Dual-Basket Grid EA ====\n";
   txt += StringFormat("Symbol: %s   TF: %s   Spread: %d pts\n",
                       _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
                       (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   txt += StringFormat("Grid step next: %.0f pts   Lot mode: %s\n",
                       CurrentStepPoints(MathMax(1, MathMax(buy.count, sell.count))),
                       EnumToString(InpLotMode));
   txt += "-----------------------------------\n";
   txt += StringFormat("BUY  basket : %d pos | %.2f lots\n", buy.count, buy.lots);
   txt += StringFormat("             P/L %.2f %s  ->  target %.2f\n",
                       buy.profit, cur, BasketTarget(buy, true));
   if(buy.count > 0)
      txt += StringFormat("             avg %.*f | lowest %.*f | next lot %.2f\n",
                          _Digits, buy.avgPrice, _Digits, buy.minPrice, LotForLevel(buy.count + 1));
   txt += "-----------------------------------\n";
   txt += StringFormat("SELL basket : %d pos | %.2f lots\n", sell.count, sell.lots);
   txt += StringFormat("             P/L %.2f %s  ->  target %.2f\n",
                       sell.profit, cur, BasketTarget(sell, false));
   if(sell.count > 0)
      txt += StringFormat("             avg %.*f | highest %.*f | next lot %.2f\n",
                          _Digits, sell.avgPrice, _Digits, sell.maxPrice, LotForLevel(sell.count + 1));
   txt += "-----------------------------------\n";
   txt += StringFormat("Floating total: %.2f %s\n", buy.profit + sell.profit, cur);
   txt += StringFormat("Balance %.2f | Equity %.2f | Free margin %.2f\n",
                       AccountInfoDouble(ACCOUNT_BALANCE),
                       AccountInfoDouble(ACCOUNT_EQUITY),
                       AccountInfoDouble(ACCOUNT_MARGIN_FREE));
   txt += StringFormat("Status: %s\n", (g_halted ? "HALTED (equity stop)"
                                        : (InpAllowNewCycles ? "running" : "winding down")));
   if(g_lastError != "")
      txt += "Last issue: " + g_lastError + "\n";

   Comment(txt);
  }
//+------------------------------------------------------------------+
