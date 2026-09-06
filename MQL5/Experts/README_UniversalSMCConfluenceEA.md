# Universal Independent Strategy EA for MT5

> The source filename remains `UniversalSMCConfluenceEA.mq5` for compatibility with the existing pull request, but version 2.00 has **no voting or confluence gate**.

This EA runs six completely independent strategy engines on completed candles:

1. SMC / market structure
2. Fair Value Gap (FVG)
3. Order Block
4. Liquidity Sweep
5. Breakout
6. Confirmed-pivot Trend Line

## Independent-order behavior

Every enabled strategy is evaluated separately on every newly closed `InpSignalTimeframe` candle. If several strategies signal on the same candle, the EA attempts every qualifying order in that candle; one strategy's open position does not block the others.

Each strategy has its own:

- magic number;
- open-position check;
- cooldown;
- order comment and dashboard status;
- signal direction and invalidation level;
- risk-based volume calculation;
- server-side SL and TP;
- break-even and ATR trailing management.

The EA permits one open position per strategy on a symbol. An existing SMC position blocks only another SMC entry; FVG, order block, sweep, breakout, and trend-line entries remain eligible. Opposite strategy directions can coexist.

There is no vote count, minimum-confluence setting, winning signal, shared direction selection, or higher-timeframe agreement requirement.

## Magic-number mapping

`InpMagicNumber` is the base. The six independent strategy magics are:

| Offset | Strategy | Default magic |
|---:|---|---:|
| +0 | SMC | 26090601 |
| +1 | FVG | 26090602 |
| +2 | Order Block | 26090603 |
| +3 | Liquidity Sweep | 26090604 |
| +4 | Breakout | 26090605 |
| +5 | Trend Line | 26090606 |

Choose a base range that does not overlap another EA instance.

## Hedging account is required

MT5 **hedging mode is mandatory** for this version. A netting account merges all orders for the same symbol into one position, making separate per-strategy SL, TP, direction, ticket, and management impossible. The EA therefore refuses initialization on netting/exchange accounts rather than silently merging strategies.

## Strategy definitions

- **SMC:** confirmed swing highs/lows establish HH/HL or LH/LL structure; a completed-candle swing break can generate a directional signal.
- **FVG:** a three-candle wick imbalance must exceed the configured ATR width and price must be at/near a still-valid zone.
- **Order Block:** the final opposing candle before ATR-qualified displacement forms the zone; intervening closes through invalidation cancel it.
- **Liquidity Sweep:** the signal candle trades beyond the recent range extreme and closes back inside.
- **Breakout:** the signal candle closes beyond the recent range with body and ATR displacement requirements.
- **Trend Line:** two confirmed rising lows or falling highs project support/resistance; the completed candle must reject the line within ATR tolerance.

All entry detectors use completed bars and confirmed pivots. There is no current-candle entry signal.

## SL, TP and risk

Each strategy order calculates protection from **that strategy's own invalidation**:

- SL is placed beyond its signal invalidation plus `InpStopBufferATR`; ATR fallback is used only when needed.
- Stop distance is normalized to the symbol's tick size and broker stop/freeze requirements.
- TP is at least `InpMinimumRewardRisk`, which cannot be configured below `2.0`.
- Post-fill code rechecks the actual entry, SL, TP and money risk. An unsafe ticket is contained and retried independently on following ticks/restart scans without blocking healthy strategies.
- Volume is calculated independently for each order through `OrderCalcProfit` and floored to the broker's volume step.
- Break-even and ATR trailing operate by ticket and only tighten that ticket's SL.

`InpRiskPercent` is **per strategy order**, not divided among strategies. At the default 0.5%, six simultaneous entries can initially risk approximately 3% plus slippage/gaps. Reduce it to about 0.15–0.25% if that combined exposure is too high. The combined daily realized-loss filter covers all six strategy magic numbers.

## Install and run

1. Use an MT5 hedging account.
2. Copy `MQL5/Experts/UniversalSMCConfluenceEA.mq5` into the terminal's `MQL5/Experts` folder and compile it in MetaEditor.
3. Attach one instance to the desired asset chart.
4. Load `MQL5/Presets/Universal_SMC_M15_Conservative.set`.
5. Ensure the base magic range `InpMagicNumber` through `InpMagicNumber + 5` is unused by another instance.
6. Enable Algo Trading and confirm the Experts log reports independent-strategy mode.
7. Attach separate instances to other asset charts with non-overlapping magic ranges.

### Hindi quick start

Bot me voting hata di gayi hai. Har strategy apna signal milne par apna alag order, SL aur TP lagati hai. Ek strategy ka running trade baaki strategies ko block nahi karta. Same symbol par alag positions aur SL/TP ke liye hedging account zaroori hai. Default risk 0.5% **har strategy order** ka hai; agar chhe signals ek saath aayein to combined initial risk lagbhag 3% ho sakta hai.

## Shared safety filters

Session/weekend, spread, free-margin reserve, long/short enable flags, and combined daily-loss controls remain shared safety gates. These can block an otherwise valid strategy signal, but a position or cooldown belonging to one strategy cannot block another strategy.

## Validation required

Before live use, compile in MetaEditor and use Strategy Tester with **Every tick based on real ticks**. Verify:

- multiple strategies that signal on one closed candle create multiple tickets;
- every ticket has the expected strategy magic, its own SL, and its own TP;
- an open SMC ticket does not prevent another strategy's order;
- every initial TP remains at least 2R after fill;
- each strategy's cooldown affects only that strategy;
- break-even/trailing modifies only the intended ticket;
- combined exposure and margin remain acceptable when several signals occur together.

No strategy guarantees profit. Broker execution, gaps, spread, contract specifications, and market regimes vary. Backtest and demo-forward-test each broker/symbol configuration before live trading.
