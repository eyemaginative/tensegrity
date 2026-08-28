// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TensegrityFeeVault} from "./TensegrityFeeVault.sol";

/// @notice Exact ERC-165 surface used by Uniswap Liquidity Launchpad.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId)
        external
        view
        returns (bool);
}

/// @notice Exact initialization-gating interface validated by LBPStrategy.
interface IInitializerHook is IERC165 {
    function authorized()
        external
        view
        returns (address);
}

/// @title TensegrityFeeHook
/// @notice USDG-denominated custom-accounting hook for the canonical
///         TNSG/USDG market.
///
/// 300 bps Holder PoW
///  25 bps Development PoW
/// -----------------------
/// 325 bps combined Hook fee
///
/// The Hook does not bridge, buy PoW assets, enumerate holders,
/// distribute rewards, change fees, or hold discretionary admin power.
contract TensegrityFeeHook is IHooks, IInitializerHook {
    using BalanceDeltaLibrary for BalanceDelta;

    address public constant USDG =
        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address public constant TNSG =
        0x6e43d92B4aE9C1093d6EfE42b18375f4B3176DAc;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant HOLDER_POW_FEE_BPS = 300;
    uint256 public constant DEVELOPMENT_POW_FEE_BPS = 25;
    uint256 public constant TOTAL_HOOK_FEE_BPS = 325;
    uint256 public constant NET_BPS = 9_675;

    uint256 public constant MIN_GROSS_QUOTE = 10_000;

    uint256 public constant MAX_INT128 =
        uint256(uint128(type(int128).max));

    uint160 public constant ALL_HOOK_MASK =
        uint160((1 << 14) - 1);

    uint160 public constant REQUIRED_HOOK_MASK =
        uint160(
            (1 << 13) |
            (1 << 7) |
            (1 << 6) |
            (1 << 3) |
            (1 << 2)
        );

    IPoolManager public immutable poolManager;
    TensegrityFeeVault public immutable feeVault;

    address public immutable override authorized;

    uint24 public immutable authorizedLpFee;
    int24 public immutable authorizedTickSpacing;

    enum FeeMode {
        BuyExactInput,
        BuyExactOutput,
        SellExactInput,
        SellExactOutput
    }

    error ZeroAddress();
    error OnlyPoolManager();
    error UnauthorizedPool();
    error HookNotEnabled();
    error QuoteBelowMinimum();
    error QuoteAmountTooLarge();
    error UnexpectedDeltaSign();
    error PartialFill();
    error InvalidLpFee();
    error InvalidTickSpacing();
    error InvalidInitializer(address caller, address expected);

    event TensegrityHookFee(
        uint64 indexed epochId,
        address indexed swapCaller,
        FeeMode indexed mode,
        uint256 grossQuote,
        uint256 netOrPoolQuote,
        uint256 holderPowFee,
        uint256 developmentPowFee,
        uint256 totalHookFee
    );

    constructor(
        IPoolManager manager,
        address settlementExecutor,
        address authorizedInitializer,
        uint24 lpFee,
        int24 tickSpacing
    ) {
        if (
            address(manager) == address(0) ||
            settlementExecutor == address(0) ||
            authorizedInitializer == address(0)
        ) {
            revert ZeroAddress();
        }

        if (lpFee > 1_000_000) {
            revert InvalidLpFee();
        }

        if (tickSpacing <= 0) {
            revert InvalidTickSpacing();
        }

        poolManager =
            manager;

        authorized =
            authorizedInitializer;

        authorizedLpFee =
            lpFee;

        authorizedTickSpacing =
            tickSpacing;

        feeVault =
            new TensegrityFeeVault(
                USDG,
                settlementExecutor
            );
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) {
            revert OnlyPoolManager();
        }
        _;
    }

    /// @notice The exact v4 hook permissions required by the frozen
    ///         four-mode fee specification.
    function getHookPermissions()
        public
        pure
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Production deployment must CREATE2-mine an address whose
    ///         low hook-permission bits equal REQUIRED_HOOK_MASK.
    ///         PoolManager.initialize() independently enforces this.
    function isPermissionedAddress()
        external
        view
        returns (bool)
    {
        return (
            uint160(address(this)) &
            ALL_HOOK_MASK
        ) == REQUIRED_HOOK_MASK;
    }

    /// @notice ERC-165 compatibility required by the Uniswap LBPStrategy.
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override
        returns (bool)
    {
        return
            interfaceId == type(IInitializerHook).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    // ========================================================
    // SWAP HOOKS
    // ========================================================

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (
            bytes4,
            BeforeSwapDelta,
            uint24
        )
    {
        _validatePool(key);

        bool exactInput =
            params.amountSpecified < 0;

        // BUY EXACT INPUT
        // USDG is specified input currency.
        if (
            params.zeroForOne &&
            exactInput
        ) {
            uint256 grossQuote =
                _negativeInt256(
                    params.amountSpecified
                );

            _requireMinimum(grossQuote);
            _requireInt128(grossQuote);

            uint256 feeAmount =
                _feeFromGross(grossQuote);

            uint256 poolQuote =
                grossQuote - feeAmount;

            _collectFee(
                sender,
                FeeMode.BuyExactInput,
                key,
                grossQuote,
                poolQuote,
                feeAmount
            );

            return (
                IHooks.beforeSwap.selector,
                toBeforeSwapDelta(
                    _toInt128(feeAmount),
                    0
                ),
                0
            );
        }

        // SELL EXACT OUTPUT
        // USDG is specified output currency.
        if (
            !params.zeroForOne &&
            !exactInput
        ) {
            uint256 netQuote =
                uint256(
                    params.amountSpecified
                );

            uint256 grossQuote =
                _grossUp(netQuote);

            _requireMinimum(grossQuote);
            _requireInt128(grossQuote);

            uint256 feeAmount =
                grossQuote - netQuote;

            _collectFee(
                sender,
                FeeMode.SellExactOutput,
                key,
                grossQuote,
                netQuote,
                feeAmount
            );

            return (
                IHooks.beforeSwap.selector,
                toBeforeSwapDelta(
                    _toInt128(feeAmount),
                    0
                ),
                0
            );
        }

        // BUY exact-output and SELL exact-input charge afterSwap
        // because USDG is the unspecified currency and the actual
        // execution amount is known there.
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDelta.wrap(0),
            0
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (
            bytes4,
            int128
        )
    {
        _validatePool(key);

        bool exactInput =
            params.amountSpecified < 0;

        // BUY EXACT INPUT
        // Fee was already collected beforeSwap.
        // Reject partial core USDG input so the precharged fee can
        // never be based on an amount the pool did not actually use.
        if (
            params.zeroForOne &&
            exactInput
        ) {
            uint256 grossQuote =
                _negativeInt256(
                    params.amountSpecified
                );

            uint256 feeAmount =
                _feeFromGross(grossQuote);

            uint256 expectedPoolQuote =
                grossQuote - feeAmount;

            uint256 actualPoolQuote =
                _negativeInt128(
                    delta.amount0()
                );

            if (
                actualPoolQuote !=
                expectedPoolQuote
            ) {
                revert PartialFill();
            }

            return (
                IHooks.afterSwap.selector,
                0
            );
        }

        // BUY EXACT OUTPUT
        // USDG is unspecified input currency.
        if (
            params.zeroForOne &&
            !exactInput
        ) {
            uint256 expectedTnsgOutput =
                uint256(
                    params.amountSpecified
                );

            if (
                expectedTnsgOutput >
                MAX_INT128
            ) {
                revert QuoteAmountTooLarge();
            }

            uint256 actualTnsgOutput =
                _positiveInt128(
                    delta.amount1()
                );

            if (
                actualTnsgOutput !=
                expectedTnsgOutput
            ) {
                revert PartialFill();
            }

            uint256 poolQuote =
                _negativeInt128(
                    delta.amount0()
                );

            uint256 grossQuote =
                _grossUp(poolQuote);

            _requireMinimum(grossQuote);
            _requireInt128(grossQuote);

            uint256 feeAmount =
                grossQuote - poolQuote;

            _collectFee(
                sender,
                FeeMode.BuyExactOutput,
                key,
                grossQuote,
                poolQuote,
                feeAmount
            );

            return (
                IHooks.afterSwap.selector,
                _toInt128(feeAmount)
            );
        }

        // SELL EXACT INPUT
        // USDG is unspecified output currency.
        if (
            !params.zeroForOne &&
            exactInput
        ) {
            uint256 grossQuote =
                _positiveInt128(
                    delta.amount0()
                );

            _requireMinimum(grossQuote);

            uint256 feeAmount =
                _feeFromGross(grossQuote);

            uint256 netQuote =
                grossQuote - feeAmount;

            _collectFee(
                sender,
                FeeMode.SellExactInput,
                key,
                grossQuote,
                netQuote,
                feeAmount
            );

            return (
                IHooks.afterSwap.selector,
                _toInt128(feeAmount)
            );
        }

        // SELL EXACT OUTPUT
        // Fee was collected beforeSwap. The core pool was instructed
        // to produce gross USDG; reject any partial quote output.
        uint256 requestedNetQuote =
            uint256(
                params.amountSpecified
            );

        uint256 expectedGrossQuote =
            _grossUp(requestedNetQuote);

        uint256 actualGrossQuote =
            _positiveInt128(
                delta.amount0()
            );

        if (
            actualGrossQuote !=
            expectedGrossQuote
        ) {
            revert PartialFill();
        }

        return (
            IHooks.afterSwap.selector,
            0
        );
    }

    // ========================================================
    // NON-PERMISSIONED CALLBACKS
    // Fail closed if called unexpectedly.
    // ========================================================

    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        _validatePool(key);

        if (sender != authorized) {
            revert InvalidInitializer(
                sender,
                authorized
            );
        }

        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (
            bytes4,
            BalanceDelta
        )
    {
        revert HookNotEnabled();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (
            bytes4,
            BalanceDelta
        )
    {
        revert HookNotEnabled();
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    // ========================================================
    // INTERNAL ACCOUNTING
    // ========================================================

    function _collectFee(
        address sender,
        FeeMode mode,
        PoolKey calldata key,
        uint256 grossQuote,
        uint256 netOrPoolQuote,
        uint256 feeAmount
    )
        private
    {
        if (feeAmount == 0) {
            revert QuoteBelowMinimum();
        }

        // PoolManager.take() debits this Hook's transient USDG
        // accounting and transfers the actual canonical USDG
        // directly to the immutable FeeVault.
        poolManager.take(
            key.currency0,
            address(feeVault),
            feeAmount
        );

        (
            uint64 epochId,
            uint256 holderFee,
            uint256 developmentFee
        ) =
            feeVault.recordFee(
                feeAmount
            );

        emit TensegrityHookFee(
            epochId,
            sender,
            mode,
            grossQuote,
            netOrPoolQuote,
            holderFee,
            developmentFee,
            feeAmount
        );
    }

    function _validatePool(
        PoolKey calldata key
    )
        private
        view
    {
        if (
            Currency.unwrap(key.currency0) != USDG ||
            Currency.unwrap(key.currency1) != TNSG ||
            address(key.hooks) != address(this) ||
            key.fee != authorizedLpFee ||
            key.tickSpacing != authorizedTickSpacing
        ) {
            revert UnauthorizedPool();
        }
    }

    function _feeFromGross(
        uint256 grossQuote
    )
        private
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(
            grossQuote,
            TOTAL_HOOK_FEE_BPS,
            BPS_DENOMINATOR
        );
    }

    function _grossUp(
        uint256 poolOrNetQuote
    )
        private
        pure
        returns (uint256)
    {
        return FullMath.mulDivRoundingUp(
            poolOrNetQuote,
            BPS_DENOMINATOR,
            NET_BPS
        );
    }

    function _requireMinimum(
        uint256 grossQuote
    )
        private
        pure
    {
        if (grossQuote < MIN_GROSS_QUOTE) {
            revert QuoteBelowMinimum();
        }
    }

    function _requireInt128(
        uint256 amount
    )
        private
        pure
    {
        if (amount > MAX_INT128) {
            revert QuoteAmountTooLarge();
        }
    }

    function _toInt128(
        uint256 amount
    )
        private
        pure
        returns (int128)
    {
        _requireInt128(amount);

        return int128(
            int256(amount)
        );
    }

    function _negativeInt256(
        int256 amount
    )
        private
        pure
        returns (uint256)
    {
        if (amount >= 0) {
            revert UnexpectedDeltaSign();
        }

        if (amount == type(int256).min) {
            revert QuoteAmountTooLarge();
        }

        return uint256(-amount);
    }

    function _negativeInt128(
        int128 amount
    )
        private
        pure
        returns (uint256)
    {
        if (amount >= 0) {
            revert UnexpectedDeltaSign();
        }

        return uint256(
            -int256(amount)
        );
    }

    function _positiveInt128(
        int128 amount
    )
        private
        pure
        returns (uint256)
    {
        if (amount <= 0) {
            revert UnexpectedDeltaSign();
        }

        return uint256(
            uint128(amount)
        );
    }
}
