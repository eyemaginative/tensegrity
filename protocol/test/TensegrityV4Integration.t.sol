// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../lib/uniswap-v4-core-deployed/lib/forge-std/src/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {
    PoolId,
    PoolIdLibrary
} from "@uniswap/v4-core/src/types/PoolId.sol";

import {
    ModifyLiquidityParams,
    SwapParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {
    PoolSwapTest
} from "../lib/uniswap-v4-core-deployed/src/test/PoolSwapTest.sol";

import {
    PoolModifyLiquidityTest
} from "../lib/uniswap-v4-core-deployed/src/test/PoolModifyLiquidityTest.sol";

import {
    TensegrityFeeHook,
    IInitializerHook,
    IERC165
} from "../src/TensegrityFeeHook.sol";

import {
    TensegrityFeeVault
} from "../src/TensegrityFeeVault.sol";

contract TensegrityIntegrationERC20 {
    mapping(address account => uint256 balance)
        public balanceOf;

    mapping(
        address owner =>
            mapping(address spender => uint256 amount)
    )
        public allowance;

    function mint(
        address recipient,
        uint256 amount
    )
        external
    {
        balanceOf[recipient] += amount;
    }

    function approve(
        address spender,
        uint256 amount
    )
        external
        returns (bool)
    {
        allowance[msg.sender][spender] =
            amount;

        return true;
    }

    function transfer(
        address recipient,
        uint256 amount
    )
        external
        returns (bool)
    {
        _transfer(
            msg.sender,
            recipient,
            amount
        );

        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    )
        external
        returns (bool)
    {
        if (msg.sender != sender) {
            uint256 allowed =
                allowance[sender][msg.sender];

            require(
                allowed >= amount,
                "ALLOWANCE"
            );

            if (allowed != type(uint256).max) {
                allowance[sender][msg.sender] =
                    allowed - amount;
            }
        }

        _transfer(
            sender,
            recipient,
            amount
        );

        return true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    )
        private
    {
        uint256 senderBalance =
            balanceOf[sender];

        require(
            senderBalance >= amount,
            "BALANCE"
        );

        unchecked {
            balanceOf[sender] =
                senderBalance - amount;
        }

        balanceOf[recipient] +=
            amount;
    }
}

contract TensegrityCreate2Factory {
    error Create2Failed();

    function deploy(
        bytes32 salt,
        bytes memory initCode
    )
        external
        returns (address deployed)
    {
        assembly ("memory-safe") {
            deployed :=
                create2(
                    0,
                    add(initCode, 0x20),
                    mload(initCode),
                    salt
                )
        }

        if (deployed == address(0)) {
            revert Create2Failed();
        }
    }
}

contract TensegrityV4IntegrationTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant USDG =
        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address internal constant TNSG =
        0x6e43d92B4aE9C1093d6EfE42b18375f4B3176DAc;

    address internal constant LBP_STRATEGY =
        0x05d552391067389EE44fec3924157ed33F976000;

    uint24 internal constant LP_FEE =
        2_500;

    int24 internal constant TICK_SPACING =
        60;

    uint160 internal constant ALL_HOOK_MASK =
        uint160((1 << 14) - 1);

    uint160 internal constant REQUIRED_HOOK_MASK =
        0x20CC;

    uint160 internal constant SQRT_PRICE_1_1 =
        79_228_162_514_264_337_593_543_950_336;

    uint256 internal constant INITIAL_BALANCE =
        1e30;

    int256 internal constant INITIAL_LIQUIDITY =
        1e24;

    IPoolManager internal manager;

    TensegrityFeeHook internal hook;
    TensegrityFeeVault internal vault;

    TensegrityCreate2Factory internal factory;

    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    PoolKey internal key;

    function setUp() public {
        // ----------------------------------------------------
        // Canonical-address ERC20 behavior for local-only test.
        // No live-chain state is touched.
        // ----------------------------------------------------

        TensegrityIntegrationERC20 implementation =
            new TensegrityIntegrationERC20();

        vm.etch(
            USDG,
            address(implementation).code
        );

        vm.etch(
            TNSG,
            address(implementation).code
        );

        TensegrityIntegrationERC20(USDG).mint(
            address(this),
            INITIAL_BALANCE
        );

        TensegrityIntegrationERC20(TNSG).mint(
            address(this),
            INITIAL_BALANCE
        );

        // ----------------------------------------------------
        // REAL v4 POOLMANAGER
        // ----------------------------------------------------

        manager =
            IPoolManager(
                address(
                    new PoolManager(
                        address(this)
                    )
                )
            );

        // ----------------------------------------------------
        // CREATE2-MINE EXACT 0x20CC HOOK ADDRESS
        // ----------------------------------------------------

        factory =
            new TensegrityCreate2Factory();

        bytes memory initCode =
            abi.encodePacked(
                type(TensegrityFeeHook).creationCode,
                abi.encode(
                    manager,
                    address(this),
                    LBP_STRATEGY,
                    LP_FEE,
                    TICK_SPACING
                )
            );

        (
            bytes32 salt,
            address predicted
        ) =
            _mineHookAddress(
                address(factory),
                keccak256(initCode)
            );

        address deployed =
            factory.deploy(
                salt,
                initCode
            );

        assertEq(
            deployed,
            predicted
        );

        hook =
            TensegrityFeeHook(
                deployed
            );

        vault =
            hook.feeVault();

        assertEq(
            uint256(
                uint160(deployed) &
                ALL_HOOK_MASK
            ),
            uint256(
                REQUIRED_HOOK_MASK
            )
        );

        assertTrue(
            hook.isPermissionedAddress()
        );

        // ----------------------------------------------------
        // REAL TNSG/USDG POOL KEY
        // ----------------------------------------------------

        key =
            PoolKey({
                currency0: Currency.wrap(USDG),
                currency1: Currency.wrap(TNSG),
                fee: LP_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(deployed)
            });

        PoolId poolId =
            key.toId();

        (
            uint160 sqrtBefore,
            ,
            ,
        ) =
            manager.getSlot0(
                poolId
            );

        assertEq(
            sqrtBefore,
            0
        );

        // These are the material predicates used by the
        // Liquidity Launchpad validation path.
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

        assertEq(
            hook.authorized(),
            LBP_STRATEGY
        );

        assertTrue(
            IHooks(address(hook))
                .isValidHookAddress(
                    LP_FEE
                )
        );

        assertTrue(
            IHooks(address(hook))
                .hasPermission(
                    Hooks.BEFORE_INITIALIZE_FLAG
                )
        );

        // The live LBPStrategy is the only permitted initializer.
        vm.prank(
            LBP_STRATEGY
        );

        manager.initialize(
            key,
            SQRT_PRICE_1_1
        );

        (
            uint160 sqrtAfter,
            ,
            uint24 protocolFee,
            uint24 lpFee
        ) =
            manager.getSlot0(
                poolId
            );

        assertEq(
            sqrtAfter,
            SQRT_PRICE_1_1
        );

        assertEq(
            protocolFee,
            0
        );

        assertEq(
            lpFee,
            LP_FEE
        );

        // ----------------------------------------------------
        // REAL v4 TEST ROUTERS / REAL unlock accounting
        // ----------------------------------------------------

        liquidityRouter =
            new PoolModifyLiquidityTest(
                manager
            );

        swapRouter =
            new PoolSwapTest(
                manager
            );

        TensegrityIntegrationERC20(USDG).approve(
            address(liquidityRouter),
            type(uint256).max
        );

        TensegrityIntegrationERC20(TNSG).approve(
            address(liquidityRouter),
            type(uint256).max
        );

        TensegrityIntegrationERC20(USDG).approve(
            address(swapRouter),
            type(uint256).max
        );

        TensegrityIntegrationERC20(TNSG).approve(
            address(swapRouter),
            type(uint256).max
        );

        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:
                    TickMath.minUsableTick(
                        TICK_SPACING
                    ),
                tickUpper:
                    TickMath.maxUsableTick(
                        TICK_SPACING
                    ),
                liquidityDelta:
                    INITIAL_LIQUIDITY,
                salt:
                    bytes32(0)
            }),
            ""
        );

        assertFalse(
            manager.isUnlocked()
        );

        assertEq(
            manager.getNonzeroDeltaCount(),
            0
        );
    }

    // ========================================================
    // CREATE2 MINER
    // ========================================================

    function _mineHookAddress(
        address deployer,
        bytes32 initCodeHash
    )
        private
        pure
        returns (
            bytes32 salt,
            address predicted
        )
    {
        for (
            uint256 i = 0;
            i < 500_000;
            ++i
        ) {
            salt =
                bytes32(i);

            predicted =
                address(
                    uint160(
                        uint256(
                            keccak256(
                                abi.encodePacked(
                                    hex"ff",
                                    deployer,
                                    salt,
                                    initCodeHash
                                )
                            )
                        )
                    )
                );

            if (
                (
                    uint160(predicted) &
                    ALL_HOOK_MASK
                ) ==
                REQUIRED_HOOK_MASK
            ) {
                return (
                    salt,
                    predicted
                );
            }
        }

        revert(
            "NO_0x20CC_SALT"
        );
    }

    // ========================================================
    // REAL SWAP / ACCOUNTING HELPER
    // ========================================================

    function _executeSwap(
        bool zeroForOne,
        int256 amountSpecified
    )
        private
        returns (
            BalanceDelta delta,
            uint256 hookFee
        )
    {
        uint256 vaultBefore =
            TensegrityIntegrationERC20(USDG)
                .balanceOf(
                    address(vault)
                );

        uint160 sqrtPriceLimitX96 =
            zeroForOne
                ? SQRT_PRICE_1_1 / 2
                : SQRT_PRICE_1_1 * 2;

        delta =
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne:
                        zeroForOne,
                    amountSpecified:
                        amountSpecified,
                    sqrtPriceLimitX96:
                        sqrtPriceLimitX96
                }),
                PoolSwapTest.TestSettings({
                    takeClaims:
                        false,
                    settleUsingBurn:
                        false
                }),
                ""
            );

        uint256 vaultAfter =
            TensegrityIntegrationERC20(USDG)
                .balanceOf(
                    address(vault)
                );

        hookFee =
            vaultAfter -
            vaultBefore;

        assertGt(
            hookFee,
            0
        );

        // The physical token backing and Vault accounting
        // must agree after the actual PoolManager transaction.
        assertEq(
            vaultAfter,
            vault.accountedOutstanding()
        );

        (
            uint256 epochTotal,
            uint256 holderAccrued,
            uint256 developmentAccrued,
            ,
            ,
        ) =
            vault.getEpochAccounting(1);

        assertEq(
            epochTotal,
            hookFee
        );

        assertEq(
            developmentAccrued,
            hookFee / 13
        );

        assertEq(
            holderAccrued +
                developmentAccrued,
            hookFee
        );

        // unlock() itself reverts on outstanding deltas.
        // These checks prove the post-return transient state too.
        assertFalse(
            manager.isUnlocked()
        );

        assertEq(
            manager.getNonzeroDeltaCount(),
            0
        );

        assertEq(
            manager.currencyDelta(
                address(hook),
                Currency.wrap(USDG)
            ),
            0
        );

        assertEq(
            manager.currencyDelta(
                address(swapRouter),
                Currency.wrap(USDG)
            ),
            0
        );

        assertEq(
            manager.currencyDelta(
                address(swapRouter),
                Currency.wrap(TNSG)
            ),
            0
        );
    }

    // ========================================================
    // INTEGRATION TESTS
    // ========================================================

    function testRealPoolCCAInitializerAndLpFee()
        public
        view
    {
        (
            uint160 sqrtPriceX96,
            ,
            uint24 protocolFee,
            uint24 lpFee
        ) =
            manager.getSlot0(
                key.toId()
            );

        assertEq(
            sqrtPriceX96,
            SQRT_PRICE_1_1
        );

        assertEq(
            protocolFee,
            0
        );

        // v4 fee units are millionths:
        // 2,500 = 0.25% = 25 bps.
        assertEq(
            lpFee,
            2_500
        );

        assertEq(
            uint256(
                uint160(address(hook)) &
                ALL_HOOK_MASK
            ),
            uint256(
                0x20CC
            )
        );

        assertEq(
            hook.authorized(),
            LBP_STRATEGY
        );
    }

    function testRealBuyExactInput() public {
        uint256 grossQuote =
            100_000_000;

        (
            BalanceDelta delta,
            uint256 hookFee
        ) =
            _executeSwap(
                true,
                -int256(grossQuote)
            );

        assertEq(
            _negative(
                delta.amount0()
            ),
            grossQuote
        );

        assertGt(
            _positive(
                delta.amount1()
            ),
            0
        );

        assertEq(
            hookFee,
            3_250_000
        );
    }

    function testRealBuyExactOutput() public {
        uint256 requestedTnsg =
            100_000_000;

        (
            BalanceDelta delta,
            uint256 hookFee
        ) =
            _executeSwap(
                true,
                int256(requestedTnsg)
            );

        assertEq(
            _positive(
                delta.amount1()
            ),
            requestedTnsg
        );

        uint256 grossQuote =
            _negative(
                delta.amount0()
            );

        uint256 poolQuote =
            grossQuote -
            hookFee;

        assertEq(
            grossQuote,
            FullMath.mulDivRoundingUp(
                poolQuote,
                10_000,
                9_675
            )
        );
    }

    function testRealSellExactInput() public {
        uint256 tnsgInput =
            100_000_000;

        (
            BalanceDelta delta,
            uint256 hookFee
        ) =
            _executeSwap(
                false,
                -int256(tnsgInput)
            );

        assertEq(
            _negative(
                delta.amount1()
            ),
            tnsgInput
        );

        uint256 netQuote =
            _positive(
                delta.amount0()
            );

        uint256 grossQuote =
            netQuote +
            hookFee;

        assertEq(
            hookFee,
            FullMath.mulDiv(
                grossQuote,
                325,
                10_000
            )
        );
    }

    function testRealSellExactOutput() public {
        uint256 netQuote =
            100_000_000;

        (
            BalanceDelta delta,
            uint256 hookFee
        ) =
            _executeSwap(
                false,
                int256(netQuote)
            );

        assertEq(
            _positive(
                delta.amount0()
            ),
            netQuote
        );

        uint256 grossQuote =
            netQuote +
            hookFee;

        assertEq(
            grossQuote,
            FullMath.mulDivRoundingUp(
                netQuote,
                10_000,
                9_675
            )
        );

        assertEq(
            hookFee,
            3_359_174
        );
    }

    function _positive(
        int128 amount
    )
        private
        pure
        returns (uint256)
    {
        require(
            amount > 0,
            "EXPECTED_POSITIVE"
        );

        return uint256(
            uint128(amount)
        );
    }

    function _negative(
        int128 amount
    )
        private
        pure
        returns (uint256)
    {
        require(
            amount < 0,
            "EXPECTED_NEGATIVE"
        );

        return uint256(
            -int256(amount)
        );
    }
}
