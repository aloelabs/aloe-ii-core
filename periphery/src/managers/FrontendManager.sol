// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import {ERC20, SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IUniswapV3SwapCallback} from "v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import {TickMath} from "aloe-ii-core/libraries/TickMath.sol";

import {Borrower, IManager} from "aloe-ii-core/Borrower.sol";
import {Factory} from "aloe-ii-core/Factory.sol";

contract FrontendManager is IManager, IUniswapV3SwapCallback {
    using SafeTransferLib for ERC20;

    event Modify(address indexed borrower, int24 tick);

    Factory public immutable FACTORY;

    constructor(Factory factory) {
        FACTORY = factory;
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata data) external {
        Borrower borrower = abi.decode(data, (Borrower));
        borrower.transfer(amount0 > 0 ? uint256(amount0) : 0, amount1 > 0 ? uint256(amount1) : 0, msg.sender);
    }

    /* solhint-disable code-complexity */

    function callback(bytes calldata data, address owner, uint208) external returns (uint208 positions) {
        // We cast `msg.sender` as a `Borrower`, but it could really be anything. DO NOT TRUST!
        Borrower account = Borrower(payable(msg.sender));

        // Decoding `data` can't hurt
        uint8[] memory actions;
        bytes[] memory args;
        (actions, args, positions) = abi.decode(data, (uint8[], bytes[], uint144));

        // Keep track of this so we don't have to read it from `FACTORY` twice
        bool isBorrower;

        for (uint256 i; i < actions.length; i++) {
            uint8 action = actions[i];

            // transfer in
            if (action == 0) {
                (address asset, uint256 amount) = abi.decode(args[i], (address, uint256));

                // NOTE: Users will be approving this contract, so before making *any* call to `transferFrom`,
                // we must ensure that `msg.sender` should be allowed to take `owner`'s funds. If `msg.sender`
                // *is not* a `Borrower`, `owner` could be anything -- so revert. But if `msg.sender` *is* a
                // `Borrower`, then we know that `owner` has explicitly called `modify` and handed execution
                // flow to this contract (there's no other way for `Borrower` to have called this).
                if (!isBorrower) {
                    isBorrower = FACTORY.isBorrower(msg.sender);
                    require(isBorrower);
                }

                ERC20(asset).safeTransferFrom(owner, msg.sender, amount);
                continue;
            }

            // transfer out
            if (action == 1) {
                (uint256 amount0, uint256 amount1) = abi.decode(args[i], (uint256, uint256));
                account.transfer(amount0, amount1, owner);
                continue;
            }

            // borrow
            if (action == 2) {
                (uint256 amount0, uint256 amount1) = abi.decode(args[i], (uint256, uint256));
                account.borrow(amount0, amount1, msg.sender);
                continue;
            }

            // repay
            if (action == 3) {
                (uint256 amount0, uint256 amount1) = abi.decode(args[i], (uint256, uint256));
                account.repay(amount0, amount1);
                continue;
            }

            // add liquidity
            if (action == 4) {
                (int24 lower, int24 upper, uint128 liquidity) = abi.decode(args[i], (int24, int24, uint128));
                account.uniswapDeposit(lower, upper, liquidity);
                continue;
            }

            // remove liquidity
            if (action == 5) {
                (int24 lower, int24 upper, uint128 liquidity) = abi.decode(args[i], (int24, int24, uint128));
                account.uniswapWithdraw(lower, upper, liquidity, msg.sender);
                continue;
            }

            // swap
            if (action == 6) {
                (int256 amount0, int256 amount1, uint32 deadline) = abi.decode(args[i], (int256, int256, uint32));
                require(block.timestamp < deadline, "deadline");

                int256 amountIn;
                int256 amountOut;
                uint160 sqrtPriceLimitX96;

                bool zeroForOne = amount0 < 0;
                if (zeroForOne) {
                    // make sure `amountIn` is positive so that we're doing "exact amount in"
                    amountIn = -amount0;
                    amountOut = amount1;
                    sqrtPriceLimitX96 = TickMath.MIN_SQRT_RATIO + 1;
                } else {
                    // make sure `amountIn` is positive so that we're doing "exact amount in"
                    amountIn = -amount1;
                    amountOut = amount0;
                    sqrtPriceLimitX96 = TickMath.MAX_SQRT_RATIO - 1;
                }

                (int256 received0, int256 received1) = account.UNISWAP_POOL().swap({
                    recipient: msg.sender,
                    zeroForOne: zeroForOne,
                    amountSpecified: amountIn,
                    sqrtPriceLimitX96: sqrtPriceLimitX96,
                    data: abi.encode(account)
                });

                if (zeroForOne) require(-received1 >= amountOut, "slippage");
                else require(-received0 >= amountOut, "slippage");
            }
        }

        (, int24 currentTick, , , , , ) = account.UNISWAP_POOL().slot0();
        emit Modify(msg.sender, currentTick);
    }

    /* solhint-enable code-complexity */
}
