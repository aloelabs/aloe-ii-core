// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.17;

import "forge-std/Vm.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import "src/Lender.sol";

contract LenderHarness {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    Lender immutable LENDER;

    address[] public holders;

    mapping(address => bool) alreadyHolder;

    address[] public borrowers;

    uint32[] public courierIds;

    mapping(uint32 => bool) alreadyEnrolledCourier;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(Lender lender) {
        LENDER = lender;

        holders.push(lender.RESERVE());
        alreadyHolder[lender.RESERVE()] = true;
    }

    /*//////////////////////////////////////////////////////////////
                                  MAIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new courier (referrer) with the given values
    /// @dev Does not bound inputs without first verifying that the unbounded ones revert
    function enrollCourier(uint32 id, address wallet, uint16 cut) external {
        // Check that inputs are properly formatted
        if (id == 0 || cut == 0 || cut >= 10_000) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.enrollCourier(id, wallet, cut);
        }
        if (id == 0) id = 1;
        cut = (cut % 9_999) + 1;

        // Check whether the given id is enrolled already
        (, uint16 currentCut) = LENDER.couriers(id);
        if (currentCut != 0) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.enrollCourier(id, wallet, cut);

            assert(alreadyEnrolledCourier[id]);
            return;
        }

        // Actual action
        vm.prank(msg.sender);
        LENDER.enrollCourier(id, wallet, cut);

        // Assertions
        (address actualWallet, uint16 actualCut) = LENDER.couriers(id);
        require(actualWallet == wallet, "enrollCourier: failed to set wallet");
        require(actualCut == cut, "enrollCourier: failed to set cut");

        // {HARNESS BOOKKEEPING} Keep courierIds up-to-date
        assert(!alreadyEnrolledCourier[id]);
        courierIds.push(id);
        alreadyEnrolledCourier[id] = true;

        // {HARNESS BOOKKEEPING} Keep holders up-to-date
        if (!alreadyHolder[wallet]) {
            holders.push(wallet);
            alreadyHolder[wallet] = true;
        }
    }

    /// @notice Credits a courier for an `account`'s deposits
    /// @dev Does not bound inputs without first verifying that the unbounded ones revert
    function creditCourier(uint32 id, address account) public {
        // Check that `msg.sender` has permission to assign a courier to `account`
        if (msg.sender != account) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.creditCourier(id, account);

            vm.prank(account);
            LENDER.approve(msg.sender, 1);
        }

        // Check for `RESERVE` involvement, courier existence, self-reference, and non-zero balance
        (address wallet, ) = LENDER.couriers(id);
        if (account == LENDER.RESERVE() ||
            !alreadyEnrolledCourier[id] ||
            wallet == account ||
            LENDER.balanceOf(account) > 0
        ) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.creditCourier(id, account);
            return;
        }

        // Actual action
        vm.prank(msg.sender);
        LENDER.creditCourier(id, account);

        // Assertions
        require(LENDER.courierOf(account) == id, "creditCourier: failed to set id");
        require(LENDER.principleOf(account) == 0, "creditCourier: messed up principle");

        // Undo side-effects
        vm.prank(account);
        LENDER.approve(msg.sender, 0);
    }

    /// @notice Jumps forward `elapsedTime` seconds and accrues interest on the `LENDER`
    /// @dev Does not bound anything because `accrueInterest` takes no args
    function accrueInterest(uint16 elapsedTime) external {
        if (elapsedTime > 0) {
            vm.warp(block.timestamp + elapsedTime);
        }
        vm.prank(msg.sender);
        LENDER.accrueInterest();

        // TODO: Once we remove the second case on Ledger.sol:322 (if (cache.lastAccrualTime == block.timestamp || oldBorrows == 0))
        // and address issue#42, we can pull this assertion out of the if statement
        if (uint256(LENDER.borrowBase()) * uint256(LENDER.borrowIndex()) / BORROWS_SCALER > 0) {
            require(LENDER.lastAccrualTime() == block.timestamp, "accrueInterest: bad time");
        }
    }

    /// @notice Deposits `amount` and sends new `shares` to `beneficiary`
    function deposit(uint112 amount, address beneficiary) public returns (uint256 shares) {
        amount = uint112(amount % (LENDER.maxDeposit(msg.sender) + 1));

        ERC20 asset = LENDER.asset();
        uint256 free = asset.balanceOf(address(LENDER)) - LENDER.lastBalance();
        uint256 amountToTransfer = amount > free ? amount - free : 0;

        shares = LENDER.previewDeposit(amount);

        // Make sure `msg.sender` has enough assets to deposit
        if (amountToTransfer > 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes(shares > 0 ? "Aloe: insufficient pre-pay" : "Aloe: zero impact"));
            LENDER.deposit(amount, beneficiary);

            MockERC20 mock = MockERC20(address(asset));
            mock.mint(msg.sender, amountToTransfer);
        }

        // Collect data
        uint256 lastBalance = LENDER.lastBalance();
        uint256 totalSupply = LENDER.totalSupply();
        uint256 sharesBefore = LENDER.balanceOf(beneficiary);
        uint256 reservesBefore = LENDER.balanceOf(LENDER.RESERVE());

        // Actual action
        // --> Pre-pay for the shares
        vm.prank(msg.sender);
        asset.transfer(address(LENDER), amountToTransfer);
        // --> Make deposit
        if (shares == 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: zero impact"));
            LENDER.deposit(amount, beneficiary);
            amount = 0;
        } else {
            vm.prank(msg.sender);
            require(LENDER.deposit(amount, beneficiary) == shares, "deposit: incorrect preview");
        }

        // Collect more data
        uint256 newReserves = LENDER.totalSupply() - (totalSupply + shares); // implicit assertion!
        uint256 reservesAfter = LENDER.balanceOf(LENDER.RESERVE());

        // Assertions
        require(LENDER.lastBalance() == lastBalance + amount, "deposit: lastBalance mismatch");
        if (beneficiary != LENDER.RESERVE()) {
            require(LENDER.balanceOf(beneficiary) == sharesBefore + shares, "deposit: mint issue");
            require(reservesAfter == reservesBefore + newReserves, "deposit: reserves issue");
        } else {
            require(reservesAfter == reservesBefore + newReserves + shares, "deposit: mint to RESERVE issue");
        }

        // {HARNESS BOOKKEEPING} Keep holders up-to-date
        if (!alreadyHolder[beneficiary]) {
            holders.push(beneficiary);
            alreadyHolder[beneficiary] = true;
        }
    }

    /// @notice Redeems `shares` from `owner` and sends underlying assets to `recipient`
    function redeem(uint112 shares, address recipient, address owner) public returns (uint256 amount) {
        // Check that `owner` actually has `shares`
        uint256 maxRedeem = LENDER.maxRedeem(owner);
        if (shares > maxRedeem) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.redeem(shares, recipient, owner);

            shares = uint112(shares % (maxRedeem + 1));
        }

        // Check that `msg.sender` has permission to burn `owner`'s shares
        if (owner != msg.sender) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.redeem(shares, recipient, owner);

            vm.prank(owner);
            LENDER.approve(msg.sender, shares);
        }

        // Collect data
        amount = LENDER.previewRedeem(shares);
        uint256 lastBalance = LENDER.lastBalance();
        uint256 totalSupply = LENDER.totalSupply();
        uint256 sharesBefore = LENDER.balanceOf(owner);
        uint256 reservesBefore = LENDER.balanceOf(LENDER.RESERVE());
        uint256 assetsBefore = LENDER.asset().balanceOf(recipient);

        // Actual action
        if (amount == 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: zero impact"));
            LENDER.redeem(shares, recipient, owner);
            shares = 0;
        } else {
            vm.prank(msg.sender);
            require(LENDER.redeem(shares, recipient, owner) == amount, "redeem: incorrect preview");
        }

        // Collect more data
        uint256 newReserves = LENDER.totalSupply() - (totalSupply - shares); // implicit assertion!
        uint256 reservesAfter = LENDER.balanceOf(LENDER.RESERVE());

        // Assertions
        require(LENDER.lastBalance() == lastBalance - amount, "redeem: lastBalance mismatch");
        require(LENDER.asset().balanceOf(recipient) == assetsBefore + amount, "redeem: transfer issue");
        if (owner != LENDER.RESERVE()) {
            require(LENDER.balanceOf(owner) == sharesBefore - shares, "redeem: burn issue");
            require(reservesAfter == reservesBefore + newReserves, "redeem: reserves issue");
        } else {
            require(reservesAfter == reservesBefore + newReserves - shares, "redeem: burn from RESERVE issue");
        }
        /// TODO: could also make assertions regarding courier payouts
    }

    /// @notice Borrows `amount` from the `LENDER` and sends it to `recipient`
    function borrow(uint112 amount, address recipient) public returns (uint256 units) {
        // Check that `msg.sender` is a borrower
        if (LENDER.borrows(msg.sender) == 0) {
            vm.expectRevert("Aloe: not a borrower");
            LENDER.borrow(amount, recipient);

            vm.prank(LENDER.FACTORY());
            LENDER.whitelist(msg.sender);

            // {HARNESS BOOKKEEPING} Keep borrowers up-to-date
            borrowers.push(msg.sender);
        }

        // Check that `LENDER` actually has `amount` available for borrowing
        uint256 maxBorrow = LENDER.lastBalance();
        if (amount > maxBorrow) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.borrow(amount, recipient);

            amount = uint112(amount % (maxBorrow + 1));
        }

        // Collect data
        ERC20 asset = LENDER.asset();
        uint256 lastBalance = LENDER.lastBalance();
        uint256 borrowBase = LENDER.borrowBase();
        uint256 borrowUnitsBefore = LENDER.borrows(msg.sender);
        uint256 borrowBalanceBefore = LENDER.borrowBalance(msg.sender);
        uint256 assetsBefore = asset.balanceOf(recipient);

        // Actual action
        vm.prank(msg.sender);
        units = LENDER.borrow(amount, recipient);

        // Assertions
        require(LENDER.lastBalance() == lastBalance - amount, "borrow: lastBalance mismatch");
        require(LENDER.borrowBase() == borrowBase + units, "borrow: borrowBase mismatch");
        require(LENDER.borrows(msg.sender) == borrowUnitsBefore + units, "borrow: bad internal bookkeeping");
        require(LENDER.borrows(msg.sender) > 0, "borrow: broken whitelist");
        require(units > 0 || amount == 0, "borrow: free money!!");
        uint256 borrowBalanceAfter = LENDER.borrowBalance(msg.sender);
        uint256 expectedBorrowBalance = borrowBalanceBefore + amount;
        require(
            expectedBorrowBalance <= borrowBalanceAfter && borrowBalanceAfter <= expectedBorrowBalance + 1,
            "borrow: debt mismatch"
        );
        if (recipient != address(LENDER)) {
            require(asset.balanceOf(recipient) == assetsBefore + amount, "borrow: transfer issue");
        } else {
            require(asset.balanceOf(recipient) == assetsBefore, "borrow: bad self reference");
        }
    }

    /// @notice Pays off some `amount` of debt on behalf of `beneficiary`
    function repay(uint112 amount, address beneficiary) public returns (uint256) {
        // Check that `beneficiary` is a borrower
        uint256 b = LENDER.borrows(beneficiary);
        if (b == 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: repay too much"));
            LENDER.repay(amount, beneficiary);
            return 0;
        }

        // Check that `beneficiary` has borrowed at least `amount`
        uint256 maxRepay = LENDER.borrowBalance(beneficiary);
        if (amount > maxRepay) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: repay too much"));
            LENDER.repay(amount, beneficiary);

            amount = uint112(amount % (maxRepay + 1));
        }

        ERC20 asset = LENDER.asset();
        uint256 free = asset.balanceOf(address(LENDER)) - LENDER.lastBalance();
        uint256 amountToTransfer = amount > free ? amount - free : 0;

        // Make sure `msg.sender` has enough assets to repay
        if (amountToTransfer > 0) {
            vm.prank(msg.sender);
            vm.expectRevert(bytes("Aloe: insufficient pre-pay"));
            LENDER.repay(amount, beneficiary);

            MockERC20 mock = MockERC20(address(asset));
            mock.mint(msg.sender, amountToTransfer);
        }

        // Collect data
        uint256 lastBalance = LENDER.lastBalance();
        uint256 borrowBase = LENDER.borrowBase();
        uint256 borrowUnitsBefore = LENDER.borrows(beneficiary);
        uint256 borrowBalanceBefore = LENDER.borrowBalance(beneficiary);

        // Actual action
        // --> Pre-pay for the debt
        vm.prank(msg.sender);
        asset.transfer(address(LENDER), amountToTransfer);
        // --> Repay
        vm.prank(msg.sender);
        uint256 units = LENDER.repay(amount, beneficiary);        

        // Assertions
        require(LENDER.lastBalance() == lastBalance + amount, "repay: lastBalance mismatch");
        require(LENDER.borrowBase() == borrowBase - units, "repay: borrowBase mismatch");
        require(LENDER.borrows(beneficiary) == borrowUnitsBefore - units, "repay: bad internal bookkeeping");
        require(LENDER.borrows(beneficiary) > 0, "repay: broken whitelist");
        require(units > 0 || amount == 0, "repay: lossy");
        uint256 borrowBalanceAfter = LENDER.borrowBalance(beneficiary);
        uint256 expectedBorrowBalance = borrowBalanceBefore - amount;
        require(
            expectedBorrowBalance <= borrowBalanceAfter && borrowBalanceAfter <= expectedBorrowBalance + 1,
            "repay: debt mismatch"
        );

        return units;
    }

    /// @notice Sends `shares` from `msg.sender` to `to`
    /// @dev Does not bound inputs without first verifying that the unbounded ones revert
    function transfer(address to, uint112 shares) public returns (bool) {
        // Check that neither `msg.sender` nor `to` have couriers
        if (LENDER.courierOf(msg.sender) != 0 || LENDER.courierOf(to) != 0) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.transfer(to, shares);
            return false;
        }

        // Check that `msg.sender` has sufficient shares to make the transfer
        uint256 balance = LENDER.balanceOf(msg.sender);
        if (balance < shares) {
            vm.prank(msg.sender);
            vm.expectRevert();
            LENDER.transfer(to, shares);

            shares = balance > 0 ? uint112(shares % (balance + 1)) : 0;
        }

        // {HARNESS BOOKKEEPING} Keep holders up-to-date
        if (!alreadyHolder[to]) {
            holders.push(to);
            alreadyHolder[to] = true;
        }

        // Actual action
        vm.prank(msg.sender);
        return LENDER.transfer(to, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            HELP THE FUZZER
    //////////////////////////////////////////////////////////////*/

    function creditCourier(uint16 i, address account) external {
        uint256 count = courierIds.length;
        if (count == 0) return;
        else creditCourier(courierIds[i % count], account);
    }

    function depositStandard(uint112 amount) external returns (uint256 shares) {
        shares = deposit(amount, msg.sender);
    }

    function redeemStandard(uint112 shares, address recipient) external returns (uint256 amount) {
        amount = redeem(shares, recipient, msg.sender);
    }

    function redeemMax(address recipient) external returns (uint256 amount) {
        amount = redeem(uint112(LENDER.maxRedeem(msg.sender)), recipient, msg.sender);
    }

    function repay(uint112 amount, uint16 i) external returns (uint256) {
        uint256 count = borrowers.length;
        if (count == 0) return 0;
        else return repay(amount, borrowers[i % count]);
    }

    function repayMax(uint16 i) external returns (uint256) {
        uint256 count = borrowers.length;
        if (count == 0) return 0;
        
        address beneficiary = borrowers[i % count];
        // uint256 amount = LENDER.borrowBalance(beneficiary);
        // if (amount > type(uint112).max) amount = type(uint112).max;
        return repay(uint112(LENDER.borrowBalance(beneficiary)), beneficiary);
    }

    /*//////////////////////////////////////////////////////////////
                             SPECIAL CASES
    //////////////////////////////////////////////////////////////*/

    function creditCourierForReserve(uint16 i) external {
        uint256 count = courierIds.length;
        if (count == 0) return;
        else creditCourier(courierIds[i % count], LENDER.RESERVE());
    }

    function depositToReserves(uint112 amount) external returns (uint256 shares) {
        shares = deposit(amount, LENDER.RESERVE());
    }

    function depositWithLenderAsSharesReceiver(uint112 amount) external returns (uint256 shares) {
        shares = deposit(amount, address(LENDER));
    }

    function redeemFromReserves(uint112 shares, address recipient) external returns (uint256 amount) {
        amount = redeem(shares, recipient, LENDER.RESERVE());
    }

    function redeemWithLenderAsAssetReceiver(uint112 shares, address owner) public returns (uint256 amount) {
        amount = redeem(shares, address(LENDER), owner);
    }

    function borrowWithLenderAsAssetReceiver(uint112 amount) external returns (uint256 units) {
        units = borrow(amount, address(LENDER));
    }

    function transferToSelf(uint112 shares) external returns (bool) {
        return transfer(msg.sender, shares);
    }

    /*//////////////////////////////////////////////////////////////
                             ARRAY LENGTHS
    //////////////////////////////////////////////////////////////*/

    function getHolderCount() external view returns (uint256) {
        return holders.length;
    }

    function getBorrowerCount() external view returns (uint256) {
        return borrowers.length;
    }
}
