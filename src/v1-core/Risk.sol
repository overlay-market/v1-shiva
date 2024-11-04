// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

library Risk {
    enum Parameters {
        K, // funding constant
        Lmbda, // market impact constant
        Delta, // bid-ask static spread constant
        CapPayoff, // payoff cap
        CapNotional, // initial notional cap
        CapLeverage, // initial leverage cap
        CircuitBreakerWindow, // trailing window for circuit breaker
        CircuitBreakerMintTarget, // target worst case inflation rate over trailing window
        MaintenanceMarginFraction, // maintenance margin (mm) constant
        MaintenanceMarginBurnRate, // burn rate for mm constant
        LiquidationFeeRate, // liquidation fee charged on liquidate
        TradingFeeRate, // trading fee charged on build/unwind
        MinCollateral, // minimum ov collateral to open position
        PriceDriftUpperLimit, // upper limit for feed price changes since last update
        AverageBlockTime // average block time of the respective chain

    }
}
