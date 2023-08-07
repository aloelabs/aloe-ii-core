// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.17;

import "forge-std/Script.sol";

import {Factory} from "aloe-ii-core/Factory.sol";

import {BorrowerLens} from "src/BorrowerLens.sol";
import {LenderLens} from "src/LenderLens.sol";
import {Router, IPermit2} from "src/Router.sol";
import {LenderAccrualHelper} from "src/helpers/LenderAccrualHelper.sol";
import {OracleUpdateHelper} from "src/helpers/OracleUpdateHelper.sol";
import {FrontendManager} from "src/managers/FrontendManager.sol";
import {SimpleManager} from "src/managers/SimpleManager.sol";
import {UniswapNFTManager, INFTManager} from "src/managers/UniswapNFTManager.sol";
import {WithdrawManager} from "src/managers/WithdrawManager.sol";

bytes32 constant TAG = bytes32(uint256(0xA10EBE1A2));

contract DeployScript is Script {
    string[] chains = ["optimism", "arbitrum", "base"];

    Factory[] factories = [
        Factory(0x95110C9806833d3D3C250112fac73c5A6f631E80),
        Factory(0x95110C9806833d3D3C250112fac73c5A6f631E80),
        Factory(0xA56eA45565478Fcd131AEccaB2FE934F23BAD8dc)
    ];

    INFTManager[] uniswapNfts = [
        INFTManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88),
        INFTManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88),
        INFTManager(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1)
    ];

    IPermit2[] permit2s = [
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3),
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3),
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3)
    ];

    function run() external {
        for (uint256 i = 0; i < chains.length; i++) {
            Factory factory = factories[i];
            INFTManager uniswapNft = uniswapNfts[i];
            IPermit2 permit2 = permit2s[i];

            vm.createSelectFork(vm.rpcUrl(chains[i]));
            vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

            new BorrowerLens{salt: TAG}();
            new LenderLens{salt: TAG}();
            new Router{salt: TAG}(permit2);

            new LenderAccrualHelper{salt: TAG}();
            new OracleUpdateHelper{salt: TAG}(factory.ORACLE());

            new FrontendManager{salt: TAG}(factory);
            new SimpleManager{salt: TAG}();
            new UniswapNFTManager{salt: TAG}(factory, uniswapNft);
            new WithdrawManager{salt: TAG}();

            vm.stopBroadcast();
        }
    }
}
