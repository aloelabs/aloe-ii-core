// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {Borrower, IManager} from "aloe-ii-core/Borrower.sol";
import {Factory} from "aloe-ii-core/Factory.sol";

import {ERC721Z, SafeSSTORE2, BytesLib} from "./ERC721Z.sol";

interface IBorrowerURISource {
    function uriOf(Borrower borrower) external view returns (string memory);
}

contract BorrowerNFT is ERC721Z {
    using SafeSSTORE2 for address;
    using BytesLib for bytes;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Modify(address indexed owner, Borrower indexed borrower, IManager indexed manager);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    Factory public immutable FACTORY;

    IBorrowerURISource public immutable URI_SOURCE;

    constructor(Factory factory, IBorrowerURISource uriSource) {
        FACTORY = factory;
        URI_SOURCE = uriSource;
    }

    /*//////////////////////////////////////////////////////////////
                           ERC721Z OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function name() external pure override returns (string memory) {
        return "Aloe Borrower";
    }

    function symbol() external pure override returns (string memory) {
        return "BORROW";
    }

    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        return URI_SOURCE.uriOf(_borrowerOf(tokenId));
    }

    /// @inheritdoc ERC721Z
    function _INDEX_SIZE() internal pure override returns (uint256) {
        return 2;
    }

    /// @inheritdoc ERC721Z
    function _ATTRIBUTES_SIZE() internal pure override returns (uint256) {
        return 20;
    }

    /*//////////////////////////////////////////////////////////////
                             MINT & MODIFY
    //////////////////////////////////////////////////////////////*/

    function mint(address to, IUniswapV3Pool[] calldata pools, bytes12[] calldata salts) external payable {
        uint256 qty = pools.length;

        uint256[] memory attributes = new uint256[](qty);
        unchecked {
            for (uint256 i; i < qty; i++) {
                Borrower borrower = FACTORY.createBorrower(pools[i], address(this), salts[i]);
                attributes[i] = uint160(address(borrower));
            }
        }

        _mint(to, qty, attributes);
    }

    function modify(
        address owner,
        uint16[] calldata indices,
        IManager[] calldata managers,
        bytes[] calldata datas,
        uint16[] calldata antes
    ) external payable {
        bytes memory tokenIds = _pointers[owner].read();

        bool authorized = msg.sender == owner || isApprovedForAll[owner][msg.sender];

        unchecked {
            uint256 count = indices.length;
            for (uint256 k; k < count; k++) {
                uint256 tokenId = tokenIds.at(indices[k], _TOKEN_SIZE());

                if (!authorized) require(msg.sender == getApproved[tokenId], "NOT_AUTHORIZED");

                Borrower borrower = _borrowerOf(tokenId);
                borrower.modify{value: uint256(antes[k]) * 1e13}({
                    callee: managers[k],
                    data: bytes.concat(bytes20(owner), datas[k]),
                    oracleSeed: 1 << 32
                });

                emit Modify(owner, borrower, managers[k]);
            }
        }
    }

    function multicall(bytes[] calldata data) external payable {
        unchecked {
            uint256 count = data.length;
            for (uint256 i; i < count; i++) {
                (bool success, ) = address(this).delegatecall(data[i]); // solhint-disable-line avoid-low-level-calls
                require(success);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CONVENIENCE
    //////////////////////////////////////////////////////////////*/

    function tokensOf(address owner) external view returns (uint256[] memory) {
        return _pointers[owner].read().unpack(_TOKEN_SIZE());
    }

    function _borrowerOf(uint256 tokenId) private pure returns (Borrower borrower) {
        uint256 attributes = _attributesOf(tokenId);
        assembly ("memory-safe") {
            borrower := attributes
        }
    }
}
