// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITensegritySettlementERC20 {
    function balanceOf(address account)
        external
        view
        returns (uint256);

    function transfer(
        address recipient,
        uint256 amount
    )
        external
        returns (bool);
}

interface ITensegritySettlementFeeVault {
    function USDG()
        external
        view
        returns (address);

    function HOOK()
        external
        view
        returns (address);

    function SETTLEMENT_EXECUTOR()
        external
        view
        returns (address);

    function releaseAvailable(uint64 epochId)
        external
        returns (
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        );
}

interface ITensegritySettlementHook {
    function USDG()
        external
        view
        returns (address);

    function TNSG()
        external
        view
        returns (address);

    function feeVault()
        external
        view
        returns (address);

    function HOLDER_POW_FEE_BPS()
        external
        view
        returns (uint256);

    function DEVELOPMENT_POW_FEE_BPS()
        external
        view
        returns (uint256);

    function TOTAL_HOOK_FEE_BPS()
        external
        view
        returns (uint256);
}

/// @notice Bridge implementation is deliberately external to the
/// SettlementExecutor. Production deployment will use the selected,
/// separately-audited Robinhood → Base adapter.
interface ITensegrityBridgeAdapter {
    function acceptSettlement(
        bytes32 settlementId,
        address feeVault,
        uint64 epochId,
        uint64 sequence,
        uint256 amount,
        uint256 holderAmount,
        uint256 developmentAmount
    )
        external
        returns (bytes32 bridgeReference);
}

/// @title TensegritySettlementExecutor
/// @notice Permissionless settlement layer between the canonical
///         Tensegrity FeeVault and an immutable bridge adapter.
///
/// The executor:
/// - cannot change protocol fees;
/// - cannot change Holder/Development attribution;
/// - has no owner;
/// - has no arbitrary withdrawal path;
/// - routes only canonical USDG;
/// - validates the originating FeeVault and FeeHook;
/// - preserves a deterministic settlement/reconciliation record.
contract TensegritySettlementExecutor {
    address public constant USDG =
        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address public constant TNSG =
        0x6e43d92B4aE9C1093d6EfE42b18375f4B3176DAc;

    uint256 public constant HOLDER_POW_FEE_BPS =
        300;

    uint256 public constant DEVELOPMENT_POW_FEE_BPS =
        25;

    uint256 public constant TOTAL_HOOK_FEE_BPS =
        325;

    address public immutable BRIDGE_ADAPTER;

    uint256 private _entered;

    struct EpochSettlement {
        uint64 settlementCount;
        uint256 totalAmount;
        uint256 holderAmount;
        uint256 developmentAmount;
    }

    struct SettlementRecord {
        address feeVault;
        uint64 epochId;
        uint64 sequence;
        uint256 amount;
        uint256 holderAmount;
        uint256 developmentAmount;
        bytes32 bridgeReference;
    }

    mapping(
        address feeVault =>
            mapping(uint64 epochId => EpochSettlement totals)
    )
        private _epochSettlements;

    mapping(bytes32 settlementId => SettlementRecord record)
        private _settlements;

    error ZeroAddress();
    error BridgeAdapterNotContract();
    error ReentrantSettlement();
    error InvalidFeeVault();
    error InvalidSettlementSplit();
    error SettlementBackingMismatch(
        uint256 expected,
        uint256 actual
    );
    error ExecutorBalanceMismatch(
        uint256 expected,
        uint256 actual
    );
    error TokenTransferFailed();
    error ZeroBridgeReference();

    event SettlementForwarded(
        bytes32 indexed settlementId,
        bytes32 indexed bridgeReference,
        address indexed feeVault,
        uint64 epochId,
        uint64 sequence,
        uint256 amount,
        uint256 holderAmount,
        uint256 developmentAmount
    );

    constructor(address bridgeAdapter) {
        if (bridgeAdapter == address(0)) {
            revert ZeroAddress();
        }

        if (bridgeAdapter.code.length == 0) {
            revert BridgeAdapterNotContract();
        }

        BRIDGE_ADAPTER =
            bridgeAdapter;

        _entered =
            1;
    }

    modifier nonReentrant() {
        if (_entered != 1) {
            revert ReentrantSettlement();
        }

        _entered =
            2;

        _;

        _entered =
            1;
    }

    /// @notice Permissionless trigger.
    ///
    /// The FeeVault itself determines the exact unreleased amount.
    /// Any bridge failure reverts this entire call, including the
    /// FeeVault release, leaving funds safely in the FeeVault.
    function settleEpoch(
        address feeVault,
        uint64 epochId
    )
        external
        nonReentrant
        returns (
            bytes32 settlementId,
            bytes32 bridgeReference,
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        )
    {
        _validateFeeVault(
            feeVault
        );

        uint256 balanceBefore =
            ITensegritySettlementERC20(USDG)
                .balanceOf(
                    address(this)
                );

        (
            amount,
            holderAmount,
            developmentAmount
        ) =
            ITensegritySettlementFeeVault(
                feeVault
            ).releaseAvailable(
                epochId
            );

        if (
            amount == 0 ||
            holderAmount +
                developmentAmount !=
                amount
        ) {
            revert InvalidSettlementSplit();
        }

        uint256 balanceAfterRelease =
            ITensegritySettlementERC20(USDG)
                .balanceOf(
                    address(this)
                );

        uint256 expectedAfterRelease =
            balanceBefore +
            amount;

        if (
            balanceAfterRelease !=
            expectedAfterRelease
        ) {
            revert SettlementBackingMismatch(
                expectedAfterRelease,
                balanceAfterRelease
            );
        }

        EpochSettlement storage totals =
            _epochSettlements[
                feeVault
            ][
                epochId
            ];

        uint64 sequence =
            totals.settlementCount + 1;

        settlementId =
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    feeVault,
                    epochId,
                    sequence,
                    amount,
                    holderAmount,
                    developmentAmount
                )
            );

        _safeTransfer(
            USDG,
            BRIDGE_ADAPTER,
            amount
        );

        bridgeReference =
            ITensegrityBridgeAdapter(
                BRIDGE_ADAPTER
            ).acceptSettlement(
                settlementId,
                feeVault,
                epochId,
                sequence,
                amount,
                holderAmount,
                developmentAmount
            );

        if (bridgeReference == bytes32(0)) {
            revert ZeroBridgeReference();
        }

        uint256 balanceAfterForward =
            ITensegritySettlementERC20(USDG)
                .balanceOf(
                    address(this)
                );

        if (
            balanceAfterForward !=
            balanceBefore
        ) {
            revert ExecutorBalanceMismatch(
                balanceBefore,
                balanceAfterForward
            );
        }

        totals.settlementCount =
            sequence;

        totals.totalAmount +=
            amount;

        totals.holderAmount +=
            holderAmount;

        totals.developmentAmount +=
            developmentAmount;

        _settlements[
            settlementId
        ] =
            SettlementRecord({
                feeVault:
                    feeVault,
                epochId:
                    epochId,
                sequence:
                    sequence,
                amount:
                    amount,
                holderAmount:
                    holderAmount,
                developmentAmount:
                    developmentAmount,
                bridgeReference:
                    bridgeReference
            });

        emit SettlementForwarded(
            settlementId,
            bridgeReference,
            feeVault,
            epochId,
            sequence,
            amount,
            holderAmount,
            developmentAmount
        );
    }

    function getEpochSettlement(
        address feeVault,
        uint64 epochId
    )
        external
        view
        returns (
            uint64 settlementCount,
            uint256 totalAmount,
            uint256 holderAmount,
            uint256 developmentAmount
        )
    {
        EpochSettlement storage totals =
            _epochSettlements[
                feeVault
            ][
                epochId
            ];

        return (
            totals.settlementCount,
            totals.totalAmount,
            totals.holderAmount,
            totals.developmentAmount
        );
    }

    function getSettlement(
        bytes32 settlementId
    )
        external
        view
        returns (
            address feeVault,
            uint64 epochId,
            uint64 sequence,
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount,
            bytes32 bridgeReference
        )
    {
        SettlementRecord storage record =
            _settlements[
                settlementId
            ];

        return (
            record.feeVault,
            record.epochId,
            record.sequence,
            record.amount,
            record.holderAmount,
            record.developmentAmount,
            record.bridgeReference
        );
    }

    /// @notice Directly-sent USDG is not attributed to protocol fees and
    /// cannot be forwarded by settlement accounting.
    function surplus()
        external
        view
        returns (uint256)
    {
        return
            ITensegritySettlementERC20(USDG)
                .balanceOf(
                    address(this)
                );
    }

    function _validateFeeVault(
        address feeVault
    )
        private
        view
    {
        if (feeVault == address(0)) {
            revert InvalidFeeVault();
        }

        address hook;

        try
            ITensegritySettlementFeeVault(
                feeVault
            ).USDG()
        returns (address value) {
            if (value != USDG) {
                revert InvalidFeeVault();
            }
        }
        catch {
            revert InvalidFeeVault();
        }

        try
            ITensegritySettlementFeeVault(
                feeVault
            ).SETTLEMENT_EXECUTOR()
        returns (address value) {
            if (value != address(this)) {
                revert InvalidFeeVault();
            }
        }
        catch {
            revert InvalidFeeVault();
        }

        try
            ITensegritySettlementFeeVault(
                feeVault
            ).HOOK()
        returns (address value) {
            hook =
                value;
        }
        catch {
            revert InvalidFeeVault();
        }

        if (
            hook == address(0) ||
            hook.code.length == 0
        ) {
            revert InvalidFeeVault();
        }

        try
            ITensegritySettlementHook(
                hook
            ).USDG()
        returns (address value) {
            if (value != USDG) {
                revert InvalidFeeVault();
            }
        }
        catch {
            revert InvalidFeeVault();
        }

        try
            ITensegritySettlementHook(
                hook
            ).TNSG()
        returns (address value) {
            if (value != TNSG) {
                revert InvalidFeeVault();
            }
        }
        catch {
            revert InvalidFeeVault();
        }

        try
            ITensegritySettlementHook(
                hook
            ).feeVault()
        returns (address value) {
            if (value != feeVault) {
                revert InvalidFeeVault();
            }
        }
        catch {
            revert InvalidFeeVault();
        }

        try
            ITensegritySettlementHook(
                hook
            ).HOLDER_POW_FEE_BPS()
        returns (uint256 value) {
            if (
                value !=
                HOLDER_POW_FEE_BPS
            ) {
                revert InvalidFeeVault();
            }
        }
        catch {
            revert InvalidFeeVault();
        }

        try
            ITensegritySettlementHook(
                hook
            ).DEVELOPMENT_POW_FEE_BPS()
        returns (uint256 value) {
            if (
                value !=
                DEVELOPMENT_POW_FEE_BPS
            ) {
                revert InvalidFeeVault();
            }
        }
        catch {
            revert InvalidFeeVault();
        }

        try
            ITensegritySettlementHook(
                hook
            ).TOTAL_HOOK_FEE_BPS()
        returns (uint256 value) {
            if (
                value !=
                TOTAL_HOOK_FEE_BPS
            ) {
                revert InvalidFeeVault();
            }
        }
        catch {
            revert InvalidFeeVault();
        }
    }

    function _safeTransfer(
        address token,
        address recipient,
        uint256 amount
    )
        private
    {
        (
            bool success,
            bytes memory returnData
        ) =
            token.call(
                abi.encodeWithSelector(
                    ITensegritySettlementERC20
                        .transfer
                        .selector,
                    recipient,
                    amount
                )
            );

        if (!success) {
            revert TokenTransferFailed();
        }

        if (returnData.length != 0) {
            if (
                returnData.length != 32 ||
                !abi.decode(
                    returnData,
                    (bool)
                )
            ) {
                revert TokenTransferFailed();
            }
        }
    }
}
