// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import "src/Lender.sol";
import "src/RateModel.sol";

import {Factory, FactoryForLenderTests} from "./Utils.sol";

contract LenderReferralsTest is Test {
    using stdStorage for StdStorage;

    ERC20 asset;

    Lender lender;

    function setUp() public {
        FactoryForLenderTests factory = new FactoryForLenderTests(new RateModel(), ERC20(address(0)));

        asset = new MockERC20("Token", "TKN", 18);
        lender = factory.deploySingleLender(asset);
    }

    function test_canEnrollCourier(uint32 id, address wallet, uint16 cut) public {
        (id, wallet, cut) = _enroll(id, wallet, cut);

        (address a, uint16 b) = lender.FACTORY().couriers(id);
        assertEq(a, wallet);
        assertEq(b, cut);
    }

    function test_cannotSetCutTo0(uint32 id, address wallet) public {
        vm.assume(id != 0);

        Factory factory = lender.FACTORY();
        vm.prank(wallet);
        vm.expectRevert(bytes(""));
        factory.enrollCourier(id, 0);
    }

    function test_cannotSetCutAbove10000(uint32 id, address wallet, uint16 cut) public {
        vm.assume(id != 0);
        if (cut < 10_000) cut += 10_000;

        Factory factory = lender.FACTORY();
        vm.prank(wallet);
        vm.expectRevert(bytes(""));
        factory.enrollCourier(id, cut);
    }

    function test_cannotEnrollId0(address wallet, uint16 cut) public {
        vm.assume(cut != 0);

        Factory factory = lender.FACTORY();
        vm.prank(wallet);
        vm.expectRevert(bytes(""));
        factory.enrollCourier(0, cut);
    }

    function test_cannotEditCourierCut(uint32 id, address wallet, uint16 cutA, uint16 cutB) public {
        cutA = cutA % 10_000;
        cutB = cutB % 10_000;

        vm.assume(id != 0);
        vm.assume(cutA != 0);
        vm.assume(cutB != 0);

        Factory factory = lender.FACTORY();

        vm.prank(wallet);
        factory.enrollCourier(id, cutA);
        vm.prank(wallet);
        vm.expectRevert(bytes(""));
        factory.enrollCourier(id, cutB);
    }

    function test_cannotEditCourierWallet(uint32 id, address walletA, address walletB, uint16 cut) public {
        cut = cut % 10_000;
        vm.assume(id != 0);
        vm.assume(cut != 0);

        Factory factory = lender.FACTORY();

        vm.prank(walletA);
        factory.enrollCourier(id, cut);
        vm.prank(walletB);
        vm.expectRevert(bytes(""));
        factory.enrollCourier(id, cut);
    }

    function test_canCreditCourier(uint32 id, address wallet, uint16 cut) public {
        (id, wallet, cut) = _enroll(id, wallet, cut);
        vm.assume(wallet != address(this));

        deal(address(asset), address(lender), 1e5 + 1);

        lender.deposit(1e5 + 1, address(this), id);
        assertEq(lender.courierOf(address(this)), id);
    }

    function test_canCreditCourierWithPermission(uint32 id, address wallet, uint16 cut, address account) public {
        (id, wallet, cut) = _enroll(id, wallet, cut);
        vm.assume(wallet != account && account != lender.RESERVE());

        vm.prank(account);
        lender.approve(address(this), 1e5 + 1);

        deal(address(asset), address(lender), 1e5 + 1);

        lender.deposit(1e5 + 1, account, id);
        assertEq(lender.courierOf(account), id);
    }

    function test_cannotCreditSelf(uint32 id, address wallet, uint16 cut) public {
        (id, wallet, cut) = _enroll(id, wallet, cut);

        vm.prank(wallet);
        vm.expectRevert(bytes("Aloe: courier"));
        lender.deposit(0, wallet, id);
    }

    function test_cannotCreditCourierWithoutPermission(uint32 id, address wallet, uint16 cut, address account) public {
        (id, wallet, cut) = _enroll(id, wallet, cut);
        vm.assume(account != address(this));

        vm.expectRevert(bytes("Aloe: courier"));
        lender.deposit(0, account, id);
    }

    function test_cannotCreditCourierBeforeEnrollment(uint32 id, address account) public {
        vm.assume(id != 0);
        vm.prank(account);
        lender.approve(address(this), 1);

        vm.expectRevert(bytes("Aloe: courier"));
        lender.deposit(1, account, id);
    }

    function test_cannotCreditCourierAfterAcquiringTokens(
        uint32 id,
        address wallet,
        uint16 cut,
        address account
    ) public {
        vm.assume(wallet != account);
        vm.assume(account != lender.RESERVE());
        (id, wallet, cut) = _enroll(id, wallet, cut);

        vm.prank(account);
        lender.approve(address(this), 1);

        deal(address(lender), account, 1);
        deal(address(asset), address(lender), 1e5 + 1);

        lender.deposit(1e5 + 1, account, id);
        assertEq(lender.courierOf(account), 0);
    }

    function test_depositDoesIncreasePrinciple(
        uint32 id,
        address wallet,
        uint16 cut,
        address caller,
        uint112 amount
    ) public {
        vm.assume(amount > 1e6);
        (id, wallet, cut) = _enroll(id, wallet, cut);
        address to = caller;

        if (to == wallet || to == lender.RESERVE()) {
            vm.prank(to);
            vm.expectRevert(bytes("Aloe: courier"));
            lender.deposit(amount, to, id);
            return;
        }

        deal(address(asset), address(lender), amount);
        vm.prank(caller);
        lender.deposit(amount / 2, to, id);

        assertEq(lender.courierOf(to), id);
        assertEq(lender.principleOf(to), amount / 2);
        assertEq(lender.balanceOf(to), amount / 2);
        assertEq(lender.underlyingBalance(to), amount / 2);

        uint256 val = uint256(vm.load(address(lender), bytes32(uint256(1))));
        val += uint256(amount / 4) << 72;
        val += (1e12) << 184;
        vm.store(address(lender), bytes32(uint256(1)), bytes32(val));

        assertEq(lender.courierOf(to), id);
        assertEq(lender.principleOf(to), amount / 2);
        assertEq(lender.balanceOf(to), amount / 2);
        assertApproxEqAbs(lender.convertToAssets(lender.balanceOf(to)), amount, 2);

        vm.prank(caller);
        lender.deposit(amount / 2, to);

        assertEq(lender.courierOf(to), id);
        assertEq(lender.principleOf(to), amount / 2 + amount / 2);
        assertApproxEqAbs(lender.balanceOf(to), amount / 2 + amount / 4, 1);
        assertApproxEqAbs(lender.convertToAssets(lender.balanceOf(to)), uint256(amount) + amount / 2, 2);
    }

    function test_withdrawDoesPayout(
        uint32 id,
        address wallet,
        uint16 cut,
        address caller,
        uint104 amount
    ) public {
        // MARK: Start by doing everything that `test_depositDoesIncreasePrinciple` does

        amount = uint104(bound(amount, 1e10, type(uint104).max));
        (id, wallet, cut) = _enroll(id, wallet, cut);
        address to = caller;

        if (to == wallet || to == address(lender)) return;

        if (to == wallet || to == lender.RESERVE()) {
            vm.prank(to);
            vm.expectRevert(bytes("Aloe: courier"));
            lender.deposit(amount, to, id);
            return;
        }

        deal(address(asset), address(lender), amount);
        vm.prank(caller);
        lender.deposit(amount / 2, to, id);

        uint256 val = uint256(vm.load(address(lender), bytes32(uint256(1))));
        val += uint256(amount / 4) << 72;
        val += uint256(1e12) << 184;
        vm.store(address(lender), bytes32(uint256(1)), bytes32(val));

        vm.prank(caller);
        lender.deposit(amount / 2, to);

        // MARK: Now do withdrawal stuff

        uint256 bal = lender.balanceOf(to);
        uint256 profit = lender.convertToAssets(bal) - lender.principleOf(to);

        // pretend that borrower pays off a big loan so that lender can make full payout
        deal(address(asset), address(lender), type(uint128).max);
        val = uint256(vm.load(address(lender), bytes32(uint256(1))));
        val -= uint256(amount / 4) << 72;
        vm.store(address(lender), bytes32(uint256(1)), bytes32(val));
        val = uint256(vm.load(address(lender), bytes32(uint256(0))));
        val += uint256(amount / 2) << 112;
        vm.store(address(lender), bytes32(uint256(0)), bytes32(val));

        uint256 reward = (profit * uint256(cut)) / 10_000;
        uint256 rewardShares = lender.convertToShares(reward);

        uint256 maxRedeem = lender.maxRedeem(to);
        assertLe(maxRedeem, bal - rewardShares);
        if (bal - rewardShares >= 1) {
            assertGe(maxRedeem, bal - rewardShares - 1);
        }

        vm.prank(to);
        lender.redeem(maxRedeem, to, to);

        assertApproxEqAbs(lender.balanceOf(wallet), rewardShares, 1);
        assertApproxEqAbs(lender.underlyingBalance(wallet), reward, 1);
    }

    // TODO: test chaining

    // TODO: test withdrawing in 25% chunks

    // TODO: test that nominalShares = balanceOf before any interest has accrued

    // TODO: expect revert if shares > post-fee balance, even if shares < pre-fee balance

    function _enroll(uint32 id, address wallet, uint16 cut) private returns (uint32, address, uint16) {
        cut = cut % 10_000;

        vm.assume(id != 0);
        vm.assume(cut != 0);

        Factory factory = lender.FACTORY();
        vm.prank(wallet);
        factory.enrollCourier(id, cut);

        return (id, wallet, cut);
    }
}
