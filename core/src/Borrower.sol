// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20, SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IUniswapV3MintCallback} from "v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {LiquidationEngine, Assets, Prices} from "./libraries/BalanceSheet.sol";
import {FixedPoint96} from "./libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {Oracle} from "./libraries/Oracle.sol";
import {Positions} from "./libraries/Positions.sol";
import {TickMath} from "./libraries/TickMath.sol";

import {Lender} from "./Lender.sol";

interface ILiquidator {
    function callback0(
        bytes calldata data,
        uint256 assets1,
        uint256 liabilities0
    ) external returns (uint256 converted0);

    function callback1(
        bytes calldata data,
        uint256 assets0,
        uint256 liabilities1
    ) external returns (uint256 converted1);
}

interface IManager {
    function callback(bytes calldata data) external returns (uint144 positions);
}

contract Borrower is IUniswapV3MintCallback {
    using SafeTransferLib for ERC20;
    using Positions for int24[6];

    uint8 public constant B = 3; // TODO: To make this governable, move it into packedSlot

    uint256 public constant ANTE = 0.001 ether; // TODO: To make this governable, move it into packedSlot

    /// @notice The Uniswap pair in which the vault will manage positions
    IUniswapV3Pool public immutable UNISWAP_POOL;

    /// @notice The first token of the Uniswap pair
    ERC20 public immutable TOKEN0;

    /// @notice The second token of the Uniswap pair
    ERC20 public immutable TOKEN1;

    /// @notice The lender for `TOKEN0`
    Lender public immutable LENDER0;

    /// @notice The lender for `TOKEN1`
    Lender public immutable LENDER1;

    struct PackedSlot {
        address owner;
        bool isInCallback;
    }

    PackedSlot public packedSlot;

    int24[6] public positions;

    constructor(IUniswapV3Pool pool, Lender lender0, Lender lender1) {
        UNISWAP_POOL = pool;
        LENDER0 = lender0;
        LENDER1 = lender1;

        TOKEN0 = lender0.asset();
        TOKEN1 = lender1.asset();

        require(pool.token0() == address(TOKEN0));
        require(pool.token1() == address(TOKEN1));
    }

    function initialize(address owner) external {
        require(packedSlot.owner == address(0));
        packedSlot.owner = owner;
    }

    // TODO: add feature -- ability to withdraw ante if liabilities==0
    // TODO: add feature -- ability to set new owner

    function liquidate(ILiquidator callee, bytes calldata data) external {
        require(!packedSlot.isInCallback);

        Prices memory prices = _getPrices();
        (uint256 liabilities0, uint256 liabilities1) = getLiabilities();

        require(
            !LiquidationEngine.isSolvent(liabilities0, liabilities1, _getAssets(positions.read(), prices, true), prices)
        );

        uint256 assets0 = TOKEN0.balanceOf(address(this));
        uint256 repayable0 = Math.min(assets0, liabilities0);
        liabilities0 -= repayable0;

        uint256 assets1 = TOKEN1.balanceOf(address(this));
        uint256 repayable1 = Math.min(assets1, liabilities1);
        liabilities1 -= repayable1;

        // TODO: this is already computed inside of computeLiquidationIncentive, so use that instead of
        // re-computing it (or at least compare gas between the 2 options)
        uint256 priceX96 = Math.mulDiv(prices.c, prices.c, FixedPoint96.Q96);

        // If both are zero or neither is zero, there's nothing more to do
        if (liabilities0 + liabilities1 == 0 || liabilities0 * liabilities1 > 0) {
            payable(msg.sender).transfer(ANTE);
            return;
        } else if (liabilities0 > 0) {
            TOKEN1.safeApprove(address(callee), type(uint256).max);
            uint256 converted0 = callee.callback0(data, assets1 - repayable1, liabilities0);
            TOKEN1.safeApprove(address(callee), 0);

            uint256 maxLoss1 = Math.mulDiv(converted0 * 105, priceX96, 100 * FixedPoint96.Q96);
            require(assets1 - TOKEN1.balanceOf(address(this)) <= maxLoss1);

            // TODO is scaling the best incentive, or would it be better to use thresholding?
            payable(msg.sender).transfer((ANTE * converted0) / liabilities0);

            repayable0 += converted0;
        } else {
            TOKEN0.safeApprove(address(callee), type(uint256).max);
            uint256 converted1 = callee.callback1(data, assets0 - repayable0, liabilities1);
            TOKEN1.safeApprove(address(callee), 0);

            uint256 maxLoss0 = Math.mulDiv(converted1 * 105, FixedPoint96.Q96, 100 * priceX96);
            require(assets0 - TOKEN0.balanceOf(address(this)) <= maxLoss0);

            // TODO is scaling the best incentive, or would it be better to use thresholding?
            payable(msg.sender).transfer((ANTE * converted1) / liabilities1);

            repayable1 += converted1;
        }

        _repay(repayable0, repayable1);
    }

    function modify(IManager callee, bytes calldata data, bool[2] calldata allowances) external payable {
        require(msg.sender == packedSlot.owner, "Aloe: only owner");
        require(!packedSlot.isInCallback);

        if (allowances[0]) TOKEN0.safeApprove(address(callee), type(uint256).max);
        if (allowances[1]) TOKEN1.safeApprove(address(callee), type(uint256).max);

        packedSlot.isInCallback = true;
        // Write new Uniswap positions to storage iff they're properly formatted and unique.
        // We rely on `_isSolvent` to ensure `_positions.length % 2 == 0` and that each
        // position obeys Uniswap's expectations for ticks, e.g. tickLower < tickUpper
        int24[] memory positions_ = positions.write(callee.callback(data));
        packedSlot.isInCallback = false;

        if (allowances[0]) TOKEN0.safeApprove(address(callee), 1);
        if (allowances[1]) TOKEN1.safeApprove(address(callee), 1);

        Prices memory prices = _getPrices();
        (uint256 liabilities0, uint256 liabilities1) = getLiabilities();

        require(
            LiquidationEngine.isSolvent(liabilities0, liabilities1, _getAssets(positions_, prices, false), prices),
            "Aloe: need more margin"
        );

        if (liabilities0 + liabilities1 > 0) require(address(this).balance > ANTE, "Aloe: missing ante");
    }

    function borrow(uint256 amount0, uint256 amount1, address recipient) external {
        require(packedSlot.isInCallback);

        if (amount0 > 0) LENDER0.borrow(amount0, recipient);
        if (amount1 > 0) LENDER1.borrow(amount1, recipient);
    }

    // Technically uneccessary. but:
    // --> Keep because it allows us to use transfer instead of transferFrom, saving allowance reads in the underlying asset contracts
    // --> Keep for integrator convenience
    // --> Keep because it allows integrators to repay debts without configuring the `allowances` bool array
    function repay(uint256 amount0, uint256 amount1) external {
        require(packedSlot.isInCallback);
        _repay(amount0, amount1);
    }

    function _repay(uint256 amount0, uint256 amount1) private {
        if (amount0 > 0) {
            TOKEN0.safeTransfer(address(LENDER0), amount0);
            LENDER0.repay(amount0, address(this));
        }
        if (amount1 > 0) {
            TOKEN1.safeTransfer(address(LENDER1), amount1);
            LENDER1.repay(amount1, address(this));
        }
    }

    function uniswapDeposit(
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) external returns (uint256 amount0, uint256 amount1) {
        require(packedSlot.isInCallback);

        (amount0, amount1) = UNISWAP_POOL.mint(address(this), lower, upper, liquidity, "");
    }

    function uniswapWithdraw(
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) external returns (uint256 burned0, uint256 burned1, uint256 collected0, uint256 collected1) {
        require(packedSlot.isInCallback);

        (burned0, burned1) = UNISWAP_POOL.burn(lower, upper, liquidity);

        // Collect all owed tokens including earned fees
        (collected0, collected1) = UNISWAP_POOL.collect(
            address(this),
            lower,
            upper,
            type(uint128).max,
            type(uint128).max
        );
    }

    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(UNISWAP_POOL));
        if (amount0 > 0) TOKEN0.safeTransfer(msg.sender, amount0);
        if (amount1 > 0) TOKEN1.safeTransfer(msg.sender, amount1);
    }

    function _getAssets(
        int24[] memory positions_,
        Prices memory prices,
        bool withdraw
    ) private returns (Assets memory assets) {
        assets.fixed0 = TOKEN0.balanceOf(address(this));
        assets.fixed1 = TOKEN1.balanceOf(address(this));

        uint256 count = positions_.length;
        unchecked {
            for (uint256 i; i < count; i += 2) {
                uint160 L;
                uint160 U;
                uint128 liquidity;

                {
                    // Load lower and upper ticks from the `positions_` array
                    int24 l = positions_[i];
                    int24 u = positions_[i + 1];
                    // Fetch amount of `liquidity` in the position
                    (liquidity, , , , ) = UNISWAP_POOL.positions(keccak256(abi.encodePacked(address(this), l, u)));

                    // Compute lower and upper sqrt ratios
                    L = TickMath.getSqrtRatioAtTick(l);
                    U = TickMath.getSqrtRatioAtTick(u);

                    // TODO what happens if we attempt to withdraw a position that doesn't exist?
                    if (withdraw) {
                        // Withdraw all `liquidity` from the position, adding earned fees as fixed assets
                        (uint256 burned0, uint256 burned1) = UNISWAP_POOL.burn(l, u, liquidity);
                        (uint256 collected0, uint256 collected1) = UNISWAP_POOL.collect(
                            address(this),
                            l,
                            u,
                            type(uint128).max,
                            type(uint128).max
                        );
                        assets.fixed0 += collected0 - burned0;
                        assets.fixed1 += collected1 - burned1;
                    }
                }

                // Compute the value of `liquidity` (in terms of token1) at both probe prices
                assets.fluid1A += LiquidityAmounts.getValueOfLiquidity(prices.a, L, U, liquidity);
                assets.fluid1B += LiquidityAmounts.getValueOfLiquidity(prices.b, L, U, liquidity);

                // Compute what amounts underlie `liquidity` at the current TWAP
                (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(prices.c, L, U, liquidity);
                assets.fluid0C += amount0;
                assets.fluid1C += amount1;
            }
        }
    }

    // ⬇️⬇️⬇️⬇️ VIEW FUNCTIONS ⬇️⬇️⬇️⬇️  ------------------------------------------------------------------------------

    function getUniswapPositions() public view returns (int24[] memory) {
        return positions.read();
    }

    function _getPrices() private view returns (Prices memory prices) {
        (int24 arithmeticMeanTick, ) = Oracle.consult(UNISWAP_POOL, 1200);
        uint256 sigma = 0.025e18; // TODO fetch real data from the volatility oracle

        // compute prices at which solvency will be checked
        uint160 sqrtMeanPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        (uint160 a, uint160 b) = LiquidationEngine.computeProbePrices(sqrtMeanPriceX96, sigma, B);
        prices = Prices(a, b, sqrtMeanPriceX96);
    }

    function getLiabilities() public view returns (uint256 amount0, uint256 amount1) {
        amount0 = LENDER0.borrowBalanceStored(address(this));
        amount1 = LENDER1.borrowBalanceStored(address(this));
    }
}
