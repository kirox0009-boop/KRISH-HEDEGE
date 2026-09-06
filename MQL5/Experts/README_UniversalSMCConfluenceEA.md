# Universal SMC Confluence EA for MT5

`UniversalSMCConfluenceEA.mq5` is a direction-only, risk-based Expert Advisor. It evaluates six independent feature families on completed candles, requires configurable directional confluence, calculates a structural/ATR stop, and places a server-side TP of at least 2R. It does **not** use grid averaging, martingale, simultaneous hedging, or a guaranteed-profit model.

## Strategy definitions

All entry analysis uses closed bars on `InpSignalTimeframe`; confirmed pivots require bars on both sides and therefore do not use future information after confirmation.

1. **SMC / market structure:** confirmed swing highs and lows establish HH/HL or LH/LL structure. A closed-candle break of a confirmed swing is treated as BOS; the opposing swing supplies invalidation.
2. **Fair value gap (FVG):** a three-candle wick imbalance must exceed `InpFVGMinimumATR`. The zone remains usable until a candle closes through its invalidation and price is at/near the zone.
3. **Order block:** the final opposing candle before an ATR-qualified displacement is used as the zone. Price must remain near that candle and on its valid side.
4. **Liquidity sweep:** the signal candle must trade beyond the recent lookback extreme and close back inside it.
5. **Breakout:** the candle must close beyond the recent range with a minimum body and volatility buffer.
6. **Trend line:** two confirmed rising swing lows form bullish support; two falling swing highs form bearish resistance. The completed candle must reject the projected line within ATR tolerance.

Each enabled family contributes at most one vote. A trade needs `InpMinimumConfluence` votes in one direction, more votes than the opposite direction, and—by default—matching H1 structure/mean bias. The dashboard shows every current feature direction and the rejection reason.

## SL, TP and lot calculation

- The initial SL is placed beyond the deepest matching feature invalidation plus `InpStopBufferATR`. If a valid structural reference is unavailable, an ATR fallback is used.
- Stops are aligned to the symbol's trade tick size and expanded when needed to satisfy the broker's stop level.
- Setups wider than `InpMaximumStopATR` are rejected.
- `InpMinimumRewardRisk` cannot be configured below `2.0`. TP is calculated from actual risk and checked again after the fill. If slippage makes TP less than the configured R multiple, TP is moved outward. If protection cannot be verified, the EA attempts to close the position.
- Volume is calculated from equity or balance risk using `OrderCalcProfit`, then floored to the broker's volume step. If the broker minimum lot would exceed the risk budget, no trade is placed. After the fill, actual money risk is recalculated; the position is closed if slippage exceeds `InpMaximumRiskOvershootPct` above the budget.
- Margin reserve, fixed/ATR spread filters, cooldown, session/weekend lock, one-position-per-symbol, and daily realized-loss controls can block new entries. Existing positions continue to be managed.

Break-even can activate at 1R. ATR trailing can activate later; both only tighten risk and never deliberately widen the stop. Initial R is stored in an MT5 terminal global variable and recovered from the original position-order history when available. Every owned ticket is safety-checked on startup and during operation; if initial risk or required server protection cannot be verified, the EA persists an emergency-close state and retries containment after restart.

## Install and run

1. Copy `MQL5/Experts/UniversalSMCConfluenceEA.mq5` into the terminal's `MQL5/Experts` directory.
2. Compile it in MetaEditor.
3. Open the desired asset chart and attach one EA instance. The chart period itself may differ; the EA reads `InpSignalTimeframe` and `InpTrendTimeframe` explicitly.
4. Load `MQL5/Presets/Universal_SMC_M15_Conservative.set` as a conservative starting profile.
5. Enable Algo Trading and confirm the Experts log says the EA is ready.
6. For several assets, attach one instance per symbol. Use a different `InpMagicNumber` for another instance on the same symbol. On netting accounts, reserve the entire symbol exclusively for this EA while its position is open: MT5 merges all deals on a symbol, so manual or foreign-EA deals cannot be managed independently. The EA blocks foreign positions before entry and pauses management with a critical alert if it detects a later foreign deal merged into its active netting symbol.

### Hindi quick start

EA ko desired asset ke chart par attach karein, preset load karein, aur pehle Strategy Tester/demo par verify karein. Har symbol ke liye alag chart instance use karein. Same symbol par doosra instance ho to unique magic number dein. Default risk 0.5% per trade aur minimum TP 1:2 hai.

## Broker and asset portability

The code reads each current chart symbol's digits, point, tick size, tick value through `OrderCalcProfit`, minimum/maximum/step volume, stop/freeze levels, filling policy, live spread, and margin requirement. It supports directional operation on hedging accounts and on netting accounts where the symbol is reserved exclusively for this EA. Symbol suffixes such as `EURUSD.a` or `XAUUSDm` require no hard-coded name.

“Portable” does not mean one parameter set is suitable everywhere. Forex, metals, indices, energy, equities, and crypto CFDs have different sessions, gaps, volatility, spreads, contract specifications, and minimum lots. Optimize thresholds and timeframes separately for each broker-symbol pair.

## Recommended validation

Before live use, run MT5 Strategy Tester with **Every tick based on real ticks** and visual mode. Check at least:

- entries occur only after a signal candle closes;
- the log/dashboard reports at least the configured number of matching families;
- every accepted fill has a server-side SL and TP at or beyond 2R;
- risk money remains close to the configured percentage for that symbol;
- spread, daily-loss, cooldown, Friday, and foreign-position locks work;
- break-even/trailing never move SL away from profit;
- behavior survives terminal restart with an open position;
- results remain acceptable out of sample and across different market regimes.

## Important limitations

No SMC, FVG, breakout, or trend-line definition guarantees profitable trades. Backtests can overfit, execution can gap beyond SL, and broker data/contract rules vary. The daily loss guard covers realized deals for this EA's symbol and magic; it is not an account-wide kill switch. The EA manages one owned position per symbol and intentionally does not pyramid or average losses. Use demo/forward testing and capital you can afford to risk. No profitability claim is made.
