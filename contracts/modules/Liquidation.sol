// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../BaseLogic.sol";


/// @notice Liquidate users who are in collateral violation to protect lenders
contract Liquidation is BaseLogic {
    constructor(bytes32 moduleGitCommit_) BaseLogic(MODULEID__LIQUIDATION, moduleGitCommit_) {}

    // How much of a liquidation is credited to the underlying's reserves.
    uint public constant UNDERLYING_RESERVES_FEE = 0.02 * 1e18;

    // Maximum discount that can be awarded under any conditions.
    uint public constant MAXIMUM_DISCOUNT = 0.20 * 1e18;

    // How much faster the booster grows for a fully funded supplier. Partially-funded suppliers
    // have this scaled proportional to their free-liquidity divided by the violator's liability.
    uint public constant DISCOUNT_BOOSTER_SLOPE = 2 * 1e18;

    // How much booster discount can be awarded beyond the base discount.
    uint public constant MAXIMUM_BOOSTER_DISCOUNT = 0.025 * 1e18;

    // Post-liquidation target health score that limits maximum liquidation sizes. Must be >= 1.
    uint public constant TARGET_HEALTH = 1.25 * 1e18;


    /// @notice Information about a prospective liquidation opportunity
    struct LiquidationOpportunity {
        uint repay;
        uint yield;
        uint healthScore;

        // Only populated if repay > 0:
        uint baseDiscount;
        uint discount;
        uint conversionRate;
    }

    struct LiquidationLocals {
        address liquidator;
        address violator;
        address underlying;
        address collateral;

        uint underlyingPrice;
        uint collateralPrice;

        LiquidationOpportunity liqOpp;

        uint repayPreFees;
    }
    //修改主要结构体的信息
    function computeLiqOpp(LiquidationLocals memory liqLocs) private {
        require(!isSubAccountOf(liqLocs.violator, liqLocs.liquidator), "e/liq/self-liquidation"); //交易发起者不能是自己的子账户
        require(isEnteredInMarket(liqLocs.violator, liqLocs.underlying), "e/liq/violator-not-entered-underlying"); //验证被清算人（违约者）是否有负债
        require(isEnteredInMarket(liqLocs.violator, liqLocs.collateral), "e/liq/violator-not-entered-collateral"); //验证被清算人（违约者）是否有抵押

        liqLocs.underlyingPrice = getAssetPrice(liqLocs.underlying); //获取被清算人借款token的价格
        liqLocs.collateralPrice = getAssetPrice(liqLocs.collateral); //获取被清算人抵押token的价格

        LiquidationOpportunity memory liqOpp = liqLocs.liqOpp; 
        //拿underlying token在euler上公开的信息
        AssetStorage storage underlyingAssetStorage = eTokenLookup[underlyingLookup[liqLocs.underlying].eTokenAddress];//拿到underlying token的etoken的信息
        AssetCache memory underlyingAssetCache = loadAssetCache(liqLocs.underlying, underlyingAssetStorage); //传两个信息，拿一个信息
        //拿collateral token在euler上公开的信息
        AssetStorage storage collateralAssetStorage = eTokenLookup[underlyingLookup[liqLocs.collateral].eTokenAddress];
        AssetCache memory collateralAssetCache = loadAssetCache(liqLocs.collateral, collateralAssetStorage);

        liqOpp.repay = liqOpp.yield = 0; //repay是清算人替被清算人还的token数量，yield是清算人收益

        (uint collateralValue, uint liabilityValue) = getAccountLiquidity(liqLocs.violator); //获得被清算人risk—adjusted的抵押价值和负债价值
        //判断被清算人负债价值是否为0
        if (liabilityValue == 0) {
            liqOpp.healthScore = type(uint).max;
            return; // no violation
        }

        liqOpp.healthScore = collateralValue * 1e18 / liabilityValue; //算healthscore，乘上1e18避免小数。
        //health socre > 1 (1e18 in solidity)
        if (collateralValue >= liabilityValue) {
            return; // no violation
        }

        // At this point healthScore must be < 1 since collateral < liability

        // Compute discount

        {
            uint baseDiscount = UNDERLYING_RESERVES_FEE + (1e18 - liqOpp.healthScore);

            uint discountBooster = computeDiscountBooster(liqLocs.liquidator, liabilityValue);

            uint discount = baseDiscount * discountBooster / 1e18;

            if (discount > (baseDiscount + MAXIMUM_BOOSTER_DISCOUNT)) discount = baseDiscount + MAXIMUM_BOOSTER_DISCOUNT;
            if (discount > MAXIMUM_DISCOUNT) discount = MAXIMUM_DISCOUNT; //不允许超过最大值

            liqOpp.baseDiscount = baseDiscount; //basediscount为什么这么算=1-health factor?
            liqOpp.discount = discount;
            liqOpp.conversionRate = liqLocs.underlyingPrice * 1e18 / liqLocs.collateralPrice * 1e18 / (1e18 - discount); //repay和yield的转换率
        }
//Let's imagine a simple example without liquidation surcharges and boosters (explained in this page below): assume a user's health factor is 0.90. This implies a liquidation discount of 10% (1 - 0.90). Hence, for taking on $100 worth of dTokens, a liquidator receives $110 worth of eTokens.


        // Determine amount to repay to bring user to target health
        //如果抵押和负债token一样，repay所有负债
        if (liqLocs.underlying == liqLocs.collateral) {
            liqOpp.repay = type(uint).max;
        } else { //如果抵押和负债token不一样
            AssetConfig memory collateralConfig = resolveAssetConfig(liqLocs.collateral);//拿两种token的一些信息
            AssetConfig memory underlyingConfig = resolveAssetConfig(liqLocs.underlying);

            uint collateralFactor = collateralConfig.collateralFactor;
            uint borrowFactor = underlyingConfig.borrowFactor;

            uint liabilityValueTarget = liabilityValue * TARGET_HEALTH / 1e18; //求出负债最大值
            // needColleteralValueToTargetHealth

            // These factors are first converted into standard 1e18-scale fractions, then adjusted according to TARGET_HEALTH and the discount:
            uint borrowAdj = borrowFactor != 0 ? TARGET_HEALTH * CONFIG_FACTOR_SCALE / borrowFactor : MAX_SANE_DEBT_AMOUNT;
            uint collateralAdj = 1e18 * uint(collateralFactor) / CONFIG_FACTOR_SCALE * 1e18 / (1e18 - liqOpp.discount); //collateralAdj越大，代表被清算人坏账金额越大
            //如果borrowAdj <= collateralAdj,代表坏账金额较多，就尽可能进行最大的清算；反之只用清算到1.25健康分数？？？
            // 1U --> colleteralAdj --> colleteralvalue  
            // 1u --> borrowAdj --> liabilityvalue
            // colleteralAdj > borrowAdj  说明该被清算账户目前是坏账，那么合约就不限制repay数量，尽量一次性清完
            if (borrowAdj <= collateralAdj) {
                liqOpp.repay = type(uint).max;
            } else {
                // liabilityValueTarget >= liabilityValue > collateralValue 
                uint maxRepayInReference = (liabilityValueTarget - collateralValue) * 1e18 / (borrowAdj - collateralAdj);//确定repay value max
                liqOpp.repay = maxRepayInReference * 1e18 / liqLocs.underlyingPrice; //确定repay number max （非坏账 抵押和负债token不一样）
                //轻微违规的话，repay就少一些，减去collateralValue，然后把金额除以价格获得repay的token数量
            }
        }

        // Limit repay to current owed
        // This can happen when there are multiple borrows and liquidating this one won't bring the violator back to solvency
        // 清算人的清算数量不能超过被清算人的负债数量，max repay固定减少到最大在负债数量
        {
            uint currentOwed = getCurrentOwed(underlyingAssetStorage, underlyingAssetCache, liqLocs.violator);
            if (liqOpp.repay > currentOwed) liqOpp.repay = currentOwed;
        }

        // Limit yield to borrower's available collateral, and reduce repay if necessary
        // This can happen when borrower has multiple collaterals and seizing all of this one won't bring the violator back to solvency
        // 先算理论上的yield，再判断理论yield值是否大于被清算人的抵押值，如果大于，则yield = collateralBalance。
        liqOpp.yield = liqOpp.repay * liqOpp.conversionRate / 1e18;

        {
            uint collateralBalance = balanceToUnderlyingAmount(collateralAssetCache, collateralAssetStorage.users[liqLocs.violator].balance);

            if (collateralBalance < liqOpp.yield) {
                liqOpp.repay = collateralBalance * 1e18 / liqOpp.conversionRate;
                liqOpp.yield = collateralBalance;
            }
        }

        // Adjust repay to account for reserves fee
        // liquidation surchanrge，也就是给清算人加上一个附加费
        liqLocs.repayPreFees = liqOpp.repay;
        liqOpp.repay = liqOpp.repay * (1e18 + UNDERLYING_RESERVES_FEE) / 1e18;
        //在liqLocs结构体中记录了符合平台规定的repay最大数量以及转换后的yield
    }


    // Returns 1e18-scale fraction > 1 representing how much faster the booster grows for this liquidator

    function computeDiscountBooster(address liquidator, uint violatorLiabilityValue) private returns (uint) {
        uint booster = getUpdatedAverageLiquidityWithDelegate(liquidator) * 1e18 / violatorLiabilityValue;
        if (booster > 1e18) booster = 1e18;

        booster = booster * (DISCOUNT_BOOSTER_SLOPE - 1e18) / 1e18;

        return booster + 1e18;
    }


    /// @notice Checks to see if a liquidation would be profitable, without actually doing anything
    /// @param liquidator Address that will initiate the liquidation
    /// @param violator Address that may be in collateral violation
    /// @param underlying Token that is to be repayed
    /// @param collateral Token that is to be seized
    /// @return liqOpp The details about the liquidation opportunity
    function checkLiquidation(address liquidator, address violator, address underlying, address collateral) external nonReentrant returns (LiquidationOpportunity memory liqOpp) {
        LiquidationLocals memory liqLocs;

        liqLocs.liquidator = liquidator;
        liqLocs.violator = violator;
        liqLocs.underlying = underlying;
        liqLocs.collateral = collateral;

        computeLiqOpp(liqLocs);

        return liqLocs.liqOpp;
    }


    /// @notice Attempts to perform a liquidation
    /// @param violator Address that may be in collateral violation
    /// @param underlying Token that is to be repayed
    /// @param collateral Token that is to be seized
    /// @param repay The amount of underlying DTokens to be transferred from violator to sender, in units of underlying
    /// @param minYield The minimum acceptable amount of collateral ETokens to be transferred from violator to sender, in units of collateral
    function liquidate(address violator, address underlying, address collateral, uint repay, uint minYield) external nonReentrant {
        require(accountLookup[violator].deferLiquidityStatus == DEFERLIQUIDITY__NONE, "e/liq/violator-liquidity-deferred");//检验没有被清算

        address liquidator = unpackTrailingParamMsgSender();//拿到清算人账户地址

        emit RequestLiquidate(liquidator, violator, underlying, collateral, repay, minYield); //触发事件

        updateAverageLiquidity(liquidator);  //更新账户和平台交互的时间
        updateAverageLiquidity(violator); //更新账户和平台交互的时间


        LiquidationLocals memory liqLocs;

        liqLocs.liquidator = liquidator;
        liqLocs.violator = violator;
        liqLocs.underlying = underlying;
        liqLocs.collateral = collateral;

        computeLiqOpp(liqLocs);


        executeLiquidation(liqLocs, repay, minYield);
    }

    function executeLiquidation(LiquidationLocals memory liqLocs, uint desiredRepay, uint minYield) private {
        require(desiredRepay <= liqLocs.liqOpp.repay, "e/liq/excessive-repay-amount");//如果desire的值大于函数算出来的规定的最大repay值（desire是想要的具体的repay数量），那么交易失败


        uint repay; //先创建一个新repay，基于一些新的条件再计算最后决定的repay数量（之前是算符合规定的最大repay）

        {
            AssetStorage storage underlyingAssetStorage = eTokenLookup[underlyingLookup[liqLocs.underlying].eTokenAddress];
            AssetCache memory underlyingAssetCache = loadAssetCache(liqLocs.underlying, underlyingAssetStorage);

            //
            if (desiredRepay == liqLocs.liqOpp.repay) repay = liqLocs.repayPreFees;
            else repay = desiredRepay * (1e18 * 1e18 / (1e18 + UNDERLYING_RESERVES_FEE)) / 1e18;//repay是desiredrepay去掉reserve之后的数量

            {
                uint repayExtra = desiredRepay - repay; 
                //拿到dtonken的数量
                // Liquidator takes on violator's debt:
                //转移dtoken
                transferBorrow(underlyingAssetStorage, underlyingAssetCache, underlyingAssetStorage.dTokenAddress, liqLocs.violator, liqLocs.liquidator, repay);

                // Extra debt is minted and assigned to liquidator:

                increaseBorrow(underlyingAssetStorage, underlyingAssetCache, underlyingAssetStorage.dTokenAddress, liqLocs.liquidator, repayExtra);

                // The underlying's reserve is credited to compensate for this extra debt:

                {
                    uint poolAssets = underlyingAssetCache.poolSize + (underlyingAssetCache.totalBorrows / INTERNAL_DEBT_PRECISION);
                    uint newTotalBalances = poolAssets * underlyingAssetCache.totalBalances / (poolAssets - repayExtra);
                    increaseReserves(underlyingAssetStorage, underlyingAssetCache, newTotalBalances - underlyingAssetCache.totalBalances);
                }
            }

            logAssetStatus(underlyingAssetCache); //emit event触发事件log
        }


        uint yield; //基于一些条件计算yield

        {
            AssetStorage storage collateralAssetStorage = eTokenLookup[underlyingLookup[liqLocs.collateral].eTokenAddress];
            AssetCache memory collateralAssetCache = loadAssetCache(liqLocs.collateral, collateralAssetStorage);

            yield = repay * liqLocs.liqOpp.conversionRate / 1e18;
            require(yield >= minYield, "e/liq/min-yield");

            // Liquidator gets violator's collateral:

            address eTokenAddress = underlyingLookup[collateralAssetCache.underlying].eTokenAddress;
            //转移etoken
            transferBalance(collateralAssetStorage, collateralAssetCache, eTokenAddress, liqLocs.violator, liqLocs.liquidator, underlyingAmountToBalance(collateralAssetCache, yield));

            logAssetStatus(collateralAssetCache);//emit event触发事件log
        }


        // Since liquidator is taking on new debt, liquidity must be checked:

        checkLiquidity(liqLocs.liquidator); //检查清算人的账户是否健康

        emitLiquidationLog(liqLocs, repay, yield);
    }

    function emitLiquidationLog(LiquidationLocals memory liqLocs, uint repay, uint yield) private {
        emit Liquidation(liqLocs.liquidator, liqLocs.violator, liqLocs.underlying, liqLocs.collateral, repay, yield, liqLocs.liqOpp.healthScore, liqLocs.liqOpp.baseDiscount, liqLocs.liqOpp.discount);
    }
}
