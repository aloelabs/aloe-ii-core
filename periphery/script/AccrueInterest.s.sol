// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.17;

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {LenderAccrualHelper, Lender} from "src/helpers/LenderAccrualHelper.sol";

import {KeeperScript} from "./Keeper.s.sol";

contract AccrueInterestScript is KeeperScript {
    LenderAccrualHelper constant HELPER = LenderAccrualHelper(0x49b7C197468b5E8Eb345768280B554B39Dc9F64b);

    function run() external {
        Lender[] memory lenders;

        vm.createSelectFork(vm.rpcUrl("optimism"));

        lenders = new Lender[](poolsOptimism.length * 2);
        for (uint256 i = 0; i < poolsOptimism.length; i++) {
            (Lender lender0, Lender lender1, ) = FACTORY.getMarket(poolsOptimism[i]);
            lenders[i * 2 + 0] = lender0;
            lenders[i * 2 + 1] = lender1;
        }
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        HELPER.accrueInterest(lenders);
        vm.stopBroadcast();

        vm.createSelectFork(vm.rpcUrl("arbitrum"));

        lenders = new Lender[](poolsArbitrum.length * 2);
        for (uint256 i = 0; i < poolsArbitrum.length; i++) {
            (Lender lender0, Lender lender1, ) = FACTORY.getMarket(poolsArbitrum[i]);
            lenders[i * 2 + 0] = lender0;
            lenders[i * 2 + 1] = lender1;
        }
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        HELPER.accrueInterest(lenders);
        vm.stopBroadcast();
    }
}
