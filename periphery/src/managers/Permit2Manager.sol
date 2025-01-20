// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IManager} from "aloe-ii-core/Borrower.sol";
import {Factory} from "aloe-ii-core/Factory.sol";

import {IPermit2} from "../interfaces/IPermit2.sol";

/// @dev Permit2 signatures attest to {token, amount, spender, nonce, deadline}. Noticeable lacking is a `to`
/// field. So given a signature, this contract would have permission to send the user's tokens *anywhere*. In
/// this case the `to` address is part of the incoming calldata, so we must verify that the user is the creator
/// of that calldata (or has authorized it somehow).
/// Within `callback`, if `FACTORY.isBorrower(msg.sender) && owner == BORROWER_NFT`, then we can be sure
/// that either the user themselves OR someone who's been approved to manage their NFT(s) is the source
/// of the calldata.
contract Permit2Manager is IManager {
    error Permit2CallFailed();

    error BorrowerCallFailed();

    IPermit2 public immutable PERMIT2;

    Factory public immutable FACTORY;

    address public immutable BORROWER_NFT;

    constructor(IPermit2 permit2, Factory factory, address borrowerNft) {
        PERMIT2 = permit2;
        FACTORY = factory;
        BORROWER_NFT = borrowerNft;
    }

    function callback(bytes calldata data, address owner, uint208) external override returns (uint208) {
        // Need to check that `msg.sender` is really a borrower and that its owner is `BORROWER_NFT`
        // in order to be sure that incoming `data` is in the expected format
        require(FACTORY.isBorrower(msg.sender) && owner == BORROWER_NFT, "Aloe: bad caller");

        // `data` layout...
        // -------------------------------------------
        // | value            | start | end | length |
        // | owner            |     0 |  20 |     20 |
        // | permit2 selector |    20 |  24 |      4 |
        // | permit2 args     |    24 | 408 |    384 |
        // | - token          |    36 |  56 | (20)32 |
        // | - amount         |    56 |  88 |     32 |
        // | - nonce          |    88 | 120 |     32 |
        // | - deadline       |   120 | 152 |     32 |
        // | - to             |   164 | 184 | (20)32 |
        // | - requestedAmount|   184 | 216 |     32 |
        // | - signer         |   228 | 248 | (20)32 |
        // | - signature      |   248 | 408 |    160 |
        // | borrower call    |   408 |   ? |      ? |
        // -------------------------------------------

        // Get references to the calldata for the 2 calls we're going to make
        bytes calldata dataPermit2 = data[20:408];
        bytes calldata dataBorrower = data[408:];

        // Before calling `PERMIT2`, verify
        // (a) correct function selector
        // (b) `to` field matches the highest 160 bits of `nonce`
        // (c) `to` field is the Borrower (`msg.sender`)
        // (d) correct signer address, i.e. [claimed Permit2 signer] == [user who owns the Borrower]
        // Note that data[:20] is the true owner prepended by the `BORROWER_NFT`
        require(
            bytes4(dataPermit2[:4]) == IPermit2.permitTransferFrom.selector &&
                bytes20(dataPermit2[68:88]) == bytes20(msg.sender) &&
                bytes20(dataPermit2[144:164]) == bytes20(msg.sender) &&
                bytes20(dataPermit2[208:228]) == bytes20(data[:20])
        );

        // Make calls
        bool success;
        (success, ) = address(PERMIT2).call(dataPermit2); // solhint-disable-line avoid-low-level-calls
        if (!success) revert Permit2CallFailed();

        (success, ) = msg.sender.call(dataBorrower); // solhint-disable-line avoid-low-level-calls
        if (!success) revert BorrowerCallFailed();

        // Tag Borrower with `Fuse2Borrower()` function selector so we can identify it on the frontend
        return 0x83ee755b << 144;
    }
}
