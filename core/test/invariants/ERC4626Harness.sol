// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "forge-std/Vm.sol";

import {ERC4626, ERC20} from "solmate/mixins/ERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import "src/Lender.sol";

contract ERC4626Harness {
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    ERC4626 immutable VAULT;

    address[] public holders;

    mapping(address => bool) alreadyHolder;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(Lender lender) {
        VAULT = ERC4626(address(lender));

        holders.push(lender.RESERVE());
        alreadyHolder[lender.RESERVE()] = true;
    }

    /*//////////////////////////////////////////////////////////////
                                  MAIN
    //////////////////////////////////////////////////////////////*/

    // I'd prefer for this to be in the invariant testing file, but currently invariants don't accept fuzzed args.
    // Goal is just to make sure the `convertToXXXXXX` methods (a) don't revert and (b) don't depend on caller.
    function testViewMethods(address callerA, address callerB, uint128 amount) external {
        uint256 a;
        uint256 b;

        vm.prank(callerA);
        a = VAULT.convertToAssets(amount);
        vm.prank(callerB);
        b = VAULT.convertToAssets(amount);
        require(a == b, "convertToAssets varied with caller");

        vm.prank(callerA);
        a = VAULT.convertToShares(amount);
        vm.prank(callerB);
        b = VAULT.convertToShares(amount);
        require(a == b, "convertToShares varied with caller");
    }

    /// @dev Don't mess with the logic here, things get weird. See https://github.com/foundry-rs/foundry/issues/3806
    function warp(uint16 elapsedTime) external {
        uint256 t0 = block.timestamp;
        uint256 t1 = t0 + elapsedTime;
        if (elapsedTime > 0) {
            vm.warp(t1);
            require(block.timestamp == t1, "warp failed");
        }
    }

    function deposit(uint256 amount, address receiver, bool shouldPrepay) public returns (uint256 shares) {
        amount = amount % (VAULT.maxDeposit(msg.sender) + 1); // TODO: if remove this, could run with reverts allowed

        ERC20 asset = VAULT.asset();
        uint256 balance = asset.balanceOf(msg.sender);

        // MUST return as close to and no more than the exact amount of shares that would be minted in a `deposit` call
        shares = VAULT.previewDeposit(amount);
        if (shares <= 1e5) return 0;

        // Make sure `msg.sender` has enough assets to deposit
        if (amount > balance) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes(shares > 0 ? "TRANSFER_FROM_FAILED" : "Aloe: zero impact"));
            VAULT.deposit(amount, receiver);

            MockERC20 mock = MockERC20(address(asset));
            mock.mint(msg.sender, amount - balance);
            balance = amount;
        }

        // Collect data
        uint256 totalAssets = VAULT.totalAssets();
        // uint256 totalSupply = VAULT.totalSupply();
        uint256 sharesBefore = VAULT.balanceOf(receiver);

        // Actual action
        // --> Pre-pay or approve
        vm.prank(msg.sender);
        if (shouldPrepay)
            asset.transfer(address(VAULT), amount); // MAY support an additional flow
        else asset.approve(address(VAULT), amount); // MUST support EIP-20 `approve`/`transferFrom` flow
        // --> Make deposit
        if (shares == 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: zero impact"));
            VAULT.deposit(amount, receiver);
            amount = 0;
        } else {
            vm.prank(msg.sender);
            vm.expectEmit(true, true, false, true, address(VAULT)); // MUST emit `Deposit` event
            emit Deposit(msg.sender, receiver, amount, shares);
            require(VAULT.deposit(amount, receiver) == shares, "deposit: incorrect preview");
        }

        // Assertions
        require(asset.balanceOf(msg.sender) == balance - amount, "deposit: payment issue");
        require(VAULT.totalAssets() == totalAssets + amount, "deposit: totalAssets mismatch");
        // NOTE: This doesn't hold when interest accrues (because shares are minted to reserves)
        // require(VAULT.totalSupply() == totalSupply + shares, "deposit: totalSupply mismatch");
        if (receiver != holders[0]) {
            require(VAULT.balanceOf(receiver) == sharesBefore + shares, "deposit: mint issue");
        }

        // {HARNESS BOOKKEEPING} Keep holders up-to-date
        if (!alreadyHolder[receiver]) {
            holders.push(receiver);
            alreadyHolder[receiver] = true;
        }
    }

    function mint(uint256 shares, address receiver, bool shouldPrepay) public returns (uint256 amount) {
        shares = 1e5 + 1 + (shares % (VAULT.maxMint(msg.sender) - 1e5)); // TODO: if remove this, could run with reverts allowed

        ERC20 asset = VAULT.asset();
        uint256 balance = asset.balanceOf(msg.sender);

        // MUST return as close to and no more than the exact amount of assets that would be deposited in a `mint` call
        amount = VAULT.previewMint(shares);

        // Make sure `msg.sender` has enough assets to mint
        if (amount > balance) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes(shares > 0 ? "TRANSFER_FROM_FAILED" : "Aloe: zero impact"));
            VAULT.mint(amount, receiver);

            MockERC20 mock = MockERC20(address(asset));
            mock.mint(msg.sender, amount - balance);
            balance = amount;
        }

        // Collect data
        uint256 totalAssets = VAULT.totalAssets();
        uint256 sharesBefore = VAULT.balanceOf(receiver);

        // Actual action
        // --> Pre-pay or approve
        vm.prank(msg.sender);
        if (shouldPrepay)
            asset.transfer(address(VAULT), amount); // MAY support an additional flow
        else asset.approve(address(VAULT), amount); // MUST support EIP-20 `approve`/`transferFrom` flow
        // --> Make mint
        if (shares == 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: zero impact"));
            VAULT.mint(shares, receiver);
        } else {
            vm.prank(msg.sender);
            vm.expectEmit(true, true, false, true, address(VAULT)); // MUST emit `Deposit` event
            emit Deposit(msg.sender, receiver, amount, shares);
            require(VAULT.mint(shares, receiver) == amount, "mint: incorrect preview");
        }

        // Assertions
        require(asset.balanceOf(msg.sender) == balance - amount, "mint: payment issue");
        require(VAULT.totalAssets() == totalAssets + amount, "mint: totalAssets mismatch");
        if (receiver != holders[0]) {
            require(VAULT.balanceOf(receiver) == sharesBefore + shares, "mint: mint issue");
        }
        // NOTE: We don't make assertions about the change in `totalSupply` because when interest accrues,
        // shares are minted to reserves (separate from the operations being tested).

        // {HARNESS BOOKKEEPING} Keep holders up-to-date
        if (!alreadyHolder[receiver]) {
            holders.push(receiver);
            alreadyHolder[receiver] = true;
        }
    }

    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        // MUST revert if all of `shares` cannot be redeemed
        uint256 maxRedeem = VAULT.maxRedeem(owner);
        if (shares == type(uint256).max) {
            shares = maxRedeem;
        } else if (shares > maxRedeem) {
            vm.prank(msg.sender);
            vm.expectRevert();
            VAULT.redeem(shares, receiver, owner);

            shares = shares % (maxRedeem + 1);
        }

        // NOTE: This section is technically not 4626 compliant
        uint256 totalSupply = VAULT.totalSupply();
        if (totalSupply <= 1e5) {
            if (maxRedeem == totalSupply) {
                shares = uint112(maxRedeem);
            } else {
                shares = 0;
            }
        } else if (totalSupply - shares <= 1e5) {
            shares = uint112(totalSupply - 1e5 - 1);
        }

        // SHOULD check `msg.sender` can spend owner funds using allowance
        if (owner != msg.sender) {
            vm.prank(msg.sender);
            vm.expectRevert();
            VAULT.redeem(shares, receiver, owner);

            vm.prank(owner);
            VAULT.approve(msg.sender, shares);
        }

        // Collect data
        assets = VAULT.previewRedeem(shares);
        uint256 totalAssets = VAULT.totalAssets();
        uint256 sharesBefore = VAULT.balanceOf(owner);
        uint256 assetsBefore = VAULT.asset().balanceOf(receiver);

        // Actual action
        if (assets == 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: zero impact"));
            VAULT.redeem(shares, receiver, owner);
            shares = 0;
        } else {
            vm.prank(msg.sender);
            vm.expectEmit(true, true, true, true, address(VAULT)); // MUST emit `Withdraw` event
            emit Withdraw(msg.sender, receiver, owner, assets, shares);
            require(VAULT.redeem(shares, receiver, owner) == assets, "redeem: incorrect preview");
        }

        // Assertions
        require(VAULT.totalAssets() == totalAssets - assets, "redeem: totalAssets mismatch");

        if (receiver != address(VAULT)) {
            require(VAULT.asset().balanceOf(receiver) == assetsBefore + assets, "redeem: transfer issue");
        } else {
            require(VAULT.asset().balanceOf(receiver) == assetsBefore, "redeem: bad self reference");
        }
        if (receiver != holders[0]) {
            require(VAULT.balanceOf(owner) == sharesBefore - shares, "redeem: burn issue");
        }
        // NOTE: We don't make assertions about the change in `totalSupply` because when interest accrues,
        // shares are minted to reserves (separate from the operations being tested).
    }

    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        // MUST revert if all of `assets` cannot be withdrawn
        uint256 maxWithdraw = VAULT.maxWithdraw(owner);
        if (assets > maxWithdraw) {
            vm.prank(msg.sender);
            vm.expectRevert();
            VAULT.withdraw(assets, receiver, owner);

            assets = assets % (maxWithdraw + 1);
        }

        // SHOULD check `msg.sender` can spend owner funds using allowance
        shares = VAULT.previewWithdraw(assets);
        if (owner != msg.sender) {
            vm.prank(msg.sender);
            vm.expectRevert();
            VAULT.withdraw(assets, receiver, owner);

            vm.prank(owner);
            VAULT.approve(msg.sender, shares);
        }

        // Collect data
        uint256 totalAssets = VAULT.totalAssets();
        uint256 sharesBefore = VAULT.balanceOf(owner);
        uint256 assetsBefore = VAULT.asset().balanceOf(receiver);

        // Actual action
        if (assets == 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: zero impact"));
            VAULT.withdraw(assets, receiver, owner);
            shares = 0;
        } else {
            vm.prank(msg.sender);
            vm.expectEmit(true, true, true, true, address(VAULT)); // MUST emit `Withdraw` event
            emit Withdraw(msg.sender, receiver, owner, assets, shares);
            require(VAULT.withdraw(shares, receiver, owner) == shares, "withdraw: incorrect preview");
        }

        // Assertions
        require(VAULT.totalAssets() == totalAssets - assets, "withdraw: totalAssets mismatch");

        if (receiver != address(VAULT)) {
            require(VAULT.asset().balanceOf(receiver) == assetsBefore + assets, "withdraw: transfer issue");
        } else {
            require(VAULT.asset().balanceOf(receiver) == assetsBefore, "withdraw: bad self reference");
        }
        if (receiver != holders[0]) {
            require(VAULT.balanceOf(owner) == sharesBefore - shares, "withdraw: burn issue");
        }
        // NOTE: We don't make assertions about the change in `totalSupply` because when interest accrues,
        // shares are minted to reserves (separate from the operations being tested).
    }

    /*//////////////////////////////////////////////////////////////
                            HELP THE FUZZER
    //////////////////////////////////////////////////////////////*/

    function redeemStandard(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = redeem(shares, receiver, msg.sender);
    }

    function redeemMax(address receiver) external returns (uint256 assets) {
        assets = redeem(VAULT.maxRedeem(msg.sender), receiver, msg.sender);
    }

    function withdrawStandard(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = withdraw(assets, receiver, msg.sender);
    }

    function withdrawMax(address receiver) external returns (uint256 shares) {
        shares = withdraw(VAULT.maxWithdraw(msg.sender), receiver, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                             ARRAY LENGTHS
    //////////////////////////////////////////////////////////////*/

    function getHolderCount() external view returns (uint256) {
        return holders.length;
    }
}
