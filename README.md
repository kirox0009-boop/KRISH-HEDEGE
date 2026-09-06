# KRISH-HEDEGE — Gold Dual-Basket Grid EA (MT5)

MetaTrader 5 Expert Advisor for **XAUUSD (Gold) on the M1 timeframe**.

Buy aur Sell ke do **alag-alag independent baskets** chalte hain. Jo side profit me aata hai uska **pura basket ek saath close** hota hai (per-order close nahi), aur jo side loss me jaata hai usme **smooth averaging** grid add hoti hai. Combined/overall equity kabhi close trigger nahi banta.

> **File:** [`MQL5/Experts/GoldDualBasketGridEA.mq5`](MQL5/Experts/GoldDualBasketGridEA.mq5)

---

## Core logic (jo aapne bataya)

```
Start  ->  1 BUY + 1 SELL simultaneously open
           |
           |-- BUY basket  (magic 20260901)  --> apna alag P/L, apna alag target
           |-- SELL basket (magic 20260902)  --> apna alag P/L, apna alag target
```

**Market UP jaata hai:**

| Side | Kya hota hai |
|------|--------------|
| BUY | Basket profit `>= $1` hua → **saare buy positions close** → turant naya `0.01` BUY open → phir profit → phir close → repeat |
| SELL | Loss me hai → close **nahi** hota. Har `$3` upar jaane par ek averaging SELL add hoti hai (`0.01 → 0.02 → 0.03 → 0.04 → 0.05 ...`) |

**Market ab REVERSE (neeche) aata hai:**

| Side | Kya hota hai |
|------|--------------|
| SELL | Averaged basket ka average price paas aa gaya → total `>= $1` → **poora sell basket close** |
| BUY | Ab yeh loss me gaya → averaging start, har `$3` par ek level |

Cycle aise hi mirror hota rehta hai. Yehi aapka described system hai.

### 3 important points jo exactly implement kiye gaye hain

1. **Basket-level close, per-order nahi.** Agar BUY me 5 positions hain (`0.01, 0.02, 0.03, 0.04, 0.05`), EA sabka combined P/L jodta hai. Jab total `>= target` ho tabhi **saari 5 ek saath** close hoti hain. Koi single position individually profit me ho to bhi akeli close nahi hogi.
2. **Buy aur Sell completely separate.** Do alag magic numbers. `buy.profit` aur `sell.profit` kabhi add nahi hote decision ke liye.
3. **Smooth lot, aggressive nahi.** Default **additive** mode: `base + (level-1) × increment` → `0.01, 0.02, 0.03, 0.04, 0.05`. Martingale doubling (`0.01→0.02→0.04→0.08→0.16`) default me **nahi** hai.

---

## Requirements

| Cheez | Value |
|------|-------|
| Platform | MetaTrader **5** (MT4 pe nahi chalega) |
| Account type | **HEDGING** — mandatory. Netting account pe EA `OnInit` me hi reject kar dega |
| Symbol | XAUUSD / GOLD (broker ka jo naam ho) |
| Timeframe | M1 |
| Algo Trading | Terminal me enabled hona chahiye |

Hedging check karne ka tareeka: MT5 → Tools → Options → ya account ke "Trade" tab me position type dekhein. Netting account pe buy+sell simultaneously nahi rakh sakte, isliye EA kaam nahi karega.

---

## Installation

1. MT5 kholein → **File → Open Data Folder**
2. `MQL5/Experts/` folder me `GoldDualBasketGridEA.mq5` copy karein
3. MT5 me **F4** dabayein (MetaEditor khulega) → file open karein → **F7** (Compile). `0 errors, 0 warnings` aana chahiye
4. MT5 me wapas jaayein → Navigator → Expert Advisors → EA ko **XAUUSD M1** chart pe drag karein
5. **Common** tab me "Allow Algo Trading" tick karein → OK
6. Toolbar ka **Algo Trading** button green hona chahiye

Chart pe ek dashboard dikhega — dono baskets ka live count, lots, P/L, target aur next lot.

---

## Inputs reference

### Identification
| Input | Default | Matlab |
|-------|---------|--------|
| `InpMagicBuy` | 20260901 | BUY basket ka ID. **Sell se different hona zaroori hai** |
| `InpMagicSell` | 20260902 | SELL basket ka ID |
| `InpTradeComment` | GDBG | Order comment prefix |

### Lot sizing (smooth averaging)
| Input | Default | Matlab |
|-------|---------|--------|
| `InpBaseLot` | 0.01 | Level 1 ka lot |
| `InpLotMode` | `LOT_ADDITIVE` | `LOT_FIXED` = har level same lot · `LOT_ADDITIVE` = 0.01, 0.02, 0.03... · `LOT_MULTIPLY` = base × factor^(level-1) |
| `InpLotIncrement` | 0.01 | Additive mode me per level kitna add ho |
| `InpLotMultiplier` | 1.20 | Multiply mode ka factor. **1.3 se zyada na rakhein** |
| `InpMaxLotPerOrder` | 0.50 | Single order ka max lot |
| `InpMaxLotsPerBasket` | 3.00 | Ek basket ka max total volume (0 = off) |

Lot plan EA startup pe Experts log me print hota hai, to attach karke verify kar sakte hain.

### Grid / averaging distance
| Input | Default | Matlab |
|-------|---------|--------|
| `InpStepMode` | `STEP_PRICE` | `STEP_PRICE` = price units me ($3 gold move) — **broker-safe, recommended** · `STEP_POINTS` = points me · `STEP_ATR` = volatility ke hisaab se auto |
| `InpGridStepPrice` | 3.00 | PRICE mode: `$3` gold movement par next level |
| `InpGridStepPoints` | 300 | POINTS mode ka step |
| `InpATRPeriod` / `InpATRMultiplier` | 14 / 1.5 | ATR mode settings |
| `InpStepWidenFactor` | 1.00 | Deeper levels ka step widen karna. `1.15` = har level 15% door |
| `InpMinStepPrice` | 1.00 | Step ka hard floor |
| `InpMaxPositionsPerBasket` | 15 | Max grid levels per basket |
| `InpMinSecondsBetweenAdds` | 20 | Do adds ke beech min gap (news spike me stacking rokta hai) |

> **`STEP_PRICE` kyun default hai:** kuch brokers gold 2-digit dete hain (`2650.35`, 1 point = `0.01`) aur kuch 3-digit (`2650.352`, 1 point = `0.001`). Points me step dene se **same setting do brokers pe 10× alag** ho jaati hai. `STEP_PRICE` me aap seedha `3.0` likhte hain = `$3` gold move, dono brokers pe identical.

### Basket take profit
| Input | Default | Matlab |
|-------|---------|--------|
| `InpTargetMode` | `TARGET_FIXED_MONEY` | `TARGET_FIXED_MONEY` = fixed amount · `TARGET_PER_LOT` = amount × basket volume |
| `InpBuyTargetMoney` | 1.00 | BUY basket ka profit target |
| `InpSellTargetMoney` | 1.00 | SELL basket ka profit target |
| `InpCommissionPerLotRT` | 0.00 | Round-turn commission per 1.00 lot. **ECN account pe zaroor set karein** warna target commission ke baad actually pura nahi hoga |
| `InpUseBasketTrailing` | false | Target hit hone ke baad profit trail karke thoda zyada nikalna |
| `InpBasketTrailMoney` | 0.50 | Trail give-back distance |

### Cycle behaviour
| Input | Default | Matlab |
|-------|---------|--------|
| `InpOpenBothOnStart` | true | Flat hone par buy+sell dono seed karna. `false` = EA khud pehla trade nahi kholega, sirf existing positions manage karega (manual seeding mode) |
| `InpReopenAfterProfit` | true | Basket close hone ke baad naya level-1 order |
| `InpReopenDelaySeconds` | 3 | Re-open se pehle delay |
| `InpReopenPullbackPoints` | 0 | Re-entry se pehle itna pullback wait karna (0 = turant). Extreme pe re-entry avoid karne ke liye useful |
| `InpAllowNewCycles` | true | `false` kar dein to EA naye cycle nahi kholega, sirf existing baskets ko profit me band karega (**wind-down / safe shutdown**) |

### Filters
| Input | Default | Matlab |
|-------|---------|--------|
| `InpMaxSpreadPoints` | 60 | Isse zyada spread ho to naya order nahi (news/rollover protection) |
| `InpUseTimeFilter` | false | Trading hours filter (server time) |
| `InpStartHour` / `InpEndHour` | 1 / 23 | Window |
| `InpCloseBeforeWeekend` | false | Friday sab flatten karna |
| `InpFridayCloseHour` | 21 | Friday flatten hour |

### Protection
| Input | Default | Matlab |
|-------|---------|--------|
| `InpUseEquityStop` | true | Floating drawdown protection — **ise on rakhein** |
| `InpEquityStopPercent` | 30.0 | Floating loss balance ke is % se zyada hua to sab close |
| `InpHaltAfterEquityStop` | true | Equity stop ke baad EA rok dena (re-attach karke resume) |
| `InpSlippagePoints` | 30 | Max deviation |

---

## ⚠️ Risk — yeh zaroor padhein

Yeh ek **grid / averaging** system hai. Iska structural risk: agar market ek hi direction me bina retracement trend kare, losing basket ka drawdown badhta jaata hai. Profit chhota aur consistent hota hai, loss kabhi-kabhi bada.

Default settings ke saath calculated numbers (gold: 1 lot = 100 oz, `$1` move = `$100` per lot; base `0.01`, additive `0.01`, step `$3`):

| Levels open | Adverse move | Basket volume | Floating loss |
|---|---|---|---|
| 4 | $9 | 0.10 | −$30 |
| 8 | $21 | 0.36 | −$252 |
| 12 | $33 | 0.78 | −$858 |
| 15 (max) | $42 | 1.20 | **−$1,680** |

15 levels ke baad grid rukti hai, par loss rukta nahi — 1.20 lots pe har extra `$1` move = **−$120**. `$45` par ≈ −$2,040.

Handy formula in defaults ke liye: **floating loss ≈ n × (n² − 1) / 2 dollars**, jahan `n` = open levels.

**Equity stop kab fire hoga:** `$3,000` balance × 30% = `$900` → yeh limit level **12–13** ke aas-paas hit hoti hai, matlab full 15-level grid se pehle hi EA sab flatten kar dega. Yeh intentional protection hai. Agar aap poori 15-level grid ko survive karana chahte hain to balance `$5,600`+ chahiye (`$1,680` = 30%), ya `InpMaxPositionsPerBasket` kam karein.

Margin bhi dekhein: 1.20 lots gold @ 1:100 leverage ≈ `$3,180`. @ 1:500 ≈ `$636`.

**Suggested scaling:**

| Balance | `InpBaseLot` | `InpMaxPositionsPerBasket` | `InpGridStepPrice` | `InpEquityStopPercent` |
|---|---|---|---|---|
| $500 | 0.01 | 6 | 5.0 | 20 |
| $1,000 | 0.01 | 8 | 4.0 | 25 |
| $3,000 | 0.01 | 15 | 3.0 | 30 |
| $10,000 | 0.02–0.03 | 15 | 3.0 | 30 |

Ready presets: [`MQL5/Presets/`](MQL5/Presets/) — EA settings dialog me **Load** button se import karein.

**Testing checklist — live se pehle:**
1. Strategy Tester, XAUUSD M1, **"Every tick based on real ticks"** model, kam se kam 3–6 months data
2. High-trend periods zaroor test karein (gold ke bade directional moves)
3. Demo account pe minimum 2–4 weeks
4. Equity stop hamesha enabled

Yeh code educational/research purpose ke liye hai. Live capital pe use karne ka poora risk aapka hai — koi profit guarantee nahi hai.

---

## Wind-down (safe band karna)

EA ko beech me detach karne se open positions unmanaged reh jaati hain. Safe tareeka:

1. `InpAllowNewCycles` ko **false** karein → EA naye cycle nahi kholega
2. Existing baskets apne target pe profit me close ho jaayenge
3. Dono baskets `0 pos` dikhen (dashboard pe) → tab EA detach karein

---

## Troubleshooting

| Problem | Reason / Fix |
|---|---|
| `needs a HEDGING account` alert | Account netting hai. Broker se hedging account lein |
| `Magic numbers ... must be DIFFERENT` | `InpMagicBuy` aur `InpMagicSell` same set kar diye hain |
| Koi trade nahi khul raha | Algo Trading button green hai? Spread `InpMaxSpreadPoints` se zyada? Time filter block kar raha? |
| Grid bahut jaldi-jaldi add ho rahi | `InpGridStepPrice` badhayein, ya `InpMinSecondsBetweenAdds` badhayein |
| Basket target hit hota hai par close nahi | Experts log dekhein — `close #... failed` message me broker ka retcode milega |
| Target hit par bhi net profit kam | ECN commission. `InpCommissionPerLotRT` set karein |
| `grid step is close to the current spread` warning | Step bahut chhota hai. `InpGridStepPrice` badhayein |

Sab diagnostics MT5 ke **Toolbox → Experts** tab me print hote hain.


---

## Universal Independent Strategy EA (multi-asset)

The repository also includes `MQL5/Experts/UniversalSMCConfluenceEA.mq5` version 2.00, a separate non-grid EA for chart-symbol trading. Despite the compatibility filename, voting/confluence has been removed. SMC, FVG, order block, liquidity sweep, breakout, and trend-line engines now evaluate and trade independently.

If several strategies meet their own conditions on the same closed candle, each can place a separate ticket with its own derived magic number, risk-sized volume, structural/ATR SL, TP of at least 1:2, break-even, and ATR trailing. One strategy's position or cooldown does not block another strategy.

A **hedging account is required** because MT5 netting accounts merge same-symbol trades and cannot retain separate per-strategy SL/TP. Use `MQL5/Presets/Universal_SMC_M15_Conservative.set` as a starting point and read [`MQL5/Experts/README_UniversalSMCConfluenceEA.md`](MQL5/Experts/README_UniversalSMCConfluenceEA.md) before testing.

`InpRiskPercent` applies to every independent order, so simultaneous strategy signals add their risk. This is an algorithmic framework, not a profit guarantee. Compile in MetaEditor, then backtest and forward-test every broker/symbol configuration on demo before live deployment.
