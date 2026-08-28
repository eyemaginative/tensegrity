// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITensegrityBaseUSDC {
    function balanceOf(
        address account
    )
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

/// @title TensegrityBaseReceiver
/// @notice Minimal Base-side custody and accounting boundary for canonical
///         USDC delivered by the Tensegrity Robinhood -> Relay route.
///
/// @dev ERC-20 delivery does not invoke this contract, so receipt accounting
///      is intentionally permissionless and does not authenticate msg.sender.
///      This contract does not claim that a balance increase alone proves a
///      particular Relay order. Origin-order and destination-receipt
///      reconciliation is a separate accounting/transparency concern.
///
///      Only canonical Base USDC is accounted or releasable.
///      No owner, admin, arbitrary withdrawal or arbitrary call surface exists.
contract TensegrityBaseReceiver {
    uint256 public constant EXPECTED_CHAIN_ID =
        8453;

    address public constant USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address public immutable ACQUISITION_EXECUTOR;

    uint256 private _entered;

    struct ReceiptRecord {
        uint64 receiptIndex;
        uint64 blockNumber;
        uint64 timestamp;
        uint256 amount;
        uint256 cumulativeReceived;
    }

    struct ReleaseRecord {
        uint64 releaseIndex;
        bytes32 acquisitionReference;
        uint256 amount;
        uint256 cumulativeReleased;
    }

    mapping(bytes32 receiptId => ReceiptRecord record)
        private _receipts;

    mapping(uint64 receiptIndex => bytes32 receiptId)
        public receiptIdAt;

    mapping(bytes32 releaseId => ReleaseRecord record)
        private _releases;

    mapping(uint64 releaseIndex => bytes32 releaseId)
        public releaseIdAt;

    mapping(bytes32 acquisitionReference => bool used)
        public acquisitionReferenceUsed;

    uint64 public receiptCount;
    uint64 public releaseCount;

    uint256 public totalReceived;
    uint256 public totalReleased;

    error WrongChain(uint256 actualChainId);
    error ZeroAcquisitionExecutor();
    error NothingToSync();
    error BalanceInvariant(
        uint256 accounted,
        uint256 actual
    );
    error OnlyAcquisitionExecutor();
    error InvalidRelease();
    error DuplicateAcquisitionReference();
    error InsufficientAccountedUsdc(
        uint256 requested,
        uint256 available
    );
    error TokenTransferFailed();
    error TransferBalanceMismatch(
        uint256 expected,
        uint256 actual
    );
    error ReentrantExecution();
    error NativeAssetRejected();

    event UsdcReceiptCheckpointed(
        bytes32 indexed receiptId,
        uint64 indexed receiptIndex,
        uint256 amount,
        uint256 cumulativeReceived
    );

    event UsdcReleasedToAcquisition(
        bytes32 indexed releaseId,
        bytes32 indexed acquisitionReference,
        uint64 indexed releaseIndex,
        uint256 amount,
        uint256 cumulativeReleased
    );

    constructor(
        address acquisitionExecutor
    ) {
        if (block.chainid != EXPECTED_CHAIN_ID) {
            revert WrongChain(
                block.chainid
            );
        }

        if (
            acquisitionExecutor ==
            address(0)
        ) {
            revert ZeroAcquisitionExecutor();
        }

        ACQUISITION_EXECUTOR =
            acquisitionExecutor;

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

    /// @notice Permissionlessly checkpoints canonical USDC that has arrived
    ///         since the previous checkpoint/release accounting state.
    function sync()
        external
        returns (
            bytes32 receiptId,
            uint256 amount
        )
    {
        uint256 accounted =
            totalReceived -
            totalReleased;

        uint256 actual =
            ITensegrityBaseUSDC(
                USDC
            ).balanceOf(
                address(this)
            );

        if (actual < accounted) {
            revert BalanceInvariant(
                accounted,
                actual
            );
        }

        amount =
            actual -
            accounted;

        if (amount == 0) {
            revert NothingToSync();
        }

        uint64 newReceiptIndex =
            receiptCount + 1;

        uint256 newTotalReceived =
            totalReceived +
            amount;

        receiptId =
            keccak256(
                abi.encode(
                    "TNSG_BASE_USDC_RECEIPT_V1",
                    block.chainid,
                    address(this),
                    newReceiptIndex,
                    amount,
                    newTotalReceived
                )
            );

        receiptCount =
            newReceiptIndex;

        totalReceived =
            newTotalReceived;

        receiptIdAt[
            newReceiptIndex
        ] =
            receiptId;

        _receipts[
            receiptId
        ] =
            ReceiptRecord({
                receiptIndex:
                    newReceiptIndex,
                blockNumber:
                    uint64(
                        block.number
                    ),
                timestamp:
                    uint64(
                        block.timestamp
                    ),
                amount:
                    amount,
                cumulativeReceived:
                    newTotalReceived
            });

        emit UsdcReceiptCheckpointed(
            receiptId,
            newReceiptIndex,
            amount,
            newTotalReceived
        );
    }

    /// @notice Releases only previously-accounted canonical USDC to the
    ///         immutable acquisition executor.
    ///
    /// @dev Unsynced USDC cannot be released. The acquisition reference must
    ///      be unique so downstream acquisition accounting cannot accidentally
    ///      replay the same logical operation.
    function releaseToAcquisition(
        uint256 amount,
        bytes32 acquisitionReference
    )
        external
        nonReentrant
        returns (bytes32 releaseId)
    {
        if (
            msg.sender !=
            ACQUISITION_EXECUTOR
        ) {
            revert OnlyAcquisitionExecutor();
        }

        if (
            amount == 0 ||
            acquisitionReference ==
                bytes32(0)
        ) {
            revert InvalidRelease();
        }

        if (
            acquisitionReferenceUsed[
                acquisitionReference
            ]
        ) {
            revert DuplicateAcquisitionReference();
        }

        uint256 available =
            totalReceived -
            totalReleased;

        if (amount > available) {
            revert InsufficientAccountedUsdc(
                amount,
                available
            );
        }

        uint256 balanceBefore =
            ITensegrityBaseUSDC(
                USDC
            ).balanceOf(
                address(this)
            );

        if (
            balanceBefore <
            available
        ) {
            revert BalanceInvariant(
                available,
                balanceBefore
            );
        }

        uint64 newReleaseIndex =
            releaseCount + 1;

        uint256 newTotalReleased =
            totalReleased +
            amount;

        releaseId =
            keccak256(
                abi.encode(
                    "TNSG_BASE_USDC_RELEASE_V1",
                    block.chainid,
                    address(this),
                    newReleaseIndex,
                    acquisitionReference,
                    amount,
                    newTotalReleased
                )
            );

        acquisitionReferenceUsed[
            acquisitionReference
        ] =
            true;

        releaseCount =
            newReleaseIndex;

        totalReleased =
            newTotalReleased;

        releaseIdAt[
            newReleaseIndex
        ] =
            releaseId;

        _releases[
            releaseId
        ] =
            ReleaseRecord({
                releaseIndex:
                    newReleaseIndex,
                acquisitionReference:
                    acquisitionReference,
                amount:
                    amount,
                cumulativeReleased:
                    newTotalReleased
            });

        bool transferred =
            ITensegrityBaseUSDC(
                USDC
            ).transfer(
                ACQUISITION_EXECUTOR,
                amount
            );

        if (!transferred) {
            revert TokenTransferFailed();
        }

        uint256 balanceAfter =
            ITensegrityBaseUSDC(
                USDC
            ).balanceOf(
                address(this)
            );

        uint256 expectedAfter =
            balanceBefore -
            amount;

        if (
            balanceAfter !=
            expectedAfter
        ) {
            revert TransferBalanceMismatch(
                expectedAfter,
                balanceAfter
            );
        }

        emit UsdcReleasedToAcquisition(
            releaseId,
            acquisitionReference,
            newReleaseIndex,
            amount,
            newTotalReleased
        );
    }

    function availableForAcquisition()
        public
        view
        returns (uint256)
    {
        return
            totalReceived -
            totalReleased;
    }

    function unsyncedUsdc()
        external
        view
        returns (uint256)
    {
        uint256 actual =
            ITensegrityBaseUSDC(
                USDC
            ).balanceOf(
                address(this)
            );

        uint256 accounted =
            availableForAcquisition();

        if (actual <= accounted) {
            return 0;
        }

        return
            actual -
            accounted;
    }

    function getReceipt(
        bytes32 receiptId
    )
        external
        view
        returns (
            uint64 receiptIndex,
            uint64 blockNumber,
            uint64 timestamp,
            uint256 amount,
            uint256 cumulativeReceived
        )
    {
        ReceiptRecord storage record =
            _receipts[
                receiptId
            ];

        receiptIndex =
            record.receiptIndex;

        blockNumber =
            record.blockNumber;

        timestamp =
            record.timestamp;

        amount =
            record.amount;

        cumulativeReceived =
            record.cumulativeReceived;
    }

    function getRelease(
        bytes32 releaseId
    )
        external
        view
        returns (
            uint64 releaseIndex,
            bytes32 acquisitionReference,
            uint256 amount,
            uint256 cumulativeReleased
        )
    {
        ReleaseRecord storage record =
            _releases[
                releaseId
            ];

        releaseIndex =
            record.releaseIndex;

        acquisitionReference =
            record.acquisitionReference;

        amount =
            record.amount;

        cumulativeReleased =
            record.cumulativeReleased;
    }

    receive()
        external
        payable
    {
        revert NativeAssetRejected();
    }

    fallback()
        external
        payable
    {
        revert NativeAssetRejected();
    }
}
