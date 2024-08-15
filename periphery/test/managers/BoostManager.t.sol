// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {Borrower, IManager} from "aloe-ii-core/Borrower.sol";
import {Factory, BorrowerDeployer} from "aloe-ii-core/Factory.sol";
import {Lender} from "aloe-ii-core/Lender.sol";
import {RateModel} from "aloe-ii-core/RateModel.sol";
import {VolatilityOracle} from "aloe-ii-core/VolatilityOracle.sol";

import {BorrowerNFT, IBorrowerURISource} from "src/borrower-nft/BorrowerNFT.sol";
import {BoostManager, IUniswapPositionNFT} from "src/managers/BoostManager.sol";

contract BoostManagerTest is Test {
    event CreateBorrower(IUniswapV3Pool indexed pool, address indexed owner, Borrower account);

    IUniswapV3Pool POOL = IUniswapV3Pool(0x68F5C0A2DE713a54991E01858Fd27a3832401849);

    IUniswapPositionNFT UNISWAP_NFT = IUniswapPositionNFT(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    BorrowerNFT borrowerNft;

    BoostManager boostManager;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("optimism"));
        vm.rollFork(111336182);

        RateModel rateModel = new RateModel();
        VolatilityOracle oracle = new VolatilityOracle();
        BorrowerDeployer deployer = new BorrowerDeployer();
        Factory factory = new Factory(address(0), address(0), oracle, deployer, rateModel);
        factory.createMarket(POOL);

        borrowerNft = new BorrowerNFT(factory, IBorrowerURISource(address(0)));
        boostManager = new BoostManager(factory, address(borrowerNft), UNISWAP_NFT);

        (Lender lender0, Lender lender1, ) = factory.getMarket(POOL);
        deal(address(POOL.token0()), address(lender0), 1e18);
        deal(address(POOL.token1()), address(lender1), 1e18);
        lender0.deposit(1e18, address(0));
        lender1.deposit(1e18, address(0));
    }

    // function test_mint() public {
    //     address owner = 0xde8E7d3fFada10dE2A57E7bAc090dB06596F51Cd;

    //     bytes memory mintCall;
    //     {
    //         IUniswapV3Pool[] memory pools = new IUniswapV3Pool[](1);
    //         bytes12[] memory salts = new bytes12[](1);
    //         pools[0] = POOL;
    //         salts[0] = bytes12(uint96(0));
    //         mintCall = abi.encodeCall(borrowerNft.mint, (owner, pools, salts));
    //     }

    //     bytes memory modifyCall;
    //     {
    //         uint16[] memory indices = new uint16[](1);
    //         IManager[] memory managers = new IManager[](1);
    //         bytes[] memory datas = new bytes[](1);
    //         uint16[] memory antes = new uint16[](1);
    //         indices[0] = 0;
    //         managers[0] = boostManager;
    //         datas[0] = abi.encode(
    //             uint8(0),
    //             abi.encode(
    //                 uint256(425835),
    //                 int24(70020),
    //                 int24(71700),
    //                 uint128(344339104909795631),
    //                 10_000,
    //                 uint224(type(uint224).max)
    //             )
    //         );
    //         antes[0] = 0.01 ether / 1e13;
    //         modifyCall = abi.encodeCall(borrowerNft.modify, (owner, indices, managers, datas, antes));
    //     }

    //     vm.prank(owner);
    //     UNISWAP_NFT.approve(address(boostManager), 425835);

    //     vm.prank(owner);
    //     bytes[] memory data = new bytes[](2);
    //     data[0] = mintCall;
    //     data[1] = modifyCall;
    //     borrowerNft.multicall{value: 0.01 ether}(data);
    // }
}
