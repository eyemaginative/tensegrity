// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../lib/uniswap-v4-core-deployed/lib/forge-std/src/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BalanceDelta,
    toBalanceDelta
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {
    TensegrityFeeHook,
    IInitializerHook,
    IERC165
} from "../src/TensegrityFeeHook.sol";
import {TensegrityFeeVault} from "../src/TensegrityFeeVault.sol";

contract MockTensegrityUSDG {
    mapping(address account => uint256 balance) public balanceOf;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function transfer(address recipient, uint256 amount)
        external
        returns (bool)
    {
        uint256 balance =
            balanceOf[msg.sender];

        require(
            balance >= amount,
            "BALANCE"
        );

        unchecked {
            balanceOf[msg.sender] =
                balance - amount;
        }

        balanceOf[recipient] +=
            amount;

        return true;
    }
}

contract MockTensegrityPoolManager {
    function take(
        Currency currency,
        address recipient,
        uint256 amount
    )
        external
    {
        bool ok =
            MockTensegrityUSDG(
                Currency.unwrap(currency)
            ).transfer(
                recipient,
                amount
            );

        require(ok, "TRANSFER");
    }

    function runBeforeInitialize(
        TensegrityFeeHook hook,
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    )
        external
        returns (bytes4)
    {
        return hook.beforeInitialize(
            sender,
            key,
            sqrtPriceX96
        );
    }

    function runHooks(
        TensegrityFeeHook hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta coreDelta
    )
        external
        returns (
            BeforeSwapDelta beforeDelta,
            int128 afterDelta
        )
    {
        (
            ,
            beforeDelta,

        ) =
            hook.beforeSwap(
                sender,
                key,
                params,
                ""
            );

        (
            ,
            afterDelta
        ) =
            hook.afterSwap(
                sender,
                key,
                params,
                coreDelta,
                ""
            );
    }
}

contract TensegrityFeeHookTest is Test {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    address internal constant USDG =
        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address internal constant TNSG =
        0x6e43d92B4aE9C1093d6EfE42b18375f4B3176DAc;

    uint24 internal constant LP_FEE = 2_500;
    int24 internal constant TICK_SPACING = 60;

    address internal constant LBP_STRATEGY =
        0x05d552391067389EE44fec3924157ed33F976000;

    MockTensegrityPoolManager internal manager;
    TensegrityFeeHook internal hook;
    TensegrityFeeVault internal vault;

    PoolKey internal key;

    function setUp() public {
        MockTensegrityUSDG implementation =
            new MockTensegrityUSDG();

        vm.etch(
            USDG,
            address(implementation).code
        );

        manager =
            new MockTensegrityPoolManager();

        MockTensegrityUSDG(USDG).mint(
            address(manager),
            10 ** 30
        );

        hook =
            new TensegrityFeeHook(
                IPoolManager(address(manager)),
                address(this),
                LBP_STRATEGY,
                LP_FEE,
                TICK_SPACING
            );

        vault =
            hook.feeVault();

        key =
            PoolKey({
                currency0: Currency.wrap(USDG),
                currency1: Currency.wrap(TNSG),
                fee: LP_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(hook))
            });
    }

    function _params(
        bool zeroForOne,
        int256 amountSpecified
    )
        internal
        pure
        returns (SwapParams memory)
    {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: 1
        });
    }

    function _assertEpoch(
        uint256 expectedTotal,
        uint256 expectedHolder,
        uint256 expectedDevelopment
    )
        internal
        view
    {
        (
            uint256 total,
            uint256 holder,
            uint256 development,
            uint256 released,
            uint256 holderReleased,
            uint256 developmentReleased
        ) =
            vault.getEpochAccounting(1);

        assertEq(total, expectedTotal);
        assertEq(holder, expectedHolder);
        assertEq(development, expectedDevelopment);
        assertEq(released, 0);
        assertEq(holderReleased, 0);
        assertEq(developmentReleased, 0);
    }

    function testHookPermissions() public view {
        Hooks.Permissions memory permissions =
            hook.getHookPermissions();

        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwapReturnDelta);

        assertTrue(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);

        assertEq(
            uint256(hook.REQUIRED_HOOK_MASK()),
            8396
        );

        assertEq(
            hook.authorized(),
            LBP_STRATEGY
        );

        assertTrue(
            hook.supportsInterface(
                type(IInitializerHook).interfaceId
            )
        );

        assertTrue(
            hook.supportsInterface(
                type(IERC165).interfaceId
            )
        );
    }

    function testAuthorizedInitializerMayInitialize() public {
        bytes4 response =
            manager.runBeforeInitialize(
                hook,
                LBP_STRATEGY,
                key,
                uint160(1 << 96)
            );

        assertEq(
            response,
            IHooks.beforeInitialize.selector
        );
    }

    function testUnauthorizedInitializerCannotInitialize() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityFeeHook.InvalidInitializer.selector,
                address(this),
                LBP_STRATEGY
            )
        );

        manager.runBeforeInitialize(
            hook,
            address(this),
            key,
            uint160(1 << 96)
        );
    }

    function testBuyExactInput() public {
        SwapParams memory params =
            _params(
                true,
                -100_000_000
            );

        BalanceDelta coreDelta =
            toBalanceDelta(
                -96_750_000,
                1_000_000_000_000_000_000
            );

        (
            BeforeSwapDelta beforeDelta,
            int128 afterDelta
        ) =
            manager.runHooks(
                hook,
                address(this),
                key,
                params,
                coreDelta
            );

        assertEq(
            int256(
                beforeDelta.getSpecifiedDelta()
            ),
            3_250_000
        );

        assertEq(
            int256(afterDelta),
            0
        );

        assertEq(
            MockTensegrityUSDG(USDG).balanceOf(
                address(vault)
            ),
            3_250_000
        );

        assertTrue(vault.epochStarted());
        assertEq(vault.currentEpochId(), 1);

        _assertEpoch(
            3_250_000,
            3_000_000,
            250_000
        );
    }

    function testBuyExactOutput() public {
        SwapParams memory params =
            _params(
                true,
                1_000_000_000_000_000_000
            );

        BalanceDelta coreDelta =
            toBalanceDelta(
                -100_000_000,
                1_000_000_000_000_000_000
            );

        (
            BeforeSwapDelta beforeDelta,
            int128 afterDelta
        ) =
            manager.runHooks(
                hook,
                address(this),
                key,
                params,
                coreDelta
            );

        assertEq(
            int256(
                beforeDelta.getSpecifiedDelta()
            ),
            0
        );

        assertEq(
            int256(afterDelta),
            3_359_174
        );

        assertEq(
            MockTensegrityUSDG(USDG).balanceOf(
                address(vault)
            ),
            3_359_174
        );

        _assertEpoch(
            3_359_174,
            3_100_776,
            258_398
        );
    }

    function testSellExactInput() public {
        SwapParams memory params =
            _params(
                false,
                -1_000_000_000_000_000_000
            );

        BalanceDelta coreDelta =
            toBalanceDelta(
                100_000_000,
                -1_000_000_000_000_000_000
            );

        (
            BeforeSwapDelta beforeDelta,
            int128 afterDelta
        ) =
            manager.runHooks(
                hook,
                address(this),
                key,
                params,
                coreDelta
            );

        assertEq(
            int256(
                beforeDelta.getSpecifiedDelta()
            ),
            0
        );

        assertEq(
            int256(afterDelta),
            3_250_000
        );

        assertEq(
            MockTensegrityUSDG(USDG).balanceOf(
                address(vault)
            ),
            3_250_000
        );

        _assertEpoch(
            3_250_000,
            3_000_000,
            250_000
        );
    }

    function testSellExactOutput() public {
        SwapParams memory params =
            _params(
                false,
                100_000_000
            );

        BalanceDelta coreDelta =
            toBalanceDelta(
                103_359_174,
                -1_000_000_000_000_000_000
            );

        (
            BeforeSwapDelta beforeDelta,
            int128 afterDelta
        ) =
            manager.runHooks(
                hook,
                address(this),
                key,
                params,
                coreDelta
            );

        assertEq(
            int256(
                beforeDelta.getSpecifiedDelta()
            ),
            3_359_174
        );

        assertEq(
            int256(afterDelta),
            0
        );

        assertEq(
            MockTensegrityUSDG(USDG).balanceOf(
                address(vault)
            ),
            3_359_174
        );

        _assertEpoch(
            3_359_174,
            3_100_776,
            258_398
        );
    }

    function testAggregateEpochSplit() public {
        manager.runHooks(
            hook,
            address(this),
            key,
            _params(
                true,
                -100_000_000
            ),
            toBalanceDelta(
                -96_750_000,
                1_000_000_000_000_000_000
            )
        );

        manager.runHooks(
            hook,
            address(this),
            key,
            _params(
                true,
                1_000_000_000_000_000_000
            ),
            toBalanceDelta(
                -100_000_000,
                1_000_000_000_000_000_000
            )
        );

        _assertEpoch(
            6_609_174,
            6_100_776,
            508_398
        );
    }

    function testRejectBuyExactInputPartialFill() public {
        vm.expectRevert(
            TensegrityFeeHook.PartialFill.selector
        );

        manager.runHooks(
            hook,
            address(this),
            key,
            _params(
                true,
                -100_000_000
            ),
            toBalanceDelta(
                -96_749_999,
                1_000_000_000_000_000_000
            )
        );

        assertEq(
            MockTensegrityUSDG(USDG).balanceOf(
                address(vault)
            ),
            0
        );
    }

    function testRejectBuyExactOutputPartialFill() public {
        vm.expectRevert(
            TensegrityFeeHook.PartialFill.selector
        );

        manager.runHooks(
            hook,
            address(this),
            key,
            _params(
                true,
                1_000_000_000_000_000_000
            ),
            toBalanceDelta(
                -100_000_000,
                999_999_999_999_999_999
            )
        );
    }

    function testRejectSellExactOutputPartialFill() public {
        vm.expectRevert(
            TensegrityFeeHook.PartialFill.selector
        );

        manager.runHooks(
            hook,
            address(this),
            key,
            _params(
                false,
                100_000_000
            ),
            toBalanceDelta(
                103_359_173,
                -1_000_000_000_000_000_000
            )
        );
    }

    function testRejectQuoteBelowMinimum() public {
        vm.expectRevert(
            TensegrityFeeHook.QuoteBelowMinimum.selector
        );

        manager.runHooks(
            hook,
            address(this),
            key,
            _params(
                true,
                -9_999
            ),
            BalanceDelta.wrap(0)
        );
    }

    function testRejectWrongPool() public {
        PoolKey memory badKey =
            key;

        badKey.fee =
            3_000;

        vm.expectRevert(
            TensegrityFeeHook.UnauthorizedPool.selector
        );

        manager.runHooks(
            hook,
            address(this),
            badKey,
            _params(
                true,
                -100_000_000
            ),
            toBalanceDelta(
                -96_750_000,
                1_000_000_000_000_000_000
            )
        );
    }

    function testOnlyPoolManagerMayCallHook() public {
        vm.expectRevert(
            TensegrityFeeHook.OnlyPoolManager.selector
        );

        hook.beforeSwap(
            address(this),
            key,
            _params(
                true,
                -100_000_000
            ),
            ""
        );
    }

    function testOnlyHookMayRecordVaultFee() public {
        vm.expectRevert(
            TensegrityFeeVault.OnlyHook.selector
        );

        vault.recordFee(
            325
        );
    }

    function testVaultReleaseUsesImmutableExecutor() public {
        manager.runHooks(
            hook,
            address(this),
            key,
            _params(
                true,
                -100_000_000
            ),
            toBalanceDelta(
                -96_750_000,
                1_000_000_000_000_000_000
            )
        );

        uint256 balanceBefore =
            MockTensegrityUSDG(USDG).balanceOf(
                address(this)
            );

        (
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        ) =
            vault.releaseAvailable(1);

        assertEq(amount, 3_250_000);
        assertEq(holderAmount, 3_000_000);
        assertEq(developmentAmount, 250_000);

        assertEq(
            MockTensegrityUSDG(USDG).balanceOf(
                address(this)
            ) - balanceBefore,
            3_250_000
        );

        assertEq(
            vault.accountedOutstanding(),
            0
        );
    }

    function testUnauthorizedVaultReleaseReverts() public {
        manager.runHooks(
            hook,
            address(this),
            key,
            _params(
                true,
                -100_000_000
            ),
            toBalanceDelta(
                -96_750_000,
                1_000_000_000_000_000_000
            )
        );

        vm.prank(address(0xBEEF));

        vm.expectRevert(
            TensegrityFeeVault
                .OnlySettlementExecutor
                .selector
        );

        vault.releaseAvailable(1);
    }
}
