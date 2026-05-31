// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMorpho, MarketParams as MorphoMarketParams, Id as MorphoId} from "morpho-blue/interfaces/IMorpho.sol";

import {FxPrivacyPool} from "../src/hub/FxPrivacyPool.sol";
import {FxPrivacyEntrypoint} from "../src/hub/FxPrivacyEntrypoint.sol";
import {
    FxMorphoSupplyAdapter,
    FxPerpMarginAdapter,
    FxSpotSwapAdapter,
    IFxExecutionAdapter
} from "../src/hub/FxExecutionAdapter.sol";
import {IFxRouterSwapAdapter} from "../src/hub/FxRouter.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";

import {Entrypoint} from "privacy-pools/contracts/Entrypoint.sol";
import {IEntrypoint} from "privacy-pools/interfaces/IEntrypoint.sol";
import {IPrivacyPool} from "privacy-pools/interfaces/IPrivacyPool.sol";
import {ProofLib} from "privacy-pools/contracts/lib/ProofLib.sol";
import {Constants as PpConstants} from "privacy-pools/contracts/lib/Constants.sol";
import {IVerifier} from "privacy-pools/interfaces/IVerifier.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Always-pass Groth16 stub — relayCrossCurrency tests exercise the
///         post-withdraw routing, not the ZK math.
contract MockVerifier is IVerifier {
    function verifyProof(uint256[2] memory, uint256[2][2] memory, uint256[2] memory, uint256[8] memory)
        external pure returns (bool) { return true; }
    function verifyProof(uint256[2] memory, uint256[2][2] memory, uint256[2] memory, uint256[4] memory)
        external pure returns (bool) { return true; }
}

contract MockMorpho {
    mapping(address => mapping(address => uint256)) public supplyAssetsOf;

    function supply(MorphoMarketParams memory _mp, uint256 _assets, uint256, address _onBehalf, bytes memory)
        external returns (uint256, uint256)
    {
        IERC20(_mp.loanToken).transferFrom(msg.sender, address(this), _assets);
        supplyAssetsOf[_mp.loanToken][_onBehalf] += _assets;
        return (_assets, _assets);
    }
    function withdraw(MorphoMarketParams memory _mp, uint256 _assets, uint256 _shares, address _onBehalf, address _receiver)
        external returns (uint256, uint256)
    {
        uint256 amount = _assets > 0 ? _assets : _shares;
        require(supplyAssetsOf[_mp.loanToken][_onBehalf] >= amount, "insufficient");
        supplyAssetsOf[_mp.loanToken][_onBehalf] -= amount;
        IERC20(_mp.loanToken).transfer(_receiver, amount);
        return (amount, amount);
    }
    function expectedSupplyAssets(MorphoMarketParams memory _mp, address _user) external view returns (uint256) {
        return supplyAssetsOf[_mp.loanToken][_user];
    }
    function market(MorphoId) external pure returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }
    function extSloads(bytes32[] calldata slots) external pure returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
    }
}

contract MockMarketRegistry is IFxMarketRegistry {
    function paramsOf(address loanToken, address collateralToken) external pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: address(0x1),
            irm:    address(0x2),
            lltv:   86e16
        });
    }
    function marketIdOf(address, address) external pure returns (bytes32) { return bytes32(0); }
    function listPools() external pure returns (MarketParams[] memory empty) { return empty; }
    function isPoolLive(address, address) external pure returns (bool) { return true; }
    function setPoolLive(address, address, bool) external {}
    function borrowDelegateOf(address, address) external pure returns (bool) { return false; }
    function setBorrowDelegate(address, bool) external {}
    function supply(address, address, uint256, address) external pure returns (uint256) { return 0; }
    function withdraw(address, address, uint256, address, address) external pure returns (uint256) { return 0; }
    function supplyCollateral(address, address, uint256, address) external {}
    function withdrawCollateral(address, address, uint256, address, address) external {}
    function borrow(address, address, uint256, address, address) external pure returns (uint256) { return 0; }
    function borrowDelegated(address, address, uint256, address, address) external pure returns (uint256) { return 0; }
    function repay(address, address, uint256, address) external pure returns (uint256) { return 0; }
}

/// @notice codex-r2 MED #1 regression vehicle: a fee-on-transfer ERC-20
///         that taxes 100 bps on every outbound transfer. Used to verify
///         the recipient-side balance delta check catches deflation that
///         only manifests on egress.
contract FeeOnTransferToken {
    string  public constant name     = "Fee On Transfer";
    string  public constant symbol   = "FOT";
    uint8   public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    /// 10% tax on every transfer. Symmetric (both `transfer` and
    /// `transferFrom` paths) — that's what real deflationary tokens do.
    uint256 public constant FEE_BPS = 1_000;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _taxed(uint256 amount) internal pure returns (uint256 net, uint256 fee) {
        fee = (amount * FEE_BPS) / 10_000;
        net = amount - fee;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        (uint256 net, uint256 fee) = _taxed(amount);
        balanceOf[to] += net;
        totalSupply -= fee;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        (uint256 net, uint256 fee) = _taxed(amount);
        balanceOf[to] += net;
        totalSupply -= fee;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @notice codex-r1 HIGH #1 regression vehicle: an adapter that *claims*
///         to deliver more than it actually transfers. Measured-delivery
///         check on the entrypoint must catch this.
contract MaliciousAdapter is IFxRouterSwapAdapter {
    using SafeERC20 for IERC20;

    /// @notice Actually transfer this many `buyToken` to `recipient`.
    uint256 public actualDelivery;
    /// @notice Pretend to have delivered this in the return value.
    uint256 public reportedDelivery;

    function setBehavior(uint256 actual, uint256 reported) external {
        actualDelivery   = actual;
        reportedDelivery = reported;
    }

    function swapExactInput(
        address /*sellToken*/,
        address buyToken,
        uint256 /*sellAmountNet*/,
        uint256 /*minBuyAmount*/,
        address recipient
    ) external override returns (uint256 buyAmount) {
        if (actualDelivery > 0) {
            IERC20(buyToken).safeTransfer(recipient, actualDelivery);
        }
        return reportedDelivery;
    }
}

/// @notice Minimal IFxMarginAccount stand-in: credits margin + pulls USDC.
contract MockMarginAccount {
    mapping(address => uint256) public marginOf;
    IERC20 public immutable usdc;
    constructor(address _usdc) { usdc = IERC20(_usdc); }
    function depositMargin(address trader, uint256 amount) external {
        marginOf[trader] += amount;
        usdc.transferFrom(msg.sender, address(this), amount);
    }
}

contract FxPrivacyEntrypointTest is Test {
    address constant OWNER     = address(0xABCD);
    address constant POSTMAN   = address(0xBEEF);
    address constant USER      = address(0xCAFE);
    address constant RECIPIENT = address(0xD00D);
    address constant FEE_SINK  = address(0xFEE5);

    MockStablecoin     internal usdc;
    MockStablecoin     internal eurc;
    MockVerifier       internal verifier;
    MockMorpho         internal morpho;
    MockMarketRegistry internal registry;
    MockSwapAdapter    internal adapter;

    FxPrivacyEntrypoint internal entrypoint;
    FxPrivacyPool       internal pool;
    uint256             internal poolScope;

    function setUp() public {
        usdc     = new MockStablecoin("USD Coin", "USDC", 6, address(this));
        eurc     = new MockStablecoin("EUR Coin", "EURC", 6, address(this));
        verifier = new MockVerifier();
        morpho   = new MockMorpho();
        registry = new MockMarketRegistry();
        adapter  = new MockSwapAdapter();

        // Deploy entrypoint behind ERC1967 proxy (UUPS pattern).
        address impl = address(new FxPrivacyEntrypoint());
        bytes memory initData = abi.encodeWithSelector(
            Entrypoint.initialize.selector, OWNER, POSTMAN
        );
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        entrypoint = FxPrivacyEntrypoint(payable(address(proxy)));

        // Deploy pool wired to the proxy (proxy address is what the pool sees).
        // Run pool deployment at 100% hot so the slice-1/2 mock-Morpho path
        // is unused — this test exercises slice 3 routing, not rehyp.
        pool = new FxPrivacyPool(
            address(entrypoint),
            address(verifier),
            address(verifier),
            address(usdc),
            OWNER,
            address(morpho),
            address(registry),
            address(eurc)
        );
        vm.prank(OWNER);
        pool.setHotReservePct(10_000);
        poolScope = pool.SCOPE();

        // Register pool + enable cross-currency + wire adapter.
        vm.startPrank(OWNER);
        entrypoint.registerPool(IERC20(address(usdc)), IPrivacyPool(address(pool)), 0, 0, 1_000);
        entrypoint.setSwapAdapter(IFxRouterSwapAdapter(address(adapter)));
        entrypoint.setCrossCurrencyEnabled(IERC20(address(usdc)), true);
        vm.stopPrank();

        // Postman publishes a permissive ASP root (single sentinel value).
        // Testnet ASP — every commitment is "approved." This is the v1 mode
        // documented in PRIVACY_HOOK_SPEC.md §5.3.
        vm.prank(POSTMAN);
        entrypoint.updateRoot(uint256(keccak256("permissive-asp")), "QmTestnetPermissiveAspRootCID000000000000");

        // Fund the user + adapter.
        usdc.mint(USER, 1_000e6);
        eurc.mint(address(adapter), 1_000e6); // pre-fund payout reserve

        // adapter at 1:1 (default). Different rate tested below.
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setSwapAdapter_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(USER);
        entrypoint.setSwapAdapter(IFxRouterSwapAdapter(address(adapter)));
    }

    function test_setSwapAdapter_revertsOnZero() public {
        vm.expectRevert(IEntrypoint.ZeroAddress.selector);
        vm.prank(OWNER);
        entrypoint.setSwapAdapter(IFxRouterSwapAdapter(address(0)));
    }

    function test_setCrossCurrencyEnabled_togglesFlag() public {
        assertTrue(entrypoint.crossCurrencyEnabled(IERC20(address(usdc))));
        vm.prank(OWNER);
        entrypoint.setCrossCurrencyEnabled(IERC20(address(usdc)), false);
        assertFalse(entrypoint.crossCurrencyEnabled(IERC20(address(usdc))));
    }

    function test_setCrossCurrencyEnabled_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(USER);
        entrypoint.setCrossCurrencyEnabled(IERC20(address(usdc)), false);
    }

    /*//////////////////////////////////////////////////////////////
                        RELAY CROSS CURRENCY
    //////////////////////////////////////////////////////////////*/

    /// @dev Happy path: user shields USDC, relays cross-currency to receive
    ///      EURC at the recipient.
    function test_relayCrossCurrency_succeedsAt1to1() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 1);

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  0,
            buyToken:     address(eurc),
            minBuyAmount: amount  // 1:1 rate on the mock
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0xAA);

        uint256 recipientBefore = eurc.balanceOf(RECIPIENT);
        entrypoint.relayCrossCurrency(w, p, poolScope);

        assertEq(eurc.balanceOf(RECIPIENT), recipientBefore + amount, "recipient gets EURC");
        assertEq(usdc.balanceOf(FEE_SINK), 0, "no fee at 0 bps");
    }

    function test_relayCrossCurrency_skimsRelayFee() public {
        uint256 amount = 100e6;
        uint256 feeBps = 50; // 0.5%
        _depositFromUser(amount, 2);

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  feeBps,
            buyToken:     address(eurc),
            minBuyAmount: 99e6
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0xBB);

        entrypoint.relayCrossCurrency(w, p, poolScope);

        // 0.5% of 100e6 = 0.5e6 fee in USDC to fee sink.
        assertEq(usdc.balanceOf(FEE_SINK), 0.5e6);
        // 99.5e6 swapped 1:1 → recipient gets 99.5e6 EURC.
        assertEq(eurc.balanceOf(RECIPIENT), 99.5e6);
    }

    /// @dev Adapter delivers nothing but the contract's measured-delivery
    ///      check catches it.
    function test_relayCrossCurrency_revertsOnAdapterUnderpayment() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 3);
        adapter.setForcedBuyAmount(0); // Adapter returns nothing.

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  0,
            buyToken:     address(eurc),
            minBuyAmount: amount
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0xCC);

        vm.expectRevert(abi.encodeWithSelector(
            FxPrivacyEntrypoint.AdapterUnderdelivered.selector, 0, amount
        ));
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    /// @dev codex-r1 HIGH #1 regression: malicious adapter LIES about
    ///      delivery (returns a high claim, transfers only a tiny amount).
    ///      Old code trusted the return value and would not have caught
    ///      this. Measured-delivery check now catches it.
    function test_relayCrossCurrency_catchesAdapterThatLiesAboutDelivery() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 30);

        MaliciousAdapter mal = new MaliciousAdapter();
        eurc.mint(address(mal), 100e6); // pre-fund so the adapter CAN deliver
        // Reports 100e6 delivered, actually transfers 1 wei.
        mal.setBehavior({ actual: 1, reported: amount });

        vm.prank(OWNER);
        entrypoint.setSwapAdapter(IFxRouterSwapAdapter(address(mal)));

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  0,
            buyToken:     address(eurc),
            minBuyAmount: amount
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0x30);

        vm.expectRevert(abi.encodeWithSelector(
            FxPrivacyEntrypoint.AdapterUnderdelivered.selector, 1, amount
        ));
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    /// @dev codex-r2 MED #1 regression: a fee-on-transfer `buyToken` that
    ///      taxes 10% on every transfer. With a margin where the adapter
    ///      check is satisfied but the recipient-side egress tax pushes
    ///      below the user's signed minimum, the recipient-side gate must
    ///      fire — without it, the user silently receives less than signed.
    ///
    ///      Calibration:
    ///        sell = 100e6, FOT tax = 10%
    ///        adapter delivers 100e6 → entrypoint gets 90e6 (tax 1)
    ///        minBuyAmount = 85e6 → adapter check (90 >= 85) PASSES
    ///        entrypoint sends 90e6 → recipient gets 81e6 (tax 2)
    ///        recipient check (81 < 85) FAILS → RecipientUnderdelivered
    function test_relayCrossCurrency_catchesFeeOnTransferEgressTax() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 40);

        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(adapter), 100e6);

        vm.prank(OWNER);
        entrypoint.setCrossCurrencyEnabled(IERC20(address(fot)), true);

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  0,
            buyToken:     address(fot),
            minBuyAmount: 85e6
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0x40);

        vm.expectRevert(abi.encodeWithSelector(
            FxPrivacyEntrypoint.RecipientUnderdelivered.selector, 81e6, 85e6
        ));
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    /// @dev codex-r2 MED #1 regression: zero recipient is now an explicit
    ///      revert before any swap is attempted.
    function test_relayCrossCurrency_revertsOnZeroRecipient() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 41);

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    address(0),
            feeRecipient: FEE_SINK,
            relayFeeBPS:  0,
            buyToken:     address(eurc),
            minBuyAmount: 1
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0x41);

        vm.expectRevert(FxPrivacyEntrypoint.ZeroRecipient.selector);
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    /// @dev codex-r1 HIGH #1 regression: adapter keeps the sell tokens
    ///      and delivers nothing to the entrypoint. Measured delta is 0
    ///      regardless of what the adapter's return value claims.
    function test_relayCrossCurrency_catchesAdapterThatKeepsSellTokens() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 31);

        MaliciousAdapter mal = new MaliciousAdapter();
        // Adapter delivers nothing but reports a non-zero amount — the
        // pre-r1 `AdapterReturnedZero` check would have passed this.
        mal.setBehavior({ actual: 0, reported: amount });

        vm.prank(OWNER);
        entrypoint.setSwapAdapter(IFxRouterSwapAdapter(address(mal)));

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  0,
            buyToken:     address(eurc),
            minBuyAmount: amount
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0x31);

        vm.expectRevert(abi.encodeWithSelector(
            FxPrivacyEntrypoint.AdapterUnderdelivered.selector, 0, amount
        ));
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    function test_relayCrossCurrency_revertsWhenAdapterUnset() public {
        // Re-deploy a bare entrypoint without an adapter wired.
        address impl = address(new FxPrivacyEntrypoint());
        ERC1967Proxy proxy = new ERC1967Proxy(
            impl, abi.encodeWithSelector(Entrypoint.initialize.selector, OWNER, POSTMAN)
        );
        FxPrivacyEntrypoint bare = FxPrivacyEntrypoint(payable(address(proxy)));

        IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({
            processooor: address(bare),
            data: hex""
        });
        ProofLib.WithdrawProof memory p;
        p.pubSignals[2] = 1; // non-zero withdrawnValue clears that gate

        vm.expectRevert(FxPrivacyEntrypoint.SwapAdapterNotSet.selector);
        bare.relayCrossCurrency(w, p, poolScope);
    }

    function test_relayCrossCurrency_revertsWhenAssetDisabled() public {
        vm.prank(OWNER);
        entrypoint.setCrossCurrencyEnabled(IERC20(address(usdc)), false);

        uint256 amount = 100e6;
        _depositFromUser(amount, 4);

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  0,
            buyToken:     address(eurc),
            minBuyAmount: amount
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0xDD);

        vm.expectRevert(abi.encodeWithSelector(
            FxPrivacyEntrypoint.CrossCurrencyDisabled.selector, IERC20(address(usdc))
        ));
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    function test_relayCrossCurrency_revertsWhenBuyEqualsAsset() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 5);

        // buyToken == asset → caller should have used plain `relay()` instead.
        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  0,
            buyToken:     address(usdc),
            minBuyAmount: amount
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0xEE);

        vm.expectRevert(FxPrivacyEntrypoint.BuyTokenEqualsAsset.selector);
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    function test_relayCrossCurrency_revertsWhenFeeOverMax() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 6);

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient:    RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS:  9_999, // > the 1_000 cap registered
            buyToken:     address(eurc),
            minBuyAmount: 1
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0xFF);

        vm.expectRevert(IEntrypoint.RelayFeeGreaterThanMax.selector);
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    /*//////////////////////////////////////////////////////////////
                        DENOMINATION GATE
    //////////////////////////////////////////////////////////////*/

    function _denomSet() internal pure returns (uint256[] memory d) {
        d = new uint256[](4);
        d[0] = 1e6; d[1] = 10e6; d[2] = 100e6; d[3] = 1_000e6;
    }

    function test_setDenominations_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(USER);
        entrypoint.setDenominations(IERC20(address(usdc)), _denomSet());
    }

    function test_setDenominations_enablesGateAndRegistersSet() public {
        vm.prank(OWNER);
        entrypoint.setDenominations(IERC20(address(usdc)), _denomSet());
        assertTrue(entrypoint.denominationGateEnabled(IERC20(address(usdc))));
        assertTrue(entrypoint.isDenomination(IERC20(address(usdc)), 100e6));
        assertFalse(entrypoint.isDenomination(IERC20(address(usdc)), 100.5e6));
    }

    function test_deposit_revertsOnNonDenomination() public {
        vm.prank(OWNER);
        entrypoint.setDenominations(IERC20(address(usdc)), _denomSet());

        usdc.mint(USER, 100.5e6);
        vm.startPrank(USER);
        usdc.approve(address(entrypoint), 100.5e6);
        vm.expectRevert(abi.encodeWithSelector(
            FxPrivacyEntrypoint.NotADenomination.selector, IERC20(address(usdc)), uint256(100.5e6)
        ));
        entrypoint.deposit(IERC20(address(usdc)), 100.5e6, _fakePrecommitment(99));
        vm.stopPrank();
    }

    function test_deposit_succeedsOnDenomination() public {
        vm.prank(OWNER);
        entrypoint.setDenominations(IERC20(address(usdc)), _denomSet());
        _depositFromUser(100e6, 7); // exactly 100e6 — in set
    }

    function test_gateDisabled_allowsArbitraryDeposit() public {
        // Register a set, then turn the gate OFF — arbitrary amounts pass again.
        vm.startPrank(OWNER);
        entrypoint.setDenominations(IERC20(address(usdc)), _denomSet());
        entrypoint.setDenominationGateEnabled(IERC20(address(usdc)), false);
        vm.stopPrank();
        _depositFromUser(100.5e6, 8); // off-denomination, but gate disabled
    }

    function test_relayCrossCurrency_revertsOnNonDenomination() public {
        vm.prank(OWNER);
        entrypoint.setDenominations(IERC20(address(usdc)), _denomSet());
        _depositFromUser(100e6, 11);

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient: RECIPIENT, feeRecipient: FEE_SINK, relayFeeBPS: 0,
            buyToken: address(eurc), minBuyAmount: 37e6
        });
        // withdrawnValue = 37e6 — NOT a registered denomination
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, 37e6, 0xB1);

        vm.expectRevert(abi.encodeWithSelector(
            FxPrivacyEntrypoint.NotADenomination.selector, IERC20(address(usdc)), uint256(37e6)
        ));
        entrypoint.relayCrossCurrency(w, p, poolScope);
    }

    function test_relayCrossCurrency_succeedsOnDenomination() public {
        vm.prank(OWNER);
        entrypoint.setDenominations(IERC20(address(usdc)), _denomSet());
        uint256 amount = 100e6; // in set
        _depositFromUser(amount, 12);

        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data = FxPrivacyEntrypoint.CrossCurrencyRelayData({
            recipient: RECIPIENT, feeRecipient: FEE_SINK, relayFeeBPS: 0,
            buyToken: address(eurc), minBuyAmount: amount
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftWithdrawal(data, amount, 0xB2);

        uint256 before = eurc.balanceOf(RECIPIENT);
        entrypoint.relayCrossCurrency(w, p, poolScope);
        assertEq(eurc.balanceOf(RECIPIENT), before + amount, "denomination withdrawal delivers");
    }

    /*//////////////////////////////////////////////////////////////
                  PRIVATE EXECUTION ROUTER (own-stack)
    //////////////////////////////////////////////////////////////*/

    function _morphoMarket() internal view returns (MorphoMarketParams memory) {
        return MorphoMarketParams({
            loanToken: address(usdc),
            collateralToken: address(eurc),
            oracle: address(0x1),
            irm: address(0x2),
            lltv: 86e16
        });
    }

    function _craftExecuteWithdrawal(
        FxPrivacyEntrypoint.ExecutionRelayData memory data,
        uint256 withdrawnValue,
        uint256 nullifierSalt
    ) internal view returns (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) {
        w = IPrivacyPool.Withdrawal({ processooor: address(entrypoint), data: abi.encode(data) });
        p.pubSignals[0] = uint256(keccak256(abi.encode("new-commit", nullifierSalt))) % PpConstants.SNARK_SCALAR_FIELD;
        p.pubSignals[1] = uint256(keccak256(abi.encode("nullifier", nullifierSalt))) % PpConstants.SNARK_SCALAR_FIELD;
        p.pubSignals[2] = withdrawnValue;
        p.pubSignals[3] = pool.currentRoot();
        p.pubSignals[4] = 1;
        p.pubSignals[5] = entrypoint.latestRoot();
        p.pubSignals[6] = 1;
        p.pubSignals[7] = uint256(keccak256(abi.encode(w, poolScope))) % PpConstants.SNARK_SCALAR_FIELD;
    }

    function test_registerExecutionAdapter_revertsForNonOwner() public {
        FxMorphoSupplyAdapter adapter = new FxMorphoSupplyAdapter(address(morpho), address(entrypoint));
        vm.expectRevert();
        vm.prank(USER);
        entrypoint.registerExecutionAdapter(1, IFxExecutionAdapter(address(adapter)));
    }

    function test_relayExecute_morphoSupplyFromShieldedNote() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 21);

        FxMorphoSupplyAdapter adapter = new FxMorphoSupplyAdapter(address(morpho), address(entrypoint));
        vm.prank(OWNER);
        entrypoint.registerExecutionAdapter(1, IFxExecutionAdapter(address(adapter)));

        FxPrivacyEntrypoint.ExecutionRelayData memory data = FxPrivacyEntrypoint.ExecutionRelayData({
            adapterId: 1,
            recipient: RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS: 0,
            data: abi.encode(_morphoMarket())
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftExecuteWithdrawal(data, amount, 0xE1);

        entrypoint.relayExecute(w, p, poolScope);

        // Morpho recorded the supply on behalf of RECIPIENT, funded from the
        // shielded note — the user's EOA never appears as the supplier.
        assertEq(morpho.supplyAssetsOf(address(usdc), RECIPIENT), amount, "supplied onBehalf recipient");
    }

    function test_relayExecute_skimsRelayFee() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 23);
        FxMorphoSupplyAdapter adapter = new FxMorphoSupplyAdapter(address(morpho), address(entrypoint));
        vm.prank(OWNER);
        entrypoint.registerExecutionAdapter(1, IFxExecutionAdapter(address(adapter)));

        FxPrivacyEntrypoint.ExecutionRelayData memory data = FxPrivacyEntrypoint.ExecutionRelayData({
            adapterId: 1, recipient: RECIPIENT, feeRecipient: FEE_SINK, relayFeeBPS: 100, data: abi.encode(_morphoMarket())
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftExecuteWithdrawal(data, amount, 0xE3);
        entrypoint.relayExecute(w, p, poolScope);
        // 1% fee skimmed in the sell asset; the rest supplied.
        assertEq(usdc.balanceOf(FEE_SINK), 1e6, "1% relay fee");
        assertEq(morpho.supplyAssetsOf(address(usdc), RECIPIENT), 99e6, "99 USDC supplied after fee");
    }

    function test_relayExecute_perpMarginFromShieldedNote() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 31);

        MockMarginAccount margin = new MockMarginAccount(address(usdc));
        FxPerpMarginAdapter adapter =
            new FxPerpMarginAdapter(address(margin), address(entrypoint), address(usdc));
        vm.prank(OWNER);
        entrypoint.registerExecutionAdapter(2, IFxExecutionAdapter(address(adapter)));

        // recipient = the detached executor whose perp margin gets funded.
        FxPrivacyEntrypoint.ExecutionRelayData memory data = FxPrivacyEntrypoint.ExecutionRelayData({
            adapterId: 2, recipient: RECIPIENT, feeRecipient: FEE_SINK, relayFeeBPS: 0, data: ""
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftExecuteWithdrawal(data, amount, 0xF1);

        entrypoint.relayExecute(w, p, poolScope);
        assertEq(margin.marginOf(RECIPIENT), amount, "executor perp margin funded from shielded note");
    }

    function test_relayExecute_spotSwapFromShieldedNote() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 32);

        // Wrap the existing MockSwapAdapter (1:1, pre-funded with EURC in setUp).
        FxSpotSwapAdapter spotAdapter = new FxSpotSwapAdapter(address(adapter), address(entrypoint));
        vm.prank(OWNER);
        entrypoint.registerExecutionAdapter(3, IFxExecutionAdapter(address(spotAdapter)));

        FxPrivacyEntrypoint.ExecutionRelayData memory data = FxPrivacyEntrypoint.ExecutionRelayData({
            adapterId: 3,
            recipient: RECIPIENT,
            feeRecipient: FEE_SINK,
            relayFeeBPS: 0,
            data: abi.encode(address(eurc), amount) // buyToken=EURC, minBuyAmount=amount (1:1)
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftExecuteWithdrawal(data, amount, 0xF2);

        uint256 before = eurc.balanceOf(RECIPIENT);
        entrypoint.relayExecute(w, p, poolScope);
        assertEq(eurc.balanceOf(RECIPIENT), before + amount, "spot swap output delivered to recipient");
    }

    function test_relayExecute_revertsOnUnregisteredAdapter() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 22);
        FxPrivacyEntrypoint.ExecutionRelayData memory data = FxPrivacyEntrypoint.ExecutionRelayData({
            adapterId: 99, recipient: RECIPIENT, feeRecipient: FEE_SINK, relayFeeBPS: 0, data: ""
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftExecuteWithdrawal(data, amount, 0xE2);
        vm.expectRevert(abi.encodeWithSelector(FxPrivacyEntrypoint.ExecutionAdapterNotRegistered.selector, uint256(99)));
        entrypoint.relayExecute(w, p, poolScope);
    }

    function test_relayExecute_revertsOnZeroRecipient() public {
        uint256 amount = 100e6;
        _depositFromUser(amount, 24);
        FxMorphoSupplyAdapter adapter = new FxMorphoSupplyAdapter(address(morpho), address(entrypoint));
        vm.prank(OWNER);
        entrypoint.registerExecutionAdapter(1, IFxExecutionAdapter(address(adapter)));
        FxPrivacyEntrypoint.ExecutionRelayData memory data = FxPrivacyEntrypoint.ExecutionRelayData({
            adapterId: 1, recipient: address(0), feeRecipient: FEE_SINK, relayFeeBPS: 0, data: abi.encode(_morphoMarket())
        });
        (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) =
            _craftExecuteWithdrawal(data, amount, 0xE4);
        vm.expectRevert(FxPrivacyEntrypoint.ZeroRecipient.selector);
        entrypoint.relayExecute(w, p, poolScope);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _depositFromUser(uint256 amount, uint256 nonce) internal {
        usdc.mint(USER, amount);
        vm.startPrank(USER);
        usdc.approve(address(entrypoint), amount);
        entrypoint.deposit(IERC20(address(usdc)), amount, _fakePrecommitment(nonce));
        vm.stopPrank();
    }

    /// @dev Build a Withdrawal + WithdrawProof that passes every gate in
    ///      `PrivacyPool.validWithdrawal` (mocked verifier accepts any pA/pB/pC).
    function _craftWithdrawal(
        FxPrivacyEntrypoint.CrossCurrencyRelayData memory data,
        uint256 withdrawnValue,
        uint256 nullifierSalt
    ) internal view returns (IPrivacyPool.Withdrawal memory w, ProofLib.WithdrawProof memory p) {
        w = IPrivacyPool.Withdrawal({
            processooor: address(entrypoint),
            data:        abi.encode(data)
        });

        // pubSignals layout (slice 1 reference): see ProofLib.WithdrawProof
        //  [0] newCommitmentHash
        //  [1] existingNullifierHash
        //  [2] withdrawnValue
        //  [3] stateRoot
        //  [4] stateTreeDepth (< MAX_TREE_DEPTH)
        //  [5] ASPRoot (== Entrypoint.latestRoot())
        //  [6] ASPTreeDepth (< MAX_TREE_DEPTH)
        //  [7] context = keccak256(_withdrawal, SCOPE) % FIELD
        p.pubSignals[0] = uint256(keccak256(abi.encode("new-commit", nullifierSalt))) % PpConstants.SNARK_SCALAR_FIELD;
        p.pubSignals[1] = uint256(keccak256(abi.encode("nullifier",  nullifierSalt))) % PpConstants.SNARK_SCALAR_FIELD;
        p.pubSignals[2] = withdrawnValue;
        p.pubSignals[3] = pool.currentRoot();
        p.pubSignals[4] = 1; // depth post-deposit
        p.pubSignals[5] = entrypoint.latestRoot();
        p.pubSignals[6] = 1;
        p.pubSignals[7] = uint256(keccak256(abi.encode(w, poolScope))) % PpConstants.SNARK_SCALAR_FIELD;
    }

    function _fakePrecommitment(uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode("precommitment", salt))) % PpConstants.SNARK_SCALAR_FIELD;
    }
}
