// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal canonical ERC-20 interface required by the FeeVault.
interface ITensegrityFeeVaultERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

/// @title TensegrityFeeVault
/// @notice Holds USDG collected by the Tensegrity FeeHook and maintains
///         deterministic Holder/Development accounting by seven-day epoch.
/// @dev No owner. No arbitrary withdrawal destination. The Hook and
///      settlement executor are immutable.
contract TensegrityFeeVault {
    uint64 public constant EPOCH_LENGTH = 7 days;
    uint256 public constant SPLIT_DENOMINATOR = 13;

    address public immutable USDG;
    address public immutable HOOK;
    address public immutable SETTLEMENT_EXECUTOR;

    bool public epochStarted;
    uint64 public epochZero;
    uint256 public accountedOutstanding;

    struct EpochAccounting {
        uint256 totalHookFees;
        uint256 holderAccrued;
        uint256 developmentAccrued;
        uint256 releasedFees;
        uint256 holderReleased;
        uint256 developmentReleased;
    }

    mapping(uint64 epochId => EpochAccounting accounting) private _epochs;

    error ZeroAddress();
    error OnlyHook();
    error OnlySettlementExecutor();
    error ZeroFee();
    error TimestampOverflow();
    error InsufficientFeeBacking(uint256 actualBalance, uint256 requiredBalance);
    error NothingToRelease();
    error TokenTransferFailed();

    event EpochStarted(uint64 indexed epochId, uint64 epochZero);

    event FeeRecorded(
        uint64 indexed epochId,
        uint256 amount,
        uint256 holderAccruedDelta,
        uint256 developmentAccruedDelta,
        uint256 epochTotal
    );

    event EpochReleased(
        uint64 indexed epochId,
        address indexed settlementExecutor,
        uint256 amount,
        uint256 holderAmount,
        uint256 developmentAmount
    );

    constructor(address usdg, address settlementExecutor) {
        if (usdg == address(0) || settlementExecutor == address(0)) {
            revert ZeroAddress();
        }

        USDG = usdg;
        HOOK = msg.sender;
        SETTLEMENT_EXECUTOR = settlementExecutor;
    }

    modifier onlyHook() {
        if (msg.sender != HOOK) revert OnlyHook();
        _;
    }

    modifier onlySettlementExecutor() {
        if (msg.sender != SETTLEMENT_EXECUTOR) {
            revert OnlySettlementExecutor();
        }
        _;
    }

    /// @notice Returns 0 before the first fee-bearing swap.
    ///         Epoch 1 begins at the first successfully recorded fee.
    function currentEpochId() public view returns (uint64) {
        if (!epochStarted) return 0;

        uint256 elapsed =
            block.timestamp - uint256(epochZero);

        return uint64(
            (elapsed / uint256(EPOCH_LENGTH)) + 1
        );
    }

    /// @notice Called only by the immutable FeeHook after USDG has already
    ///         been transferred into this vault by PoolManager.take().
    ///
    /// Development receives the increase in floor(epochTotal / 13).
    /// Holder accounting receives the remainder, preserving the aggregate
    /// 12/13 : 1/13 split without per-swap rounding leakage.
    function recordFee(uint256 amount)
        external
        onlyHook
        returns (
            uint64 epochId,
            uint256 holderDelta,
            uint256 developmentDelta
        )
    {
        if (amount == 0) revert ZeroFee();

        if (!epochStarted) {
            if (block.timestamp > type(uint64).max) {
                revert TimestampOverflow();
            }

            epochStarted = true;
            epochZero = uint64(block.timestamp);

            emit EpochStarted(1, epochZero);
        }

        epochId = currentEpochId();

        uint256 requiredBalance =
            accountedOutstanding + amount;

        uint256 actualBalance =
            ITensegrityFeeVaultERC20(USDG).balanceOf(
                address(this)
            );

        if (actualBalance < requiredBalance) {
            revert InsufficientFeeBacking(
                actualBalance,
                requiredBalance
            );
        }

        EpochAccounting storage epoch =
            _epochs[epochId];

        uint256 oldTotal =
            epoch.totalHookFees;

        uint256 newTotal =
            oldTotal + amount;

        uint256 oldDevelopment =
            oldTotal / SPLIT_DENOMINATOR;

        uint256 newDevelopment =
            newTotal / SPLIT_DENOMINATOR;

        developmentDelta =
            newDevelopment - oldDevelopment;

        holderDelta =
            amount - developmentDelta;

        epoch.totalHookFees =
            newTotal;

        epoch.holderAccrued +=
            holderDelta;

        epoch.developmentAccrued +=
            developmentDelta;

        accountedOutstanding =
            requiredBalance;

        emit FeeRecorded(
            epochId,
            amount,
            holderDelta,
            developmentDelta,
            newTotal
        );
    }

    /// @notice Releases all currently unreleased USDG for one epoch to the
    ///         immutable settlement executor.
    ///
    /// This may be called multiple times during an active epoch, allowing
    /// threshold/time-triggered PoW acquisition while preserving exact
    /// cumulative 12/13 : 1/13 accounting.
    function releaseAvailable(uint64 epochId)
        external
        onlySettlementExecutor
        returns (
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        )
    {
        EpochAccounting storage epoch =
            _epochs[epochId];

        holderAmount =
            epoch.holderAccrued -
            epoch.holderReleased;

        developmentAmount =
            epoch.developmentAccrued -
            epoch.developmentReleased;

        amount =
            holderAmount +
            developmentAmount;

        if (amount == 0) {
            revert NothingToRelease();
        }

        epoch.releasedFees +=
            amount;

        epoch.holderReleased +=
            holderAmount;

        epoch.developmentReleased +=
            developmentAmount;

        accountedOutstanding -=
            amount;

        _safeTransfer(
            USDG,
            SETTLEMENT_EXECUTOR,
            amount
        );

        emit EpochReleased(
            epochId,
            SETTLEMENT_EXECUTOR,
            amount,
            holderAmount,
            developmentAmount
        );
    }

    function getEpochAccounting(uint64 epochId)
        external
        view
        returns (
            uint256 totalHookFees,
            uint256 holderAccrued,
            uint256 developmentAccrued,
            uint256 releasedFees,
            uint256 holderReleased,
            uint256 developmentReleased
        )
    {
        EpochAccounting storage epoch =
            _epochs[epochId];

        return (
            epoch.totalHookFees,
            epoch.holderAccrued,
            epoch.developmentAccrued,
            epoch.releasedFees,
            epoch.holderReleased,
            epoch.developmentReleased
        );
    }

    function unreleased(uint64 epochId)
        external
        view
        returns (
            uint256 total,
            uint256 holderAmount,
            uint256 developmentAmount
        )
    {
        EpochAccounting storage epoch =
            _epochs[epochId];

        holderAmount =
            epoch.holderAccrued -
            epoch.holderReleased;

        developmentAmount =
            epoch.developmentAccrued -
            epoch.developmentReleased;

        total =
            holderAmount +
            developmentAmount;
    }

    /// @notice ERC-20 sent directly to the Vault outside the Hook accounting
    ///         remains surplus and cannot be released through accounting.
    function surplus() external view returns (uint256) {
        uint256 balance =
            ITensegrityFeeVaultERC20(USDG).balanceOf(
                address(this)
            );

        if (balance <= accountedOutstanding) {
            return 0;
        }

        return balance - accountedOutstanding;
    }

    function _safeTransfer(
        address token,
        address recipient,
        uint256 amount
    )
        private
    {
        (bool success, bytes memory returnData) =
            token.call(
                abi.encodeWithSelector(
                    ITensegrityFeeVaultERC20.transfer.selector,
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
                !abi.decode(returnData, (bool))
            ) {
                revert TokenTransferFailed();
            }
        }
    }
}
