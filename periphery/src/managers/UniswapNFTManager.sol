// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {ERC20, SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Borrower, IManager} from "aloe-ii-core/Borrower.sol";
import {Factory} from "aloe-ii-core/Factory.sol";

import {IUniswapPositionNFT} from "../interfaces/IUniswapPositionNFT.sol";

contract UniswapNFTManager is IManager {
    using SafeTransferLib for ERC20;

    Factory public immutable FACTORY;

    address public immutable BORROWER_NFT;

    IUniswapPositionNFT public immutable UNISWAP_NFT;

    mapping(address => uint256) public nonces;

    constructor(Factory factory, address borrowerNft, IUniswapPositionNFT uniswapNft) {
        FACTORY = factory;
        BORROWER_NFT = borrowerNft;
        UNISWAP_NFT = uniswapNft;
    }

    function callback(bytes calldata data, address owner, uint208) external override returns (uint208 positions) {
        // We cast `msg.sender` as a `Borrower`, but it could really be anything. DO NOT TRUST!
        Borrower borrower = Borrower(payable(msg.sender));

        // Need to check that `msg.sender` is really a borrower and that its owner is `BORROWER_NFT`
        // in order to be sure that incoming `data` is in the expected format
        require(FACTORY.isBorrower(msg.sender) && owner == BORROWER_NFT, "Aloe: bad caller");

        // Now `owner` is the true owner of the borrower
        owner = address(bytes20(data[:20]));

        // The ID of the NFT to which liquidity will be added/removed
        uint256 tokenId;
        // The position's lower tick
        int24 lower;
        // The position's upper tick
        int24 upper;
        // The change in the NFT's liquidity. Negative values move NFT-->Borrower, positives do the opposite
        int128 liquidity;
        (tokenId, lower, upper, liquidity, positions) = abi.decode(
            data[20:660],
            (uint256, int24, int24, int128, uint208)
        );

        // move position from NonfungiblePositionManager to Borrower
        if (liquidity < 0) {
            // safety checks since this contract will be approved to manage users' positions
            require(
                owner == UNISWAP_NFT.ownerOf(tokenId) &&
                    SignatureCheckerLib.isValidSignatureNowCalldata(
                        owner,
                        keccak256(
                            abi.encodePacked(
                                "\x19\x01",
                                DOMAIN_SEPARATOR(),
                                keccak256(
                                    abi.encode(
                                        keccak256(
                                            "Permit(address owner,address spender,uint128 liquidity,uint256 nonce,uint256 tokenId)"
                                        ),
                                        owner,
                                        msg.sender,
                                        uint128(-liquidity),
                                        nonces[owner]++,
                                        tokenId
                                    )
                                )
                            )
                        ),
                        data[660:]
                    )
            );

            _withdrawFromNFT(tokenId, uint128(-liquidity), msg.sender);
            borrower.uniswapDeposit(lower, upper, uint128((uint256(uint128(-liquidity)) * 999) / 1000));
        }
        // move position from Borrower to NonfungiblePositionManager (position must exist already)
        else {
            ERC20 token0 = borrower.TOKEN0();
            ERC20 token1 = borrower.TOKEN1();

            (uint256 burned0, uint256 burned1, , ) = borrower.uniswapWithdraw(
                lower,
                upper,
                uint128(liquidity),
                address(this)
            );

            token0.safeApprove(address(UNISWAP_NFT), burned0 + 1);
            token1.safeApprove(address(UNISWAP_NFT), burned1 + 1);
            UNISWAP_NFT.increaseLiquidity(
                IUniswapPositionNFT.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: burned0,
                    amount1Desired: burned1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );

            token0.safeTransfer(owner, token0.balanceOf(address(this)));
            token1.safeTransfer(owner, token1.balanceOf(address(this)));
        }
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string version,uint256 chainId,address verifyingContract)"),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    function _withdrawFromNFT(uint256 tokenId, uint128 liquidity, address recipient) private {
        UNISWAP_NFT.decreaseLiquidity(
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
