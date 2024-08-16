// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {MAX_RATE, MAX_LEVERAGE} from "src/libraries/constants/Constants.sol";

import "src/Lender.sol";
import "src/RateModel.sol";

import {FactoryForLenderTests} from "./Utils.sol";

contract LenderTest is Test {
    using stdStorage for StdStorage;

    ERC20 asset;

    Lender lender;

    function setUp() public {
        FactoryForLenderTests factory = new FactoryForLenderTests(new RateModel(), ERC20(address(0)));

        asset = new MockERC20("Token", "TKN", 18);
        lender = factory.deploySingleLender(asset);
    }

    function test_whitelist(address attacker, address borrower, uint256 value) public {
        address factory = address(lender.FACTORY());

        if (attacker == factory) return;

        // Attacker cannot whitelist new borrowers
        vm.expectRevert(bytes(""));
        hoax(attacker);
        lender.whitelist(borrower);

        // Factory can whitelist new borrowers
        hoax(factory);
        lender.whitelist(borrower);
        assertEq(lender.borrows(borrower), 1);

        // Whitelisting does not increase debt
        assertEq(lender.borrowBalanceStored(borrower), 0);

        // Whitelisting cannot erase debt
        if (value == 0) value++;
        stdstore.target(address(lender)).sig("borrows(address)").with_key(borrower).depth(0).checked_write(value);
        vm.expectRevert(bytes(""));
        hoax(factory);
        lender.whitelist(borrower);
    }

    function test_maxRateForOneYear() public {
        vm.warp(1);

        deal(address(asset), address(lender), 1e18);
        lender.deposit(1e18, address(this));

        vm.prank(address(lender.FACTORY()));
        lender.whitelist(address(this));
        lender.borrow(0.1e18, address(this));

        // As interest accrues, utilization rate changes, so we mock _any_ call to getYieldPerSecond
        vm.mockCall(
            address(lender.rateModel()),
            abi.encodeWithSelector(RateModel.getYieldPerSecond.selector),
            abi.encode(type(uint256).max)
        );

        uint72 prevIndex = lender.borrowIndex();

        for (uint256 i = 1; i < 53; i++) {
            vm.warp(1 weeks * i);
            lender.accrueInterest();

            // At MAX_RATE, expect growth of +53% per week
            uint72 currIndex = lender.borrowIndex();
            assertApproxEqRel((uint256(currIndex) * 1e18) / prevIndex, 1.5329e18, 0.0001e18);
            prevIndex = currIndex;
        }

        // 52 weeks per year, so at 53 weeks we expect it to hit max uint72
        vm.warp(1 weeks * 53);
        lender.accrueInterest();
        assertEq(lender.borrowIndex(), type(uint72).max);
    }

    function test_accrueInterest(uint256 yieldPerSecond) public {
        // Give this test contract some shares
        deal(address(asset), address(lender), 2e18);
        lender.deposit(2e18, address(this));

        // Borrow some tokens (so that interest will actually accrue)
        hoax(address(lender.FACTORY()));
        lender.whitelist(address(this));
        lender.borrow(1e18, address(this));

        // Mock interest model
        yieldPerSecond = yieldPerSecond % MAX_RATE;
        vm.mockCall(
            address(lender.rateModel()),
            abi.encodeWithSelector(RateModel.getYieldPerSecond.selector, 0.5e18, address(lender)),
            abi.encode(yieldPerSecond)
        );

        uint256 newInventory = 1e18 +
            FixedPointMathLib.mulDivDown(1e18, FixedPointMathLib.rpow(ONE + yieldPerSecond, 13, ONE), 1e12);
        uint256 interest = newInventory - 2e18;
        uint256 reserves = interest / lender.reserveFactor();
        uint256 epsilon = 2;

        // Initially, the `lender` holds 1e18 and has lent out 1e18
        assertEqDecimal(lender.totalAssets(), 2e18, 18);
        // Now skip forward in time, but don't modify `lender` state yet
        skip(13);
        // `totalAssets` uses view-only methods to compute interest, so it should have updated
        assertEqDecimal(lender.totalAssets(), newInventory, 18);
        // But `underlyingBalanceStored` just reads from storage, so it should still have old value
        assertEqDecimal(lender.underlyingBalanceStored(address(this)), 2e18, 18);
        // Now actually store interest updates
        lender.accrueInterest();
        // Both `totalAssets` and `underlyingBalanceStored` should have updated now
        assertEqDecimal(lender.totalAssets(), newInventory, 18);
        assertLeDecimal(
            stdMath.delta(lender.underlyingBalanceStored(address(this)), newInventory - reserves),
            epsilon,
            18
        );
        // Make sure `borrowIndex` is just as precise as `yieldPerSecond` and `accrualFactor`
        if (yieldPerSecond > 0) assertGt(lender.borrowIndex(), 1e12);

        assertEq(lender.lastAccrualTime(), block.timestamp);
        assertLeDecimal(stdMath.delta(lender.underlyingBalance(lender.RESERVE()), reserves), epsilon, 18);

        vm.clearMockedCalls();
    }

    function test_cannotInflateSharePrice(uint128 amount) public {
        deal(address(asset), address(lender), 1e18);
        lender.deposit(1e18, address(12345));

        uint256 balance = lender.underlyingBalance(address(12345));
        deal(address(asset), address(lender), amount);

        assertEq(lender.underlyingBalance(address(12345)), balance);
    }

    function test_cannotDepositWithoutERC20Transfer(uint112 amount, address to) public {
        if (amount <= 1e5) amount = 1e5 + 1;

        deal(address(asset), address(lender), amount - 1);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        lender.deposit(amount, to);
    }

    function test_previewAndDeposit(uint112 amount, address to) public {
        if (amount <= 1e5) amount = 1e5 + 1;

        uint256 expectedShares = lender.previewDeposit(amount);
        uint256 totalSupply = lender.totalSupply();

        deal(address(asset), address(lender), amount);
        uint256 shares = lender.deposit(amount, to);

        // Check share correctness
        assertEq(shares, expectedShares);
        assertEq(lender.balanceOf(to), expectedShares);
        assertEq(lender.totalSupply(), totalSupply + shares);

        // Check underlying correctness
        assertEq(lender.underlyingBalanceStored(to), amount);
        assertEq(lender.underlyingBalance(to), amount);
    }

    function test_depositMultipleDestinations(uint112 amountA, uint112 amountB, address toA, address toB) public {
        if (toA == toB) return;

        if (uint256(amountA) + uint256(amountB) > type(uint112).max) {
            amountA = amountA / 2;
            amountB = amountB / 2;
        }

        deal(address(asset), address(lender), amountA + amountB);
        if (amountA == 0) {
            vm.expectRevert(bytes("Aloe: zero impact"));
            lender.deposit(amountA, toA);
        } else if (amountA <= 1e5) {
            vm.expectRevert(bytes(""));
            lender.deposit(amountA, toA);
            return;
        } else lender.deposit(amountA, toA);

        if (amountB == 0) {
            vm.expectRevert(bytes("Aloe: zero impact"));
            lender.deposit(amountB, toB);
        } else if (lender.totalSupply() + amountB <= 1e5) {
            vm.expectRevert(bytes(""));
            lender.deposit(amountB, toB);
            return;
        } else lender.deposit(amountB, toB);

        assertEq(lender.underlyingBalance(toA), amountA);
        assertEq(lender.underlyingBalance(toB), amountB);
    }

    function test_previewAndDepositWithInterest(uint16 time, uint112 amount, address to) public {
        skip(time);
        test_previewAndDeposit(amount, to);
    }

    function test_deposit() public returns (address alice) {
        alice = makeAddr("alice");
        deal(address(asset), alice, 10000e6);

        hoax(alice, 1e18);
        asset.transfer(address(lender), 100e6);

        hoax(alice);
        uint256 shares = lender.deposit(100e6, alice);

        assertEq(shares, 100e6);
        assertEq(lender.totalSupply(), 100e6);
        assertEq(asset.balanceOf(alice), 9900e6);
    }

    function test_withdraw() public {
        address alice = test_deposit();

        hoax(alice);
        uint256 amount = lender.redeem(100e6, alice, alice);

        assertEq(amount, 100e6);
        assertEq(lender.totalSupply(), 0);
        assertEq(asset.balanceOf(alice), 10000e6);
    }

    function testFail_borrow() public {
        deal(address(asset), address(lender), 10000e6);

        address bob = makeAddr("bob");
        hoax(bob, 1e18);
        lender.borrow(100e6, bob);
    }

    function testFail_repay() public {
        address cindy = makeAddr("cindy");
        deal(address(asset), cindy, 10000e6);

        hoax(cindy, 1e18);
        lender.repay(100e6, cindy);
    }

    function test_spec_borrow() public {
        address alice = test_deposit();

        address jim = makeAddr("jim");
        vm.prank(address(lender.FACTORY()));
        lender.whitelist(jim);

        hoax(jim, 1e18);
        lender.borrow(10e6, jim);

        assertEq(asset.balanceOf(jim), 10e6);
        assertEq(lender.balanceOf(jim), 0);
        assertEq(lender.borrowBalance(jim), 10e6);

        skip(1 days); // seconds
        lender.accrueInterest();

        assertEq(asset.balanceOf(jim), 10e6);
        assertEq(lender.borrowBalance(jim), 10000058);

        assertEq(lender.underlyingBalance(alice), 100000050);
        assertEq(lender.underlyingBalanceStored(alice), 100000050);
    }

    function test_fuzz_borrow(uint256 amount, address recipient, address caller) public {
        vm.prank(caller);
        vm.expectRevert(bytes("Aloe: not a borrower"));
        lender.borrow(amount, recipient);

        // Allow `caller` to borrow (equivalent to `whitelist` but we don't want to depend on that fn here)
        stdstore.target(address(lender)).sig("borrows(address)").with_key(caller).checked_write(1);

        // The `lender` doesn't yet have any assets to loan out
        if (amount > 0) {
            vm.prank(caller);
            vm.expectRevert();
            lender.borrow(amount, recipient);
        }

        // Give the `lender` enough inventory for the borrow to go through (plus a little extra)
        uint256 lastBalance = amount < type(uint112).max ? amount : type(uint112).max;
        deal(address(asset), address(lender), lastBalance);
        vm.store(
            address(lender),
            bytes32(uint256(0)),
            bytes32(uint256((lastBalance << 112) + (block.timestamp << 224)))
        );

        if (amount > type(uint112).max) {
            vm.prank(caller);
            vm.expectRevert();
            lender.borrow(amount, recipient);
            return;
        }

        vm.prank(caller);
        lender.borrow(amount, recipient);

        // Check impact of the borrow
        uint256 expectedUnits = (amount * BORROWS_SCALER) / lender.borrowIndex();
        assertEq(lender.lastBalance(), lastBalance - amount);
        assertEq(lender.borrowBase(), expectedUnits);
        assertEq(lender.borrows(caller), 1 + expectedUnits);
        assertEq(lender.borrowBalance(caller), amount);
        if (recipient == address(lender)) {
            assertEq(asset.balanceOf(recipient), lastBalance);
        } else {
            assertEq(asset.balanceOf(recipient), amount);
        }
    }

    function test_fuzz_borrowTwice(uint112 amount, address recipient, address caller, uint112 anotherAmount) public {
        // Allow `caller` to borrow (equivalent to `whitelist` but we don't want to depend on that fn here)
        stdstore.target(address(lender)).sig("borrows(address)").with_key(caller).checked_write(1);

        // Give the `lender` enough inventory for the borrow to go through (plus a little extra)
        uint256 lastBalance = type(uint112).max;
        deal(address(asset), address(lender), lastBalance);
        vm.store(
            address(lender),
            bytes32(uint256(0)),
            bytes32(uint256((lastBalance << 112) + (block.timestamp << 224)))
        );

        vm.prank(caller);
        lender.borrow(amount, recipient);

        // Check impact of the borrow
        uint256 expectedUnits = (amount * BORROWS_SCALER) / lender.borrowIndex();
        assertEq(lender.lastBalance(), lastBalance - amount);
        assertEq(lender.borrowBase(), expectedUnits);
        assertEq(lender.borrows(caller), 1 + expectedUnits);
        assertEq(lender.borrowBalance(caller), amount);
        if (recipient == address(lender)) {
            assertEq(asset.balanceOf(recipient), lastBalance);
        } else {
            assertEq(asset.balanceOf(recipient), amount);
        }

        if (uint256(amount) + anotherAmount > type(uint112).max) {
            vm.prank(caller);
            vm.expectRevert();
            lender.borrow(anotherAmount, recipient);
            return;
        }
    }

    function test_math_rpowMax() public {
        assertLt(FixedPointMathLib.rpow(ONE + MAX_RATE, 1 seconds, ONE), ONE + ONE / MAX_LEVERAGE);
        assertEq(FixedPointMathLib.rpow(ONE + MAX_RATE, 1 weeks, ONE), 1532963220989);
    }

    function test_math_borrowUnitsUniqueness(uint112 amount, uint72 borrowIndex) public {
        borrowIndex = uint72(bound(borrowIndex, 1e12, type(uint72).max));

        uint256 units = (amount * BORROWS_SCALER) / borrowIndex;

        // Show that `units` will fit in uint184
        assertLe(units, type(uint184).max);

        // Show that the only way for `units` to be 0 is for `amount` to also be 0
        if (amount == 0) assertEq(units, 0);
        else assertGt(units, 0);

        // Show that changing `amount`, even by only 1, causes the `units` calculation to change too
        if (amount < type(uint112).max) {
            assertGt(((amount + 1) * BORROWS_SCALER) / borrowIndex, units);
        } else {
            assertLt(((amount - 1) * BORROWS_SCALER) / borrowIndex, units);
        }

        // Show that as long as `borrowIndex` doesn't change, the original `amount` can be recovered exactly
        assertEq(FixedPointMathLib.unsafeDivUp(units * borrowIndex, BORROWS_SCALER), amount);
    }

    function test_math_repayability(uint112 amount, uint72 borrowIndexA, uint72 borrowIndexB) public {
        borrowIndexA = uint72(bound(borrowIndexA, 1e12, type(uint72).max));
        borrowIndexB = uint72(bound(borrowIndexB, borrowIndexA, type(uint72).max));

        // The `units` that would be added to the `borrows` mapping when the user takes out `amount`
        uint256 units = (amount * BORROWS_SCALER) / borrowIndexA;
        // The value that would be returned by `lender.borrowBalance`
        uint256 maxRepay = FixedPointMathLib.mulDivUp(units, borrowIndexB, BORROWS_SCALER);

        // Extra little check here, not the main emphasis of this test
        {
            // The "official" `maxRepay` should closely match this floor-ed approximation.
            // (We're assuming some time has passed, so borrowIndexB > borrowIndexA)
            uint256 expectedMaxRepay = (uint256(amount) * borrowIndexB) / borrowIndexA;
            if (maxRepay != expectedMaxRepay) assertEq(maxRepay, expectedMaxRepay + 1);
        }

        // The initial computation that would be done in `lender.repay` to determine how many
        // units to subtract from the `borrows` mapping entry.
        // This is the value we really want to test!
        uint256 repayUnits = (maxRepay * BORROWS_SCALER) / borrowIndexB;

        // The user should always be allowed to pay their debt in full
        assertGe(repayUnits, units);

        // Some repayUnits will be wasted due to rounding errors, but those errors should be bounded
        assertLt(repayUnits, units + FixedPointMathLib.unsafeDivUp(BORROWS_SCALER, borrowIndexB));

        // Overshooting, even by just 1, should break the threshold
        assertLt((maxRepay + 0) * BORROWS_SCALER, units * borrowIndexB + BORROWS_SCALER);
        assertGe((maxRepay + 1) * BORROWS_SCALER, units * borrowIndexB + BORROWS_SCALER);
    }
}
