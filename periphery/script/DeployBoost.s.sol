// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.17;

import "forge-std/Script.sol";

import {Factory} from "aloe-ii-core/Factory.sol";

import {BoostNFT} from "src/boost/BoostNFT.sol";
import {INonfungiblePositionManager as IUniswapNFT} from "src/interfaces/INonfungiblePositionManager.sol";
import {BoostManager} from "src/managers/BoostManager.sol";

bytes32 constant TAG = bytes32(uint256(0xA10EBE1AB0051));
address constant OWNER = 0xC3feD7757CD3eb12b155F230Fa057396e9D78EAa;

contract DeployBoostScript is Script {
    string[] chains = ["optimism", "arbitrum", "base"];

    Factory[] factories = [
        Factory(0x95110C9806833d3D3C250112fac73c5A6f631E80),
        Factory(0x95110C9806833d3D3C250112fac73c5A6f631E80),
        Factory(0xA56eA45565478Fcd131AEccaB2FE934F23BAD8dc)
    ];

    IUniswapNFT[] uniswapNfts = [
        IUniswapNFT(0xC36442b4a4522E871399CD717aBDD847Ab11FE88),
        IUniswapNFT(0xC36442b4a4522E871399CD717aBDD847Ab11FE88),
        IUniswapNFT(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1)
    ];

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        for (uint256 i = 0; i < chains.length; i++) {
            Factory factory = factories[i];
            IUniswapNFT uniswapNft = uniswapNfts[i];

            vm.createSelectFork(vm.rpcUrl(chains[i]));
            vm.startBroadcast(deployerPrivateKey);

            BoostNFT boostNft = new BoostNFT{salt: TAG}(deployer, factory);
            BoostManager boostManager = new BoostManager{salt: TAG}(factory, address(boostNft), uniswapNft);

            boostNft.setBoostManager(boostManager);
            boostNft.setOwner(OWNER);

            vm.stopBroadcast();
        }
    }
}
