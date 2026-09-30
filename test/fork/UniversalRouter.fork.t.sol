// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MonadNetwork, MonadNetworks} from "../../script/config/MonadAddresses.sol";
import {MonadForkTest} from "./MonadForkTest.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice After graduation, trading moves to the (MON, token) pool. Wallets and the web reach it through the
///         network's canonical Uniswap Universal Router; this suite runs the web's exact encoding
///         (`packages/sdk/src/v4.ts`) against the deployed routers: a buy paid in native MON, and a sell authorized
///         with a Permit2 signature inside the same `execute` (PERMIT2_PERMIT + V4_SWAP). It also pins which
///         `ExactInputSingleParams` layout each router decodes.
abstract contract UniversalRouterForkTest is MonadForkTest {
    // universal-router Commands and v4-periphery Actions.
    uint8 internal constant PERMIT2_PERMIT = 0x0a;
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 internal constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    IUniversalRouter internal ur;
    PoolKey internal key;
    address internal trader;
    uint256 internal traderKey;

    /// @dev True when the router's ExactInputSingleParams has `minHopPriceX36` (the SDK's "minHopPrice" layout).
    function _expectsMinHopPrice() internal pure virtual returns (bool);

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        ur = IUniversalRouter(network.universalRouter);
        (trader, traderKey) = makeAddrAndKey("trader");
        vm.deal(trader, 100 ether);
        _graduate();
        key = migrator.poolKeyOf(address(token));
    }

    function test_buyAndSell_throughTheCanonicalRouter() public {
        // Buy: native MON in, exact input, no leftover in the router.
        uint256 monIn = 1 ether;
        vm.prank(trader);
        ur.execute{value: monIn}(_commands(V4_SWAP), _inputs(_swap(true, monIn, 1, 0)), block.timestamp + 60);
        uint256 bought = token.balanceOf(trader);
        assertGt(bought, 0, "tokens received");
        assertEq(trader.balance, 100 ether - monIn, "exactly the input spent");
        assertEq(address(ur).balance, 0, "no MON left in the router");

        // Sell half: Permit2 already has the token's built-in infinite allowance (Solady ERC20), so one signature
        // authorizes the router and the swap runs in the same transaction.
        vm.roll(block.number + 1);
        uint256 amount = bought / 2;
        (,, uint48 nonce) = IPermit2(PERMIT2).allowance(trader, address(token), address(ur));
        bytes memory permit = _permit(amount, nonce);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = permit;
        inputs[1] = _swap(false, amount, 1, 0);
        uint256 monBefore = trader.balance;
        vm.prank(trader);
        ur.execute(_commands(PERMIT2_PERMIT, V4_SWAP), inputs, block.timestamp + 60);
        assertEq(token.balanceOf(trader), bought - amount, "exact input sold");
        assertGt(trader.balance, monBefore, "MON received");
    }

    function test_slippageBoundReverts() public {
        vm.prank(trader);
        vm.expectRevert();
        ur.execute{value: 1 ether}(
            _commands(V4_SWAP), _inputs(_swap(true, 1 ether, type(uint128).max, 0)), block.timestamp + 60
        );
    }

    /// @dev minHopPriceX36 = 32 passes a router that has the field (the bound is tiny) and breaks one that does not
    ///      (it reads 32 as the hookData offset). With 0 both decode the same swap, because currency0 is native MON
    ///      (address 0, read as an empty hookData): the SDK always sends 0.
    function test_routerLayout() public {
        bytes[] memory inputs = _inputs(_swap(true, 1 ether, 1, 32));
        vm.prank(trader);
        if (!_expectsMinHopPrice()) vm.expectRevert();
        ur.execute{value: 1 ether}(_commands(V4_SWAP), inputs, block.timestamp + 60);
    }

    // ------------------------------------------------------------------ encoding (mirrors packages/sdk/src/v4.ts)

    function _swap(bool buy, uint256 amountIn, uint256 minOut, uint256 minHopPriceX36)
        internal
        view
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, buy, uint128(amountIn), uint128(minOut), minHopPriceX36, ""));
        (address input, address output) = buy ? (address(0), address(token)) : (address(token), address(0));
        params[1] = abi.encode(input, amountIn);
        params[2] = abi.encode(output, minOut);
        return abi.encode(actions, params);
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    function _permit(uint256 amount, uint48 nonce) internal view returns (bytes memory) {
        PermitSingle memory p = PermitSingle({
            details: PermitDetails({
                token: address(token),
                amount: uint160(amount),
                expiration: uint48(block.timestamp + 1 days),
                nonce: nonce
            }),
            spender: address(ur),
            sigDeadline: block.timestamp + 60
        });
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IPermit2(PERMIT2).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        PERMIT_SINGLE_TYPEHASH,
                        keccak256(abi.encode(PERMIT_DETAILS_TYPEHASH, p.details)),
                        p.spender,
                        p.sigDeadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderKey, digest);
        return abi.encode(p, abi.encodePacked(r, s, v));
    }

    function _commands(uint8 a) internal pure returns (bytes memory) {
        return abi.encodePacked(a);
    }

    function _commands(uint8 a, uint8 b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, b);
    }

    function _inputs(bytes memory a) internal pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = a;
    }
}

contract UniversalRouterMainnetForkTest is UniversalRouterForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.mainnet();
    }

    function _expectsMinHopPrice() internal pure override returns (bool) {
        return false;
    }
}

contract UniversalRouterTestnetForkTest is UniversalRouterForkTest {
    function _network() internal pure override returns (MonadNetwork memory) {
        return MonadNetworks.testnet();
    }

    function _expectsMinHopPrice() internal pure override returns (bool) {
        return true;
    }
}
