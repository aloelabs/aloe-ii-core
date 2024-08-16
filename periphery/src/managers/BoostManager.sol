// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {ERC20, SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IUniswapV3SwapCallback} from "v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import {LiquidityAmounts} from "aloe-ii-core/libraries/LiquidityAmounts.sol";
import {zip} from "aloe-ii-core/libraries/Positions.sol";
import {TickMath} from "aloe-ii-core/libraries/TickMath.sol";
import {Borrower, IManager} from "aloe-ii-core/Borrower.sol";
import {Factory} from "aloe-ii-core/Factory.sol";
import {Lender} from "aloe-ii-core/Lender.sol";

import {IUniswapPositionNFT} from "../interfaces/IUniswapPositionNFT.sol";

contract BoostManager is IManager, IUniswapV3SwapCallback {
    using SafeTransferLib for ERC20;

    Factory public immutable FACTORY;

    address public immutable BORROWER_NFT;

    IUniswapPositionNFT public immutable UNISWAP_NFT;

    constructor(Factory factory, address borrowerNft, IUniswapPositionNFT uniswapNft) {
        FACTORY = factory;
        BORROWER_NFT = borrowerNft;
        UNISWAP_NFT = uniswapNft;
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata data) external {
        Borrower borrower = abi.decode(data, (Borrower));
        borrower.transfer(amount0 > 0 ? uint256(amount0) : 0, amount1 > 0 ? uint256(amount1) : 0, msg.sender);
    }

    function callback(bytes calldata data, address owner, uint208 positions) external override returns (uint208) {
        // We cast `msg.sender` as a `Borrower`, but it could really be anything. DO NOT TRUST!
        Borrower borrower = Borrower(payable(msg.sender));

        // Need to check that `msg.sender` is really a borrower and that its owner is `BORROWER_NFT`
        // in order to be sure that incoming `data` is in the expected format
        require(FACTORY.isBorrower(msg.sender) && owner == BORROWER_NFT, "Aloe: bad caller");

        // Now `owner` is the true owner of the borrower
        owner = address(bytes20(data[:20]));
        // Decode remaining data
        (uint8 action, bytes memory args) = abi.decode(data[20:], (uint8, bytes));

        // Add liquidity (import funds from Uniswap NFT and borrow enough for specified boost factor)
        if (action == 0) {
            return _action0Mint(borrower, owner, args);
        }

        // Collect earned fees
        if (action == 1) {
            borrower.uniswapWithdraw(int24(uint24(positions)), int24(uint24(positions >> 24)), 0, owner);
        }

        // Burn liquidity
        if (action == 2) {
            return _action2Burn(borrower, owner, args, positions);
        }

        return 0;
    }

    function _action0Mint(Borrower borrower, address owner, bytes memory args) private returns (uint208) {
        // The ID of the Uniswap NFT to import
        uint256 tokenId;
        // The position's lower tick
        int24 lower;
        // The position's upper tick
        int24 upper;
        // Amount of liquidity in the position
        uint128 liquidity;
        // Leverage factor
        uint24 boost;
        // Packed maxBorrow0 and maxBorrow1; slippage protection
        uint224 maxBorrows;
        // signature
        bytes memory signature;
        (tokenId, lower, upper, liquidity, boost, maxBorrows, signature) = abi.decode(
            args,
            (uint256, int24, int24, uint128, uint24, uint224, bytes)
        );

        require(
            owner == UNISWAP_NFT.ownerOf(tokenId) &&
                SignatureCheckerLib.isValidSignatureNow(
                    owner,
                    keccak256(abi.encode(borrower, tokenId, liquidity)),
                    signature
                )
        );

        unchecked {
            (uint256 amount0, uint256 amount1) = _withdrawFromUniswapNFT(tokenId, liquidity, msg.sender);

            liquidity = uint128((uint256(liquidity) * boost) / 10_000);
            {
                (uint160 sqrtPriceX96, , , , , , ) = borrower.UNISWAP_POOL().slot0();
                (uint256 needs0, uint256 needs1) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(lower),
                    TickMath.getSqrtRatioAtTick(upper),
                    liquidity
                );
                amount0 = needs0 > 0 && needs0 > amount0 ? (needs0 + 1 - amount0) : 0;
                amount1 = needs1 > 0 && needs1 > amount1 ? (needs1 + 1 - amount1) : 0;
            }

            require(amount0 < uint112(maxBorrows) && amount1 < (maxBorrows >> 112), "slippage");
            borrower.borrow(amount0, amount1, msg.sender);
            borrower.uniswapDeposit(lower, upper, liquidity);
        }

        return zip([lower, upper, 0, 0, 0, 0]);
    }

    function _action2Burn(
        Borrower borrower,
        address owner,
        bytes memory args,
        uint208 positions
    ) private returns (uint208) {
        // The position's lower tick
        int24 lower = int24(uint24(positions));
        // The position's upper tick
        int24 upper = int24(uint24(positions >> 24));
        // Amount of liquidity in the position
        uint128 liquidity;
        // Maximum amount of token0 or token1 to swap in order to repay debts
        uint128 maxSpend;
        // Whether to swap token0 for token1 or vice versa
        bool zeroForOne;

        (maxSpend, zeroForOne) = abi.decode(args, (uint128, bool));
        (liquidity, , , , ) = borrower.UNISWAP_POOL().positions(keccak256(abi.encodePacked(msg.sender, lower, upper)));

        // Burn liquidity and collect fees
        if (liquidity > 0) borrower.uniswapWithdraw(lower, upper, liquidity, msg.sender);

        // Collect metadata from `borrower`
        Lender lender0 = borrower.LENDER0();
        Lender lender1 = borrower.LENDER1();
        ERC20 token0 = borrower.TOKEN0();
        ERC20 token1 = borrower.TOKEN1();

        // Balance sheet computations
        lender0.accrueInterest();
        lender1.accrueInterest();
        uint256 liabilities0 = lender0.borrowBalanceStored(msg.sender);
        uint256 liabilities1 = lender1.borrowBalanceStored(msg.sender);
        uint256 assets0 = token0.balanceOf(msg.sender);
        uint256 assets1 = token1.balanceOf(msg.sender);
        int256 surplus0 = int256(assets0) - int256(liabilities0);
        int256 surplus1 = int256(assets1) - int256(liabilities1);

        // Swap iff (it's necessary) AND (direction matches user's intent)
        if (surplus0 < 0 && !zeroForOne) {
            (, int256 spent1) = borrower.UNISWAP_POOL().swap({
                recipient: msg.sender,
                zeroForOne: false,
                amountSpecified: surplus0, // negative implies "exact amount out"
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1,
                data: abi.encode(borrower, token0, token1)
            });
            require(uint256(spent1) <= maxSpend, "slippage");
            assets0 = liabilities0;
            assets1 -= uint256(spent1);
        } else if (surplus1 < 0 && zeroForOne) {
            (int256 spent0, ) = borrower.UNISWAP_POOL().swap({
                recipient: msg.sender,
                zeroForOne: true,
                amountSpecified: surplus1, // negative implies "exact amount out"
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1,
                data: abi.encode(borrower, token0, token1)
            });
            require(uint256(spent0) <= maxSpend, "slippage");
            assets0 -= uint256(spent0);
            assets1 = liabilities1;
        }

        // Repay
        borrower.repay(liabilities0, liabilities1);

        unchecked {
            borrower.transfer(assets0 - liabilities0, assets1 - liabilities1, owner);
            borrower.transferEth(address(borrower).balance, payable(owner));
        }

        return zip([int24(1), 1, 0, 0, 0, 0]);
    }

    function _withdrawFromUniswapNFT(
        uint256 tokenId,
        uint128 liquidity,
        address recipient
    ) private returns (uint256 burned0, uint256 burned1) {
        (burned0, burned1) = UNISWAP_NFT.decreaseLiquidity(
            IUniswapPositionNFT.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        UNISWAP_NFT.collect(
            IUniswapPositionNFT.CollectParams({
                tokenId: tokenId,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }
}
