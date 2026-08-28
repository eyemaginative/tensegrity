// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ITensegrityBridgeAdapter
} from "./TensegritySettlementExecutor.sol";

import {
    TensegrityRelayOrderV1Hasher
} from "./TensegrityRelayOrderV1Hasher.sol";

interface ITensegrityRelayERC20 {
    function balanceOf(address account)
        external
        view
        returns (uint256);

    function allowance(
        address owner,
        address spender
    )
        external
        view
        returns (uint256);

    function approve(
        address spender,
        uint256 amount
    )
        external
        returns (bool);
}

interface ITensegrityRelayDepository {
    function depositErc20(
        address depositor,
        address token,
        uint256 amount,
        bytes32 id
    )
        external;
}

/// @title TensegrityRelayBridgeAdapter
/// @notice Immutable, permissionless Relay execution boundary for
///         staged Tensegrity USDG settlements.
///
/// SettlementExecutor acceptance is synchronous and atomic.
/// Relay execution is intentionally asynchronous:
///
/// FeeVault -> SettlementExecutor -> this adapter (staged USDG)
///                                  -> validated Relay order
///                                  -> Relay Depository
///                                  -> Base canonical USDC
///
/// No arbitrary call surface exists. No owner/admin exists.
contract TensegrityRelayBridgeAdapter
    is ITensegrityBridgeAdapter
{
    address public constant USDG =
        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address public constant BASE_USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint256 public constant BPS_DENOMINATOR =
        10_000;

    uint256 public constant MAX_QUOTE_GAP_BPS =
        50;

    uint256 public constant MIN_OUTPUT_BPS =
        9_900;

    uint256 public constant MAX_ORDER_TTL =
        8 days;

    bytes32 private constant V1_KEY =
        keccak256("v1");

    bytes32 private constant ROBINHOOD_KEY =
        keccak256("robinhood");

    bytes32 private constant ROBINHOOD_ID_KEY =
        keccak256("4663");

    bytes32 private constant BASE_KEY =
        keccak256("base");

    bytes32 private constant BASE_ID_KEY =
        keccak256("8453");

    uint256 private constant SECP256K1_HALF_N =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    address public immutable SETTLEMENT_EXECUTOR;
    address public immutable BASE_RECEIVER;
    address public immutable RELAY_DEPOSITORY;
    address public immutable RELAY_SOLVER;
    address public immutable RELAY_ROUTER;

    uint256 private _entered;

    struct SettlementRecord {
        bytes32 settlementId;
        address feeVault;
        uint64 epochId;
        uint64 sequence;
        uint64 acceptedIndex;
        uint256 amount;
        uint256 holderAmount;
        uint256 developmentAmount;
    }

    struct CumulativeTotals {
        uint256 amount;
        uint256 holderAmount;
        uint256 developmentAmount;
    }

    mapping(bytes32 bridgeReference => SettlementRecord record)
        private _settlements;

    mapping(bytes32 settlementId => bytes32 bridgeReference)
        private _settlementReferences;

    mapping(uint64 acceptedIndex => CumulativeTotals totals)
        private _cumulative;

    mapping(bytes32 orderId => bool used)
        public orderUsed;

    uint64 public acceptedSettlementCount;
    uint64 public bridgedSettlementCount;
    uint64 public relayBatchCount;

    uint256 public totalAcceptedAmount;
    uint256 public totalAcceptedHolder;
    uint256 public totalAcceptedDevelopment;

    uint256 public totalBridgedAmount;
    uint256 public totalBridgedHolder;
    uint256 public totalBridgedDevelopment;

    error ZeroAddress();
    error DepositoryNotContract();
    error OnlySettlementExecutor();
    error InvalidSettlement();
    error DuplicateSettlement();
    error SettlementBackingMismatch(
        uint256 required,
        uint256 actual
    );
    error InvalidBatchBoundary();
    error InvalidOrderVersion();
    error InvalidSolver();
    error InvalidInput();
    error InvalidRefund();
    error InvalidOutput();
    error InvalidDeadline();
    error UnexpectedDestinationCalls();
    error UnexpectedOrderFees();
    error UnexpectedRelayRouter();
    error QuoteGapTooWide();
    error MinimumOutputTooLow();
    error InvalidOrderSignature();
    error OrderAlreadyUsed();
    error ResidualAllowance(uint256 allowance);
    error TokenApprovalFailed();
    error DepositBalanceMismatch(
        uint256 expected,
        uint256 actual
    );
    error ReentrantExecution();

    event SettlementAccepted(
        bytes32 indexed settlementId,
        bytes32 indexed bridgeReference,
        uint64 indexed acceptedIndex,
        address feeVault,
        uint64 epochId,
        uint64 sequence,
        uint256 amount,
        uint256 holderAmount,
        uint256 developmentAmount
    );

    event RelayBatchExecuted(
        bytes32 indexed orderId,
        uint64 indexed batchId,
        uint64 indexed throughSettlement,
        uint64 fromSettlement,
        uint256 amount,
        uint256 holderAmount,
        uint256 developmentAmount,
        uint256 minimumBaseUsdc,
        uint256 expectedBaseUsdc
    );

    constructor(
        address settlementExecutor,
        address baseReceiver,
        address relayDepository,
        address relaySolver,
        address relayRouter
    ) {
        if (
            settlementExecutor == address(0) ||
            baseReceiver == address(0) ||
            relayDepository == address(0) ||
            relaySolver == address(0) ||
            relayRouter == address(0)
        ) {
            revert ZeroAddress();
        }

        if (relayDepository.code.length == 0) {
            revert DepositoryNotContract();
        }

        SETTLEMENT_EXECUTOR =
            settlementExecutor;

        BASE_RECEIVER =
            baseReceiver;

        RELAY_DEPOSITORY =
            relayDepository;

        RELAY_SOLVER =
            relaySolver;

        RELAY_ROUTER =
            relayRouter;

        _entered =
            1;
    }

    modifier nonReentrant() {
        if (_entered != 1) {
            revert ReentrantExecution();
        }

        _entered =
            2;

        _;

        _entered =
            1;
    }

    /// @notice Called only by the immutable expected SettlementExecutor.
    /// The corresponding USDG must already have been transferred here.
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
        returns (bytes32 bridgeReference)
    {
        if (msg.sender != SETTLEMENT_EXECUTOR) {
            revert OnlySettlementExecutor();
        }

        if (
            settlementId == bytes32(0) ||
            feeVault == address(0) ||
            amount == 0 ||
            holderAmount + developmentAmount != amount
        ) {
            revert InvalidSettlement();
        }

        if (
            _settlementReferences[settlementId] !=
            bytes32(0)
        ) {
            revert DuplicateSettlement();
        }

        uint256 stagedBefore =
            totalAcceptedAmount -
            totalBridgedAmount;

        uint256 requiredBacking =
            stagedBefore +
            amount;

        uint256 actualBalance =
            ITensegrityRelayERC20(USDG)
                .balanceOf(
                    address(this)
                );

        if (actualBalance < requiredBacking) {
            revert SettlementBackingMismatch(
                requiredBacking,
                actualBalance
            );
        }

        uint64 acceptedIndex =
            acceptedSettlementCount + 1;

        bridgeReference =
            keccak256(
                abi.encode(
                    "TNSG_RELAY_SETTLEMENT_V1",
                    block.chainid,
                    address(this),
                    settlementId
                )
            );

        if (
            bridgeReference == bytes32(0) ||
            _settlements[bridgeReference]
                .acceptedIndex != 0
        ) {
            revert DuplicateSettlement();
        }

        uint256 newAcceptedAmount =
            totalAcceptedAmount +
            amount;

        uint256 newAcceptedHolder =
            totalAcceptedHolder +
            holderAmount;

        uint256 newAcceptedDevelopment =
            totalAcceptedDevelopment +
            developmentAmount;

        acceptedSettlementCount =
            acceptedIndex;

        totalAcceptedAmount =
            newAcceptedAmount;

        totalAcceptedHolder =
            newAcceptedHolder;

        totalAcceptedDevelopment =
            newAcceptedDevelopment;

        _cumulative[acceptedIndex] =
            CumulativeTotals({
                amount:
                    newAcceptedAmount,
                holderAmount:
                    newAcceptedHolder,
                developmentAmount:
                    newAcceptedDevelopment
            });

        _settlements[bridgeReference] =
            SettlementRecord({
                settlementId:
                    settlementId,
                feeVault:
                    feeVault,
                epochId:
                    epochId,
                sequence:
                    sequence,
                acceptedIndex:
                    acceptedIndex,
                amount:
                    amount,
                holderAmount:
                    holderAmount,
                developmentAmount:
                    developmentAmount
            });

        _settlementReferences[settlementId] =
            bridgeReference;

        emit SettlementAccepted(
            settlementId,
            bridgeReference,
            acceptedIndex,
            feeVault,
            epochId,
            sequence,
            amount,
            holderAmount,
            developmentAmount
        );
    }

    /// @notice Returns the exact currently-unbridged cumulative prefix ending
    /// at throughSettlement. This makes Relay quoting race-resistant:
    /// settlements accepted after the selected index do not invalidate it.
    function previewBatch(
        uint64 throughSettlement
    )
        public
        view
        returns (
            uint64 fromSettlement,
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        )
    {
        uint64 bridgedThrough =
            bridgedSettlementCount;

        if (
            throughSettlement <= bridgedThrough ||
            throughSettlement > acceptedSettlementCount
        ) {
            revert InvalidBatchBoundary();
        }

        CumulativeTotals storage end =
            _cumulative[throughSettlement];

        if (bridgedThrough == 0) {
            fromSettlement =
                1;

            amount =
                end.amount;

            holderAmount =
                end.holderAmount;

            developmentAmount =
                end.developmentAmount;
        }
        else {
            CumulativeTotals storage start =
                _cumulative[bridgedThrough];

            fromSettlement =
                bridgedThrough + 1;

            amount =
                end.amount -
                start.amount;

            holderAmount =
                end.holderAmount -
                start.holderAmount;

            developmentAmount =
                end.developmentAmount -
                start.developmentAmount;
        }
    }

    /// @notice Permissionless execution of one already-accepted cumulative
    /// settlement prefix using a solver-signed Relay Order v1.
    function executeRelay(
        uint64 throughSettlement,
        TensegrityRelayOrderV1Hasher.Order calldata order,
        bytes calldata orderSignature
    )
        external
        nonReentrant
        returns (bytes32 orderId)
    {
        (
            uint64 fromSettlement,
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        ) =
            previewBatch(
                throughSettlement
            );

        uint256 minimumBaseUsdc;
        uint256 expectedBaseUsdc;

        (
            orderId,
            minimumBaseUsdc,
            expectedBaseUsdc
        ) =
            _validateOrder(
                order,
                orderSignature,
                amount
            );

        if (orderUsed[orderId]) {
            revert OrderAlreadyUsed();
        }

        uint256 balanceBefore =
            ITensegrityRelayERC20(USDG)
                .balanceOf(
                    address(this)
                );

        uint256 allStaged =
            totalAcceptedAmount -
            totalBridgedAmount;

        if (balanceBefore < allStaged) {
            revert SettlementBackingMismatch(
                allStaged,
                balanceBefore
            );
        }

        CumulativeTotals storage bridgedTotals =
            _cumulative[
                throughSettlement
            ];

        orderUsed[orderId] =
            true;

        bridgedSettlementCount =
            throughSettlement;

        totalBridgedAmount =
            bridgedTotals.amount;

        totalBridgedHolder =
            bridgedTotals.holderAmount;

        totalBridgedDevelopment =
            bridgedTotals.developmentAmount;

        relayBatchCount +=
            1;

        _approveExact(
            amount
        );

        ITensegrityRelayDepository(
            RELAY_DEPOSITORY
        ).depositErc20(
            address(this),
            USDG,
            amount,
            orderId
        );

        uint256 allowanceAfter =
            ITensegrityRelayERC20(USDG)
                .allowance(
                    address(this),
                    RELAY_DEPOSITORY
                );

        if (allowanceAfter != 0) {
            revert ResidualAllowance(
                allowanceAfter
            );
        }

        uint256 balanceAfter =
            ITensegrityRelayERC20(USDG)
                .balanceOf(
                    address(this)
                );

        uint256 expectedAfter =
            balanceBefore -
            amount;

        if (balanceAfter != expectedAfter) {
            revert DepositBalanceMismatch(
                expectedAfter,
                balanceAfter
            );
        }

        emit RelayBatchExecuted(
            orderId,
            relayBatchCount,
            throughSettlement,
            fromSettlement,
            amount,
            holderAmount,
            developmentAmount,
            minimumBaseUsdc,
            expectedBaseUsdc
        );
    }

    function hashOrder(
        TensegrityRelayOrderV1Hasher.Order calldata order
    )
        external
        pure
        returns (bytes32)
    {
        return
            TensegrityRelayOrderV1Hasher.hash(
                order
            );
    }

    function stagedTotals()
        external
        view
        returns (
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        )
    {
        amount =
            totalAcceptedAmount -
            totalBridgedAmount;

        holderAmount =
            totalAcceptedHolder -
            totalBridgedHolder;

        developmentAmount =
            totalAcceptedDevelopment -
            totalBridgedDevelopment;
    }

    function surplus()
        external
        view
        returns (uint256)
    {
        uint256 balance =
            ITensegrityRelayERC20(USDG)
                .balanceOf(
                    address(this)
                );

        uint256 staged =
            totalAcceptedAmount -
            totalBridgedAmount;

        if (balance <= staged) {
            return 0;
        }

        return
            balance -
            staged;
    }

    function getSettlement(
        bytes32 bridgeReference
    )
        external
        view
        returns (
            bytes32 settlementId,
            address feeVault,
            uint64 epochId,
            uint64 sequence,
            uint64 acceptedIndex,
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount,
            bool bridged
        )
    {
        SettlementRecord storage record =
            _settlements[
                bridgeReference
            ];

        settlementId =
            record.settlementId;

        feeVault =
            record.feeVault;

        epochId =
            record.epochId;

        sequence =
            record.sequence;

        acceptedIndex =
            record.acceptedIndex;

        amount =
            record.amount;

        holderAmount =
            record.holderAmount;

        developmentAmount =
            record.developmentAmount;

        bridged =
            acceptedIndex != 0 &&
            acceptedIndex <=
                bridgedSettlementCount;
    }

    function bridgeReferenceFor(
        bytes32 settlementId
    )
        external
        view
        returns (bytes32)
    {
        return
            _settlementReferences[
                settlementId
            ];
    }

    function _validateOrder(
        TensegrityRelayOrderV1Hasher.Order calldata order,
        bytes calldata orderSignature,
        uint256 inputAmount
    )
        private
        view
        returns (
            bytes32 orderId,
            uint256 minimumBaseUsdc,
            uint256 expectedBaseUsdc
        )
    {
        if (
            keccak256(bytes(order.version)) !=
            V1_KEY
        ) {
            revert InvalidOrderVersion();
        }

        if (
            !_isBaseChain(
                order.solverChainId
            ) ||
            order.solver !=
                RELAY_SOLVER
        ) {
            revert InvalidSolver();
        }

        if (order.inputs.length != 1) {
            revert InvalidInput();
        }

        TensegrityRelayOrderV1Hasher.Input
            calldata input =
                order.inputs[0];

        if (
            !_isRobinhoodChain(
                input.payment.chainId
            ) ||
            _asAddress(
                input.payment.currency
            ) != USDG ||
            input.payment.amount !=
                inputAmount ||
            input.payment.weight != 1
        ) {
            revert InvalidInput();
        }

        _validateRefunds(
            input.refunds
        );

        if (
            !_isBaseChain(
                order.output.chainId
            )
        ) {
            revert InvalidOutput();
        }

        uint256 outputDeadline =
            uint256(
                order.output.deadline
            );

        if (
            outputDeadline <=
                block.timestamp ||
            outputDeadline >
                block.timestamp +
                    MAX_ORDER_TTL
        ) {
            revert InvalidDeadline();
        }

        if (
            order.output.payments.length != 1
        ) {
            revert InvalidOutput();
        }

        if (
            order.output.calls.length != 0
        ) {
            revert UnexpectedDestinationCalls();
        }

        if (order.fees.length != 0) {
            revert UnexpectedOrderFees();
        }

        if (
            _routerFromExtraData(
                order.output.extraData
            ) != RELAY_ROUTER
        ) {
            revert UnexpectedRelayRouter();
        }

        TensegrityRelayOrderV1Hasher.OutputPayment
            calldata payment =
                order.output.payments[0];

        if (
            _asAddress(
                payment.recipient
            ) != BASE_RECEIVER ||
            _asAddress(
                payment.currency
            ) != BASE_USDC
        ) {
            revert InvalidOutput();
        }

        minimumBaseUsdc =
            payment.minimumAmount;

        expectedBaseUsdc =
            payment.expectedAmount;

        if (
            minimumBaseUsdc == 0 ||
            expectedBaseUsdc == 0 ||
            minimumBaseUsdc >
                expectedBaseUsdc
        ) {
            revert InvalidOutput();
        }

        uint256 quoteGapFloor =
            _ceilBps(
                expectedBaseUsdc,
                BPS_DENOMINATOR -
                    MAX_QUOTE_GAP_BPS
            );

        if (
            minimumBaseUsdc <
            quoteGapFloor
        ) {
            revert QuoteGapTooWide();
        }

        uint256 totalLossFloor =
            _ceilBps(
                inputAmount,
                MIN_OUTPUT_BPS
            );

        if (
            minimumBaseUsdc <
            totalLossFloor
        ) {
            revert MinimumOutputTooLow();
        }

        orderId =
            TensegrityRelayOrderV1Hasher
                .hash(
                    order
                );

        _verifySignature(
            orderId,
            orderSignature
        );
    }

    function _validateRefunds(
        TensegrityRelayOrderV1Hasher.InputRefund[]
            calldata refunds
    )
        private
        view
    {
        if (
            refunds.length < 2 ||
            refunds.length > 4
        ) {
            revert InvalidRefund();
        }

        bool hasRobinhoodRefund;
        bool hasBaseRefund;

        for (
            uint256 i;
            i < refunds.length;
            ++i
        ) {
            TensegrityRelayOrderV1Hasher.InputRefund
                calldata refund =
                    refunds[i];

            uint256 deadline =
                uint256(
                    refund.deadline
                );

            if (
                deadline <= block.timestamp ||
                deadline >
                    block.timestamp +
                        MAX_ORDER_TTL
            ) {
                revert InvalidDeadline();
            }

            if (
                _routerFromExtraData(
                    refund.extraData
                ) != RELAY_ROUTER
            ) {
                revert UnexpectedRelayRouter();
            }

            address recipient =
                _asAddress(
                    refund.recipient
                );

            address currency =
                _asAddress(
                    refund.currency
                );

            if (
                _isRobinhoodChain(
                    refund.chainId
                ) &&
                currency == USDG &&
                recipient == address(this)
            ) {
                hasRobinhoodRefund =
                    true;

                continue;
            }

            if (
                _isBaseChain(
                    refund.chainId
                ) &&
                currency == BASE_USDC &&
                recipient == BASE_RECEIVER
            ) {
                hasBaseRefund =
                    true;

                continue;
            }

            revert InvalidRefund();
        }

        if (
            !hasRobinhoodRefund ||
            !hasBaseRefund
        ) {
            revert InvalidRefund();
        }
    }

    function _verifySignature(
        bytes32 orderId,
        bytes calldata signature
    )
        private
        view
    {
        if (signature.length != 65) {
            revert InvalidOrderSignature();
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r :=
                calldataload(
                    signature.offset
                )

            s :=
                calldataload(
                    add(
                        signature.offset,
                        32
                    )
                )

            v :=
                byte(
                    0,
                    calldataload(
                        add(
                            signature.offset,
                            64
                        )
                    )
                )
        }

        if (
            uint256(s) >
                SECP256K1_HALF_N ||
            (v != 27 && v != 28)
        ) {
            revert InvalidOrderSignature();
        }

        bytes32 digest =
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    orderId
                )
            );

        address recovered =
            ecrecover(
                digest,
                v,
                r,
                s
            );

        if (
            recovered == address(0) ||
            recovered != RELAY_SOLVER
        ) {
            revert InvalidOrderSignature();
        }
    }

    function _approveExact(
        uint256 amount
    )
        private
    {
        uint256 current =
            ITensegrityRelayERC20(USDG)
                .allowance(
                    address(this),
                    RELAY_DEPOSITORY
                );

        if (current != 0) {
            revert ResidualAllowance(
                current
            );
        }

        (
            bool success,
            bytes memory returnData
        ) =
            USDG.call(
                abi.encodeWithSelector(
                    ITensegrityRelayERC20
                        .approve
                        .selector,
                    RELAY_DEPOSITORY,
                    amount
                )
            );

        if (!success) {
            revert TokenApprovalFailed();
        }

        if (
            returnData.length != 0 &&
            (
                returnData.length != 32 ||
                !abi.decode(
                    returnData,
                    (bool)
                )
            )
        ) {
            revert TokenApprovalFailed();
        }
    }

    function _ceilBps(
        uint256 amount,
        uint256 bps
    )
        private
        pure
        returns (uint256)
    {
        uint256 quotient =
            amount /
            BPS_DENOMINATOR;

        uint256 remainder =
            amount %
            BPS_DENOMINATOR;

        uint256 result =
            quotient *
            bps;

        uint256 remainderProduct =
            remainder *
            bps;

        if (remainderProduct != 0) {
            result +=
                (
                    remainderProduct +
                    BPS_DENOMINATOR -
                    1
                ) /
                BPS_DENOMINATOR;
        }

        return result;
    }

    function _asAddress(
        bytes calldata value
    )
        private
        pure
        returns (address result)
    {
        if (value.length != 20) {
            revert InvalidOutput();
        }

        assembly {
            result :=
                shr(
                    96,
                    calldataload(
                        value.offset
                    )
                )
        }
    }

    function _routerFromExtraData(
        bytes calldata value
    )
        private
        pure
        returns (address)
    {
        if (value.length != 32) {
            revert UnexpectedRelayRouter();
        }

        bytes32 word;

        assembly {
            word :=
                calldataload(
                    value.offset
                )
        }

        return
            address(
                uint160(
                    uint256(word)
                )
            );
    }

    function _isRobinhoodChain(
        string calldata value
    )
        private
        pure
        returns (bool)
    {
        bytes32 key =
            keccak256(
                bytes(value)
            );

        return
            key == ROBINHOOD_KEY ||
            key == ROBINHOOD_ID_KEY;
    }

    function _isBaseChain(
        string calldata value
    )
        private
        pure
        returns (bool)
    {
        bytes32 key =
            keccak256(
                bytes(value)
            );

        return
            key == BASE_KEY ||
            key == BASE_ID_KEY;
    }
}
