// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IFeeDiscount} from "./interfaces/IFeeDiscount.sol";

/// @title KawaiiFeeDiscount
/// @notice Phase 1 perp trading-fee discount driven by the Kawaii VIP ladder.
///         Holding the Kawaii NFT grants VIP0 (10% off). Power tiers VIP1..VIP5
///         (up to 50% off) are written per-trader by an owner/keeper via the
///         `override` map. The effective discount is `max(holderBase, override)`,
///         clamped to {MAX_DISCOUNT_BPS}.
/// @dev VIP ladder (basis points of discount; cap 5000 = 50%):
///      - VIP0 (hold NFT, power 0):      1000 (10%)  -> {holderBaseBps}
///      - VIP1 (power 1,000):            1500
///      - VIP2 (power 5,000):            2000
///      - VIP3 (power 25,000):           3000
///      - VIP4 (power 100,000):          4000
///      - VIP5 (power 500,000):          5000
///      Power-tier resolution lives off-chain (a keeper); this contract only
///      stores the resolved per-trader bps and the holder base.
///
///      The NFT holder check is defensive: it uses a low-level staticcall and
///      fails safe to "non-holder" on any revert or malformed return, so a
///      misconfigured / hostile NFT address can never block the discount read.
contract KawaiiFeeDiscount is IFeeDiscount, Ownable {
    /// @notice Maximum discount (50%).
    uint16 public constant MAX_DISCOUNT_BPS = 5000;

    /// @notice Kawaii NFT contract used for the VIP0 holder check.
    address public nft;
    /// @notice True if {nft} is an ERC-1155 (uses balanceOf(address,uint256)),
    ///         false if ERC-721 (uses balanceOf(address)).
    bool public nftIsErc1155;
    /// @notice Token id checked for ERC-1155 holders (ignored for ERC-721).
    uint256 public nftTokenId;

    /// @notice Base discount granted to any Kawaii NFT holder (VIP0). Default 1000.
    uint16 public holderBaseBps = 1000;

    /// @notice Owner/keeper-written per-trader discount for power tiers VIP1..5.
    ///         (`override` is a Solidity reserved word, hence the name.)
    mapping(address trader => uint16 bps) public traderOverrideBps;

    event NftSet(address indexed nft, bool isErc1155, uint256 tokenId);
    event HolderBaseBpsSet(uint16 bps);
    event DiscountSet(address indexed trader, uint16 bps);

    error InvalidBps(uint16 bps);
    error LengthMismatch();

    constructor(address nft_, bool isErc1155_, uint256 tokenId_, address initialOwner) Ownable(initialOwner) {
        nft = nft_;
        nftIsErc1155 = isErc1155_;
        nftTokenId = tokenId_;
        emit NftSet(nft_, isErc1155_, tokenId_);
    }

    /// @inheritdoc IFeeDiscount
    function discountBps(address trader) external view returns (uint16 bps) {
        uint16 base = _holds(trader) ? holderBaseBps : 0;
        uint16 ov = traderOverrideBps[trader];
        bps = base > ov ? base : ov;
        if (bps > MAX_DISCOUNT_BPS) bps = MAX_DISCOUNT_BPS;
    }

    /// @notice True if `trader` holds at least one Kawaii NFT. Fail-safe: any
    ///         revert / malformed return from the NFT contract yields false.
    function holdsNft(address trader) external view returns (bool) {
        return _holds(trader);
    }

    function setNft(address nft_, bool isErc1155_, uint256 tokenId_) external onlyOwner {
        nft = nft_;
        nftIsErc1155 = isErc1155_;
        nftTokenId = tokenId_;
        emit NftSet(nft_, isErc1155_, tokenId_);
    }

    function setHolderBaseBps(uint16 bps) external onlyOwner {
        if (bps > MAX_DISCOUNT_BPS) revert InvalidBps(bps);
        holderBaseBps = bps;
        emit HolderBaseBpsSet(bps);
    }

    function setDiscount(address trader, uint16 bps) external onlyOwner {
        if (bps > MAX_DISCOUNT_BPS) revert InvalidBps(bps);
        traderOverrideBps[trader] = bps;
        emit DiscountSet(trader, bps);
    }

    function setDiscounts(address[] calldata traders, uint16[] calldata bps) external onlyOwner {
        if (traders.length != bps.length) revert LengthMismatch();
        for (uint256 i = 0; i < traders.length; i++) {
            uint16 b = bps[i];
            if (b > MAX_DISCOUNT_BPS) revert InvalidBps(b);
            traderOverrideBps[traders[i]] = b;
            emit DiscountSet(traders[i], b);
        }
    }

    function _holds(address trader) internal view returns (bool) {
        address nft_ = nft;
        if (nft_ == address(0) || trader == address(0)) return false;

        bytes memory callData = nftIsErc1155
            ? abi.encodeWithSignature("balanceOf(address,uint256)", trader, nftTokenId)
            : abi.encodeWithSignature("balanceOf(address)", trader);

        (bool ok, bytes memory ret) = nft_.staticcall(callData);
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) > 0;
    }
}
