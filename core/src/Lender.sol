// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20, SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";

import {BORROWS_SCALER, ONE} from "./libraries/constants/Constants.sol";
import {Q112} from "./libraries/constants/Q.sol";
import {Rewards} from "./libraries/Rewards.sol";

import {Ledger} from "./Ledger.sol";
import {IRateModel} from "./RateModel.sol";

/// @title Lender
/// @author Aloe Labs, Inc.
/// @dev "Test everything; hold fast what is good." - 1 Thessalonians 5:21
contract Lender is Ledger {
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;
    using SafeTransferLib for ERC20;

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Borrow(address indexed caller, address indexed recipient, uint256 amount, uint256 units);

    event Repay(address indexed caller, address indexed beneficiary, uint256 amount, uint256 units);

    event CreditCourier(uint32 indexed id, address indexed account);

    /*//////////////////////////////////////////////////////////////
                       CONSTRUCTOR & INITIALIZER
    //////////////////////////////////////////////////////////////*/

    constructor(address reserve) Ledger(reserve) {}

    function initialize() external {
        require(borrowIndex == 0);
        borrowIndex = uint72(ONE);
        lastAccrualTime = uint32(block.timestamp);
    }

    /// @notice Sets the `rateModel` and `reserveFactor`. Only the `FACTORY` can call this.
    function setRateModelAndReserveFactor(IRateModel rateModel_, uint8 reserveFactor_) external {
        require(msg.sender == address(FACTORY) && reserveFactor_ > 0);

        accrueInterest();
        rateModel = rateModel_;
        reserveFactor = reserveFactor_;
    }

    /**
     * @notice Sets the rewards rate. May be 0. Only the `FACTORY` can call this.
     * @param rate The rewards rate, specified in [token units per second]. If non-zero, keep between 10^17 and
     * 10^28 token units per year for smooth operation. Assuming `FACTORY.rewardsToken()` has 18 decimals, this is
     * between 0.1 and 10 billion tokens per year.
     */
    function setRewardsRate(uint64 rate) external {
        require(msg.sender == address(FACTORY));

        (Rewards.Storage storage s, uint160 a) = Rewards.load(totalSupply);
        Rewards.setRate(s, a, rate);
    }

    /// @notice Allows `borrower` to call `borrow`. One the `FACTORY` can call this.
    function whitelist(address borrower) external {
        // Requirements:
        // - `msg.sender == FACTORY` so that only the factory can whitelist borrowers
        // - `borrows[borrower] == 0` ensures we don't accidentally erase debt
        require(msg.sender == address(FACTORY) && borrows[borrower] == 0);

        // `borrow` and `repay` have to read the `borrows` mapping anyway, so setting this to 1
        // allows them to efficiently check whether a given borrower is whitelisted. This extra
        // unit of debt won't accrue interest or impact solvency calculations.
        borrows[borrower] = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                REWARDS
    //////////////////////////////////////////////////////////////*/

    function claimRewards(address owner) external returns (uint96 earned) {
        // All claims are made through the `FACTORY`
        require(msg.sender == address(FACTORY));

        (Rewards.Storage storage s, uint160 a) = Rewards.load(totalSupply);
        earned = Rewards.claim(s, a, owner, balanceOf(owner));
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints `shares` to `beneficiary` by depositing exactly `amount` of underlying tokens
     * @dev `deposit` is more efficient than `mint` and is the recommended way of depositing. Also
     * supports the additional flow where you prepay `amount` instead of relying on approve/transferFrom.
     * @param amount The amount of underlying tokens to deposit
     * @param beneficiary The receiver of `shares`
     * @param courierId The ID of the courier (or 0, to indicate lack thereof) that will receive a cut of
     * `beneficiary`'s future interest. Only takes effect when `balanceOf(beneficiary) == 0`. In
     * all other cases, pass 0 to avoid wasting gas on courier-related checks.
     * @return shares The number of shares (banknotes) minted to `beneficiary`
     */
    function deposit(uint256 amount, address beneficiary, uint32 courierId) public returns (uint256 shares) {
        if (courierId != 0) {
            // Callers are free to set their own courier, but they need permission to mess with others'
            if (msg.sender != beneficiary) {
                require(allowance[beneficiary][msg.sender] > 0, "Aloe: courier");
                allowance[beneficiary][msg.sender] = 0;
            }

            (address courier, uint16 cut) = FACTORY.couriers(courierId);

            require(
                // Prevent `RESERVE` from having a courier, since its principle wouldn't be tracked properly
                (beneficiary != RESERVE) &&
                    // Payout logic can't handle self-reference, so don't let accounts credit themselves
                    (beneficiary != courier) &&
                    // Make sure `cut` has been set
                    (cut != 0),
                "Aloe: courier"
            );
        }

        // Accrue interest and update reserves
        (Cache memory cache, uint256 inventory) = _load();

        // Convert `amount` to `shares`
        shares = _convertToShares(amount, inventory, cache.totalSupply, /* roundUp: */ false);
        require(shares != 0, "Aloe: zero impact");

        // Mint shares, track rewards, and (if applicable) handle courier accounting
        cache.totalSupply = _mint(beneficiary, shares, amount, cache.totalSupply, courierId);
        require(cache.totalSupply > 1e5);
        // Assume tokens are transferred
        cache.lastBalance += amount;

        // Save state to storage (thus far, only mappings have been updated, so we must address everything else)
        _save(cache, /* didChangeBorrowBase: */ false);

        // Ensure tokens are transferred
        ERC20 asset_ = asset();
        bool didPrepay = cache.lastBalance <= asset_.balanceOf(address(this));
        if (!didPrepay) {
            asset_.safeTransferFrom(msg.sender, address(this), amount);
        }

        emit Deposit(msg.sender, beneficiary, amount, shares);
    }

    function deposit(uint256 amount, address beneficiary) external returns (uint256 shares) {
        shares = deposit(amount, beneficiary, 0);
    }

    function mint(uint256 shares, address beneficiary) external returns (uint256 amount) {
        amount = previewMint(shares);
        deposit(amount, beneficiary, 0);
    }

    /**
     * @notice Burns `shares` from `owner` and sends `amount` of underlying tokens to `receiver`. If
     * `owner` has a courier, additional shares will be transferred from `owner` to the courier as a fee.
     * @dev `redeem` is more efficient than `withdraw` and is the recommended way of withdrawing
     * @param shares The number of shares to burn in exchange for underlying tokens. To burn all your shares,
     * you can pass `maxRedeem(owner)`. If `maxRedeem(owner)` is changing over time (due to a courier or
     * high utilization) you can pass `type(uint256).max` and it will be computed in-place.
     * @param recipient The receiver of `amount` of underlying tokens
     * @param owner The user from whom shares are taken (for both the burn and possible fee transfer)
     * @return amount The number of underlying tokens transferred to `recipient`
     */
    function redeem(uint256 shares, address recipient, address owner) public returns (uint256 amount) {
        if (shares == type(uint256).max) shares = maxRedeem(owner);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Accrue interest and update reserves
        (Cache memory cache, uint256 inventory) = _load();

        // Convert `shares` to `amount`
        amount = _convertToAssets(shares, inventory, cache.totalSupply, /* roundUp: */ false);
        require(amount != 0, "Aloe: zero impact");

        // Burn shares, track rewards, and (if applicable) handle courier accounting
        cache.totalSupply = _burn(owner, shares, inventory, cache.totalSupply);
        require(cache.totalSupply == 0 || cache.totalSupply > 1e5);
        // Assume tokens are transferred
        cache.lastBalance -= amount;

        // Save state to storage (thus far, only mappings have been updated, so we must address everything else)
        _save(cache, /* didChangeBorrowBase: */ false);

        // Transfer tokens
        asset().safeTransfer(recipient, amount);

        emit Withdraw(msg.sender, recipient, owner, amount, shares);
    }

    function withdraw(uint256 amount, address recipient, address owner) external returns (uint256 shares) {
        shares = previewWithdraw(amount);
        redeem(shares, recipient, owner);
    }

    /*//////////////////////////////////////////////////////////////
                           BORROW/REPAY LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends `amount` of `asset` to `recipient` and increases `msg.sender`'s debt by `units`
    function borrow(uint256 amount, address recipient) external returns (uint256 units) {
        // Accrue interest and update reserves
        (Cache memory cache, ) = _load();

        unchecked {
            uint256 b = borrows[msg.sender];
            require(b != 0, "Aloe: not a borrower");

            // Convert `amount` to `units`
            units = (amount * BORROWS_SCALER) / cache.borrowIndex;

            // Track borrows
            borrows[msg.sender] = b + units;
        }
        cache.borrowBase += units;
        // Assume tokens are transferred
        cache.lastBalance -= amount;

        // Save state to storage (thus far, only mappings have been updated, so we must address everything else)
        _save(cache, /* didChangeBorrowBase: */ true);

        // Transfer tokens
        asset().safeTransfer(recipient, amount);

        emit Borrow(msg.sender, recipient, amount, units);
    }

    /**
     * @notice Reduces `beneficiary`'s debt by `units`, assuming someone has pre-paid `amount` of `asset`. To repay
     * all debt for some account, call `repay(borrowBalance(account), account)`.
     * @dev To avoid frontrunning, `amount` should be pre-paid in the same transaction as the `repay` call.
     * @custom:example ```solidity
     *   PERMIT2.permitTransferFrom(
     *     permitMsg,
     *     IPermit2.SignatureTransferDetails({to: address(lender), requestedAmount: amount}),
     *     msg.sender,
     *     signature
     *   );
     *   lender.repay(amount, beneficiary)
     * ```
     */
    function repay(uint256 amount, address beneficiary) external returns (uint256 units) {
        // Accrue interest and update reserves
        (Cache memory cache, ) = _load();

        unchecked {
            uint256 b = borrows[beneficiary];

            // Convert `amount` to `units`
            units = (amount * BORROWS_SCALER) / cache.borrowIndex;
            if (!(units < b)) {
                units = b - 1;

                uint256 maxRepay = (units * cache.borrowIndex).unsafeDivUp(BORROWS_SCALER);
                require(b > 1 && amount <= maxRepay, "Aloe: repay too much");
            }

            // Track borrows
            borrows[beneficiary] = b - units;
            cache.borrowBase -= units;
        }
        // Assume tokens are transferred
        cache.lastBalance += amount;

        // Save state to storage (thus far, only mappings have been updated, so we must address everything else)
        _save(cache, /* didChangeBorrowBase: */ true);

        // Ensure tokens are transferred
        require(cache.lastBalance <= asset().balanceOf(address(this)), "Aloe: insufficient pre-pay");

        emit Repay(msg.sender, beneficiary, amount, units);
    }

    function accrueInterest() public returns (uint72) {
        (Cache memory cache, ) = _load();
        _save(cache, /* didChangeBorrowBase: */ false);
        return uint72(cache.borrowIndex);
    }

    /*//////////////////////////////////////////////////////////////
                               ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function approve(address spender, uint256 shares) external returns (bool) {
        allowance[msg.sender][spender] = shares;

        emit Approval(msg.sender, spender, shares);

        return true;
    }

    function transfer(address to, uint256 shares) external returns (bool) {
        accrueInterest();
        _transfer(msg.sender, to, shares);

        return true;
    }

    function transferFrom(address from, address to, uint256 shares) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - shares;

        accrueInterest();
        _transfer(from, to, shares);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                             ERC2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "Aloe: permit expired");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress != address(0) && recoveredAddress == owner, "Aloe: permit invalid");

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Transfers `shares` from `from` to `to`, iff neither of them have a courier
    function _transfer(address from, address to, uint256 shares) private {
        (Rewards.Storage storage s, uint160 a) = Rewards.load(totalSupply);

        unchecked {
            // From most to least significant...
            // -------------------------------
            // | courier id       | 32 bits  |
            // | user's principle | 112 bits |
            // | user's balance   | 112 bits |
            // -------------------------------
            uint256 data;

            data = balances[from];
            require(data >> 224 == 0 && shares <= data % Q112);
            balances[from] = data - shares;

            Rewards.updateUserState(s, a, from, data % Q112);

            data = balances[to];
            require(data >> 224 == 0);
            balances[to] = data + shares;

            Rewards.updateUserState(s, a, to, data % Q112);
        }

        emit Transfer(from, to, shares);
    }

    /// @dev Make sure to do something with the return value, `newTotalSupply`!
    function _mint(
        address to,
        uint256 shares,
        uint256 amount,
        uint256 totalSupply_,
        uint32 courierId
    ) private returns (uint256 newTotalSupply) {
        // Need to compute `newTotalSupply` with checked math to avoid overflow
        newTotalSupply = totalSupply_ + shares;

        unchecked {
            // From most to least significant...
            // -------------------------------
            // | courier id       | 32 bits  |
            // | user's principle | 112 bits |
            // | user's balance   | 112 bits |
            // -------------------------------
            uint256 data = balances[to];

            // Get rewards accounting out of the way
            (Rewards.Storage storage s, uint160 a) = Rewards.load(totalSupply_);
            Rewards.updatePoolState(s, a);
            Rewards.updateUserState(s, a, to, data % Q112);

            // Only set courier if balance is 0. Otherwise previous courier may be cheated out of fees.
            if (data % Q112 == 0) {
                data = uint256(courierId) << 224;
                emit CreditCourier(courierId, to);
            }

            // Keep track of principle iff `to` has a courier
            if (data >> 224 != 0) {
                require(amount + ((data >> 112) % Q112) < Q112);
                data += amount << 112;
            }

            // Keep track of balance regardless of courier.
            // Since `totalSupply` fits in uint112, the user's balance will too. No need to check here.
            balances[to] = data + shares;
        }

        emit Transfer(address(0), to, shares);
    }

    /// @dev Make sure to do something with the return value, `newTotalSupply`!
    function _burn(
        address from,
        uint256 shares,
        uint256 inventory,
        uint256 totalSupply_
    ) private returns (uint256 newTotalSupply) {
        unchecked {
            // Can compute `newTotalSupply` with unchecked math since other checks cover underflow
            newTotalSupply = totalSupply_ - shares;

            // From most to least significant...
            // -------------------------------
            // | courier id       | 32 bits  |
            // | user's principle | 112 bits |
            // | user's balance   | 112 bits |
            // -------------------------------
            uint256 data = balances[from];
            uint256 balance = data % Q112;

            // Get rewards accounting out of the way
            (Rewards.Storage storage s, uint160 a) = Rewards.load(totalSupply_);
            Rewards.updatePoolState(s, a);
            Rewards.updateUserState(s, a, from, balance);

            uint32 id = uint32(data >> 224);
            if (id != 0) {
                uint256 principleAssets = (data >> 112) % Q112;
                uint256 principleShares = principleAssets.mulDivUp(totalSupply_, inventory);

                if (balance > principleShares) {
                    (address courier, uint16 cut) = FACTORY.couriers(id);

                    // Compute total fee owed to courier. Take it out of balance so that
                    // comparison is correct later on (`shares <= balance`)
                    uint256 fee = ((balance - principleShares) * cut) / 10_000;
                    balance -= fee;

                    // Compute portion of fee to pay out during this burn.
                    fee = (fee * shares) / balance;

                    // Send `fee` from `from` to `courier`.
                    // NOTE: We skip principle update on courier, so if couriers credit
                    // each other, 100% of `fee` is treated as profit and will pass through
                    // to the next courier.
                    data -= fee;
                    Rewards.updateUserState(s, a, courier, ((balances[courier] += fee) - fee) % Q112);
                    emit Transfer(from, courier, fee);
                }

                // Update principle
                data -= ((principleAssets * shares) / balance) << 112;
            }

            require(shares <= balance);
            balances[from] = data - shares;
        }

        emit Transfer(from, address(0), shares);
    }

    function _load() private returns (Cache memory cache, uint256 inventory) {
        // Accrue interest (only in memory)
        uint256 newTotalSupply;
        (cache, inventory, newTotalSupply) = _previewInterest(_getCache());

        // Update reserves (new `totalSupply` is only in memory, but `balances[RESERVE]` is updated in storage)
        if (newTotalSupply > cache.totalSupply) {
            cache.totalSupply = _mint(RESERVE, newTotalSupply - cache.totalSupply, 0, cache.totalSupply, 0);
        }
    }

    function _save(Cache memory cache, bool didChangeBorrowBase) private {
        // `cache.lastAccrualTime == 0` implies that `cache.borrowIndex` was updated
        if (cache.lastAccrualTime == 0 || didChangeBorrowBase) {
            borrowBase = cache.borrowBase.safeCastTo184();
            borrowIndex = cache.borrowIndex.safeCastTo72();
        }

        totalSupply = cache.totalSupply.safeCastTo112();
        lastBalance = cache.lastBalance.safeCastTo112();
        lastAccrualTime = uint32(block.timestamp);
    }
}
