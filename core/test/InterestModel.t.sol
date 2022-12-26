// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import "forge-std/Test.sol";

import {InterestModel} from "src/InterestModel.sol";

contract RateModelTest is Test {
    InterestModel model;

    function setUp() public {
        model = new InterestModel();
    }

    function test_neverReverts(uint256 elapsedTime, uint256 utilization) public {
        model.computeYieldPerSecond(utilization % (1e18 - 1));
        uint256 result = model.getAccrualFactor(elapsedTime, utilization);

        assertGe(result, 1e12);
        assertLt(result, 2e12);
    }

    function test_monotonic(uint256 utilization) public {
        vm.assume(utilization != 0);

        assertGe(model.getAccrualFactor(13, utilization), model.getAccrualFactor(13, utilization - 1));
    }

    function test_matchesSpec() public {
        assertEq(model.getAccrualFactor(0, 0), 1e12);
        assertEq(model.getAccrualFactor(13, 0), 1e12);
        assertEq(model.getAccrualFactor(365 days, 0), 1e12);

        assertEq(model.getAccrualFactor(0, 0.1e18), 1e12);
        assertEq(model.getAccrualFactor(13, 0.1e18), 1000000000871);
        assertEq(model.getAccrualFactor(1 days, 0.1e18), 1000005788813);
        assertEq(model.getAccrualFactor(1 weeks, 0.1e18), 1000040522394);
        assertEq(model.getAccrualFactor(365 days, 0.1e18), 1000040522394);

        assertEq(model.getAccrualFactor(0, 0.8e18), 1e12);
        assertEq(model.getAccrualFactor(13, 0.8e18), 1000000031720);
        assertEq(model.getAccrualFactor(1 days, 0.8e18), 1000210838121);
        assertEq(model.getAccrualFactor(1 weeks, 0.8e18), 1001476800691);
        assertEq(model.getAccrualFactor(365 days, 0.8e18), 1001476800691);

        assertEq(model.getAccrualFactor(0, 0.999e18), 1e12);
        assertEq(model.getAccrualFactor(13, 0.999e18), 1000000785200);
        assertEq(model.getAccrualFactor(1 days, 0.999e18), 1005232198483);
        assertEq(model.getAccrualFactor(1 weeks, 0.999e18), 1037205322874);
        assertEq(model.getAccrualFactor(365 days, 0.999e18), 1037205322874);
    }
}
