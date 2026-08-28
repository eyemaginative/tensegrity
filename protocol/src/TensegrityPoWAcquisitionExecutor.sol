// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    FullMath
} from "@uniswap/v4-core/src/libraries/FullMath.sol";

interface ITensegrityAcquisitionERC20 {
    function balanceOf(
        address account
    )
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

    function transfer(
        address recipient,
        uint256 amount
    )
        external
        returns (bool);
}

interface ITensegrityAcquisitionBaseReceiver {
    function USDC()
        external
        view
        returns (address);

    function ACQUISITION_EXECUTOR()
        external
        view
        returns (address);

    function releaseToAcquisition(
        uint256 amount,
        bytes32 acquisitionReference
    )
        external
        returns (bytes32 releaseId);
}

interface ITensegrityAcquisitionReserveAccounting {
    function ACQUISITION_EXECUTOR()
        external
        view
        returns (address);

    function recordAcquisition(
        bytes32 acquisitionReference,
        address asset,
        uint256 amount
    )
        external;
}

interface ITensegritySlipstreamRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(
        ExactInputParams calldata params
    )
        external
        payable
        returns (uint256 amountOut);

    function factory()
        external
        view
        returns (address);

    function WETH9()
        external
        view
        returns (address);
}

interface ITensegrityAggregatorV3 {
    function decimals()
        external
        view
        returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title TensegrityPoWAcquisitionExecutor
/// @notice Base-only, permissionless acquisition engine converting
///         accounted protocol USDC into the fixed Tensegrity PoW basket.
///
/// Basket allocation:
///   50% cbBTC
///   25% cbLTC
///   25% cbDOGE
///
/// Acquired assets are immediately divided:
///   Holder Reserve       = 12/13
///   Development Reserve  =  1/13
///
/// There is no arbitrary route, arbitrary calldata, owner, admin,
/// withdrawal or mutable provider configuration.
contract TensegrityPoWAcquisitionExecutor {
    uint256 public constant EXPECTED_CHAIN_ID =
        8453;

    address public constant USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address public constant CBBTC =
        0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address public constant CBLTC =
        0xcb17C9Db87B595717C857a08468793f5bAb6445F;

    address public constant CBDOGE =
        0xcbD06E5A2B0C65597161de254AA074E489dEb510;

    address public constant ROUTER =
        0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;

    address public constant FACTORY =
        0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    address public constant WETH =
        0x4200000000000000000000000000000000000006;

    int24 public constant POW_SECOND_HOP_TICK =
        100;

    uint256 public constant BPS_DENOMINATOR =
        10_000;

    uint256 public constant ORACLE_FLOOR_BPS =
        9_800;

    uint256 public constant HOLDER_DEVELOPMENT_DENOMINATOR =
        13;

    uint256 public constant SEQUENCER_GRACE_PERIOD =
        1 hours;

    uint256 public constant MIN_VOLATILE_MAX_AGE =
        15 minutes;

    uint256 public constant MAX_VOLATILE_MAX_AGE =
        6 hours;

    uint256 public constant MIN_USDC_MAX_AGE =
        1 hours;

    uint256 public constant MAX_USDC_MAX_AGE =
        30 hours;

    ITensegrityAcquisitionBaseReceiver
        public immutable BASE_RECEIVER;

    address public immutable HOLDER_RESERVE;
    address public immutable DEVELOPMENT_RESERVE;

    ITensegrityAggregatorV3
        public immutable USDC_USD_FEED;

    ITensegrityAggregatorV3
        public immutable CBBTC_USD_FEED;

    ITensegrityAggregatorV3
        public immutable LTC_USD_FEED;

    ITensegrityAggregatorV3
        public immutable DOGE_USD_FEED;

    ITensegrityAggregatorV3
        public immutable SEQUENCER_UPTIME_FEED;

    uint256 public immutable VOLATILE_MAX_AGE;
    uint256 public immutable USDC_MAX_AGE;

    uint256 private _entered;

    uint64 public acquisitionCount;

    uint256 public totalUsdcProcessed;

    uint256 public totalCbBtcAcquired;
    uint256 public totalCbLtcAcquired;
    uint256 public totalCbDogeAcquired;

    uint256 public totalHolderCbBtc;
    uint256 public totalHolderCbLtc;
    uint256 public totalHolderCbDoge;

    uint256 public totalDevelopmentCbBtc;
    uint256 public totalDevelopmentCbLtc;
    uint256 public totalDevelopmentCbDoge;

    struct AcquisitionRecord {
        bytes32 acquisitionReference;
        bytes32 receiverReleaseId;
        uint256 usdcAmount;
        uint256 btcUsdcBudget;
        uint256 ltcUsdcBudget;
        uint256 dogeUsdcBudget;
        uint256 cbBtcAcquired;
        uint256 cbLtcAcquired;
        uint256 cbDogeAcquired;
        int24 btcFirstHopTick;
        int24 ltcFirstHopTick;
        int24 dogeFirstHopTick;
    }

    mapping(
        uint64 acquisitionIndex =>
            AcquisitionRecord record
    )
        private _acquisitions;

    error WrongChain(uint256 actualChainId);
    error ZeroAddress();
    error DuplicateReserve();

    error ReserveBindingInvalid(
        address reserve,
        address actualExecutor
    );
    error DependencyNotContract(address dependency);
    error InvalidRouterBinding();
    error InvalidFeedDecimals(
        address feed,
        uint8 decimals
    );
    error InvalidOracleAge();
    error ReceiverBindingInvalid();
    error InvalidAmount();
    error AcquisitionTooSmall();
    error InvalidFirstHopTick();
    error InvalidCallerMinimum();
    error SequencerDown();
    error SequencerGracePeriod();
    error InvalidOracleRound(address feed);
    error InvalidOraclePrice(
        address feed,
        int256 answer
    );
    error StaleOracle(
        address feed,
        uint256 updatedAt
    );
    error FundingBalanceMismatch(
        uint256 expected,
        uint256 actual
    );
    error ExistingAllowance(uint256 allowance);
    error ApprovalFailed();
    error ResidualAllowance(uint256 allowance);
    error RouterOutputMismatch(
        uint256 returnedAmount,
        uint256 balanceDelta
    );
    error OutputBelowMinimum(
        uint256 minimum,
        uint256 actual
    );
    error OutputTooSmall();
    error TokenTransferFailed();
    error TokenTransferMismatch();
    error ResidualAcquisitionUsdc(
        uint256 expected,
        uint256 actual
    );
    error ReentrantExecution();

    event PoWAcquisitionExecuted(
        uint64 indexed acquisitionIndex,
        bytes32 indexed acquisitionReference,
        bytes32 indexed receiverReleaseId,
        uint256 usdcAmount,
        uint256 cbBtcAcquired,
        uint256 cbLtcAcquired,
        uint256 cbDogeAcquired,
        uint256 holderCbBtc,
        uint256 holderCbLtc,
        uint256 holderCbDoge,
        uint256 developmentCbBtc,
        uint256 developmentCbLtc,
        uint256 developmentCbDoge
    );

    constructor(
        address baseReceiver,
        address holderReserve,
        address developmentReserve,
        address usdcUsdFeed,
        address cbBtcUsdFeed,
        address ltcUsdFeed,
        address dogeUsdFeed,
        address sequencerUptimeFeed,
        uint256 volatileMaxAge,
        uint256 usdcMaxAge
    ) {
        if (block.chainid != EXPECTED_CHAIN_ID) {
            revert WrongChain(
                block.chainid
            );
        }

        if (
            baseReceiver == address(0) ||
            holderReserve == address(0) ||
            developmentReserve == address(0) ||
            usdcUsdFeed == address(0) ||
            cbBtcUsdFeed == address(0) ||
            ltcUsdFeed == address(0) ||
            dogeUsdFeed == address(0) ||
            sequencerUptimeFeed == address(0)
        ) {
            revert ZeroAddress();
        }

        if (
            holderReserve ==
            developmentReserve
        ) {
            revert DuplicateReserve();
        }

        _requireContract(
            baseReceiver
        );

        _requireContract(
            holderReserve
        );

        _requireContract(
            developmentReserve
        );

        address holderExecutor =
            ITensegrityAcquisitionReserveAccounting(
                holderReserve
            ).ACQUISITION_EXECUTOR();

        if (
            holderExecutor !=
            address(this)
        ) {
            revert ReserveBindingInvalid(
                holderReserve,
                holderExecutor
            );
        }

        address developmentExecutor =
            ITensegrityAcquisitionReserveAccounting(
                developmentReserve
            ).ACQUISITION_EXECUTOR();

        if (
            developmentExecutor !=
            address(this)
        ) {
            revert ReserveBindingInvalid(
                developmentReserve,
                developmentExecutor
            );
        }

        _requireContract(
            ROUTER
        );

        _requireContract(
            FACTORY
        );

        _requireContract(
            USDC
        );

        _requireContract(
            CBBTC
        );

        _requireContract(
            CBLTC
        );

        _requireContract(
            CBDOGE
        );

        _requireContract(
            usdcUsdFeed
        );

        _requireContract(
            cbBtcUsdFeed
        );

        _requireContract(
            ltcUsdFeed
        );

        _requireContract(
            dogeUsdFeed
        );

        _requireContract(
            sequencerUptimeFeed
        );

        if (
            ITensegritySlipstreamRouter(
                ROUTER
            ).factory() != FACTORY ||
            ITensegritySlipstreamRouter(
                ROUTER
            ).WETH9() != WETH
        ) {
            revert InvalidRouterBinding();
        }

        _requireEightDecimals(
            usdcUsdFeed
        );

        _requireEightDecimals(
            cbBtcUsdFeed
        );

        _requireEightDecimals(
            ltcUsdFeed
        );

        _requireEightDecimals(
            dogeUsdFeed
        );

        if (
            volatileMaxAge <
                MIN_VOLATILE_MAX_AGE ||
            volatileMaxAge >
                MAX_VOLATILE_MAX_AGE ||
            usdcMaxAge <
                MIN_USDC_MAX_AGE ||
            usdcMaxAge >
                MAX_USDC_MAX_AGE
        ) {
            revert InvalidOracleAge();
        }

        BASE_RECEIVER =
            ITensegrityAcquisitionBaseReceiver(
                baseReceiver
            );

        HOLDER_RESERVE =
            holderReserve;

        DEVELOPMENT_RESERVE =
            developmentReserve;

        USDC_USD_FEED =
            ITensegrityAggregatorV3(
                usdcUsdFeed
            );

        CBBTC_USD_FEED =
            ITensegrityAggregatorV3(
                cbBtcUsdFeed
            );

        LTC_USD_FEED =
            ITensegrityAggregatorV3(
                ltcUsdFeed
            );

        DOGE_USD_FEED =
            ITensegrityAggregatorV3(
                dogeUsdFeed
            );

        SEQUENCER_UPTIME_FEED =
            ITensegrityAggregatorV3(
                sequencerUptimeFeed
            );

        VOLATILE_MAX_AGE =
            volatileMaxAge;

        USDC_MAX_AGE =
            usdcMaxAge;

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

    /// @notice Permissionlessly executes a complete three-asset acquisition.
    /// Caller minimums may tighten, but never weaken, the oracle floor.
    function acquire(
        uint256 usdcAmount,
        int24 btcFirstHopTick,
        int24 ltcFirstHopTick,
        int24 dogeFirstHopTick,
        uint256 callerMinCbBtc,
        uint256 callerMinCbLtc,
        uint256 callerMinCbDoge
    )
        external
        nonReentrant
        returns (
            bytes32 acquisitionReference
        )
    {
        if (usdcAmount == 0) {
            revert InvalidAmount();
        }

        if (
            callerMinCbBtc == 0 ||
            callerMinCbLtc == 0 ||
            callerMinCbDoge == 0
        ) {
            revert InvalidCallerMinimum();
        }

        _requireFirstHopTick(
            btcFirstHopTick
        );

        _requireFirstHopTick(
            ltcFirstHopTick
        );

        _requireFirstHopTick(
            dogeFirstHopTick
        );

        _requireReceiverBinding();

        _checkSequencer();

        (
            uint256 btcBudget,
            uint256 ltcBudget,
            uint256 dogeBudget
        ) =
            previewBudgets(
                usdcAmount
            );

        (
            uint256 oracleMinCbBtc,
            uint256 oracleMinCbLtc,
            uint256 oracleMinCbDoge
        ) =
            _oracleMinimums(
                btcBudget,
                ltcBudget,
                dogeBudget
            );

        uint256 minimumCbBtc =
            _max(
                callerMinCbBtc,
                oracleMinCbBtc
            );

        uint256 minimumCbLtc =
            _max(
                callerMinCbLtc,
                oracleMinCbLtc
            );

        uint256 minimumCbDoge =
            _max(
                callerMinCbDoge,
                oracleMinCbDoge
            );

        uint64 nextIndex =
            acquisitionCount + 1;

        uint256 nextTotalUsdc =
            totalUsdcProcessed +
            usdcAmount;

        acquisitionReference =
            keccak256(
                abi.encode(
                    "TNSG_POW_ACQUISITION_V1",
                    block.chainid,
                    address(this),
                    nextIndex,
                    nextTotalUsdc,
                    usdcAmount,
                    btcFirstHopTick,
                    ltcFirstHopTick,
                    dogeFirstHopTick
                )
            );

        uint256 usdcBefore =
            ITensegrityAcquisitionERC20(
                USDC
            ).balanceOf(
                address(this)
            );

        bytes32 receiverReleaseId =
            BASE_RECEIVER
                .releaseToAcquisition(
                    usdcAmount,
                    acquisitionReference
                );

        uint256 usdcAfterRelease =
            ITensegrityAcquisitionERC20(
                USDC
            ).balanceOf(
                address(this)
            );

        uint256 expectedAfterRelease =
            usdcBefore +
            usdcAmount;

        if (
            usdcAfterRelease !=
            expectedAfterRelease
        ) {
            revert FundingBalanceMismatch(
                expectedAfterRelease,
                usdcAfterRelease
            );
        }

        uint256 cbBtcAcquired =
            _swap(
                _btcPath(
                    btcFirstHopTick
                ),
                CBBTC,
                btcBudget,
                minimumCbBtc
            );

        uint256 cbLtcAcquired =
            _swap(
                _ltcPath(
                    ltcFirstHopTick
                ),
                CBLTC,
                ltcBudget,
                minimumCbLtc
            );

        uint256 cbDogeAcquired =
            _swap(
                _dogePath(
                    dogeFirstHopTick
                ),
                CBDOGE,
                dogeBudget,
                minimumCbDoge
            );

        uint256 usdcAfterSwaps =
            ITensegrityAcquisitionERC20(
                USDC
            ).balanceOf(
                address(this)
            );

        if (
            usdcAfterSwaps !=
            usdcBefore
        ) {
            revert ResidualAcquisitionUsdc(
                usdcBefore,
                usdcAfterSwaps
            );
        }

        (
            uint256 holderCbBtc,
            uint256 developmentCbBtc
        ) =
            _splitAndTransfer(
                acquisitionReference,
                CBBTC,
                cbBtcAcquired
            );

        (
            uint256 holderCbLtc,
            uint256 developmentCbLtc
        ) =
            _splitAndTransfer(
                acquisitionReference,
                CBLTC,
                cbLtcAcquired
            );

        (
            uint256 holderCbDoge,
            uint256 developmentCbDoge
        ) =
            _splitAndTransfer(
                acquisitionReference,
                CBDOGE,
                cbDogeAcquired
            );

        acquisitionCount =
            nextIndex;

        totalUsdcProcessed =
            nextTotalUsdc;

        totalCbBtcAcquired +=
            cbBtcAcquired;

        totalCbLtcAcquired +=
            cbLtcAcquired;

        totalCbDogeAcquired +=
            cbDogeAcquired;

        totalHolderCbBtc +=
            holderCbBtc;

        totalHolderCbLtc +=
            holderCbLtc;

        totalHolderCbDoge +=
            holderCbDoge;

        totalDevelopmentCbBtc +=
            developmentCbBtc;

        totalDevelopmentCbLtc +=
            developmentCbLtc;

        totalDevelopmentCbDoge +=
            developmentCbDoge;

        _acquisitions[
            nextIndex
        ] =
            AcquisitionRecord({
                acquisitionReference:
                    acquisitionReference,
                receiverReleaseId:
                    receiverReleaseId,
                usdcAmount:
                    usdcAmount,
                btcUsdcBudget:
                    btcBudget,
                ltcUsdcBudget:
                    ltcBudget,
                dogeUsdcBudget:
                    dogeBudget,
                cbBtcAcquired:
                    cbBtcAcquired,
                cbLtcAcquired:
                    cbLtcAcquired,
                cbDogeAcquired:
                    cbDogeAcquired,
                btcFirstHopTick:
                    btcFirstHopTick,
                ltcFirstHopTick:
                    ltcFirstHopTick,
                dogeFirstHopTick:
                    dogeFirstHopTick
            });

        emit PoWAcquisitionExecuted(
            nextIndex,
            acquisitionReference,
            receiverReleaseId,
            usdcAmount,
            cbBtcAcquired,
            cbLtcAcquired,
            cbDogeAcquired,
            holderCbBtc,
            holderCbLtc,
            holderCbDoge,
            developmentCbBtc,
            developmentCbLtc,
            developmentCbDoge
        );
    }

    /// @notice Cumulative allocation prevents repeated integer residue from
    /// systematically changing the long-run 50/25/25 basket.
    function previewBudgets(
        uint256 usdcAmount
    )
        public
        view
        returns (
            uint256 btcBudget,
            uint256 ltcBudget,
            uint256 dogeBudget
        )
    {
        if (usdcAmount == 0) {
            revert InvalidAmount();
        }

        uint256 beforeTotal =
            totalUsdcProcessed;

        uint256 afterTotal =
            beforeTotal +
            usdcAmount;

        uint256 btcBefore =
            beforeTotal / 2;

        uint256 ltcBefore =
            beforeTotal / 4;

        uint256 dogeBefore =
            beforeTotal -
            btcBefore -
            ltcBefore;

        uint256 btcAfter =
            afterTotal / 2;

        uint256 ltcAfter =
            afterTotal / 4;

        uint256 dogeAfter =
            afterTotal -
            btcAfter -
            ltcAfter;

        btcBudget =
            btcAfter -
            btcBefore;

        ltcBudget =
            ltcAfter -
            ltcBefore;

        dogeBudget =
            dogeAfter -
            dogeBefore;

        if (
            btcBudget == 0 ||
            ltcBudget == 0 ||
            dogeBudget == 0
        ) {
            revert AcquisitionTooSmall();
        }
    }

    function previewOracleMinimums(
        uint256 usdcAmount
    )
        external
        view
        returns (
            uint256 minimumCbBtc,
            uint256 minimumCbLtc,
            uint256 minimumCbDoge
        )
    {
        _checkSequencer();

        (
            uint256 btcBudget,
            uint256 ltcBudget,
            uint256 dogeBudget
        ) =
            previewBudgets(
                usdcAmount
            );

        return
            _oracleMinimums(
                btcBudget,
                ltcBudget,
                dogeBudget
            );
    }

    function getAcquisition(
        uint64 acquisitionIndex
    )
        external
        view
        returns (
            AcquisitionRecord memory
        )
    {
        return
            _acquisitions[
                acquisitionIndex
            ];
    }

    function _oracleMinimums(
        uint256 btcBudget,
        uint256 ltcBudget,
        uint256 dogeBudget
    )
        private
        view
        returns (
            uint256 minimumCbBtc,
            uint256 minimumCbLtc,
            uint256 minimumCbDoge
        )
    {
        uint256 usdcPrice =
            _readPrice(
                USDC_USD_FEED,
                USDC_MAX_AGE
            );

        uint256 cbBtcPrice =
            _readPrice(
                CBBTC_USD_FEED,
                VOLATILE_MAX_AGE
            );

        uint256 ltcPrice =
            _readPrice(
                LTC_USD_FEED,
                VOLATILE_MAX_AGE
            );

        uint256 dogePrice =
            _readPrice(
                DOGE_USD_FEED,
                VOLATILE_MAX_AGE
            );

        minimumCbBtc =
            _oracleFloor(
                btcBudget,
                usdcPrice,
                cbBtcPrice
            );

        minimumCbLtc =
            _oracleFloor(
                ltcBudget,
                usdcPrice,
                ltcPrice
            );

        minimumCbDoge =
            _oracleFloor(
                dogeBudget,
                usdcPrice,
                dogePrice
            );
    }

    /// @dev Price feeds are constrained to 8 decimals.
    /// USDC uses 6 decimals; all three output assets use 8.
    /// Therefore the token-unit scale adjustment is exactly x100.
    function _oracleFloor(
        uint256 usdcAmount,
        uint256 usdcPrice,
        uint256 assetPrice
    )
        private
        pure
        returns (uint256)
    {
        if (
            usdcPrice >
            type(uint256).max / 100
        ) {
            revert InvalidAmount();
        }

        uint256 oracleUnits =
            FullMath.mulDiv(
                usdcAmount,
                usdcPrice * 100,
                assetPrice
            );

        uint256 minimum =
            FullMath.mulDiv(
                oracleUnits,
                ORACLE_FLOOR_BPS,
                BPS_DENOMINATOR
            );

        if (minimum == 0) {
            revert AcquisitionTooSmall();
        }

        return minimum;
    }

    function _swap(
        bytes memory path,
        address outputToken,
        uint256 amountIn,
        uint256 minimumOut
    )
        private
        returns (uint256 amountOut)
    {
        uint256 outputBefore =
            ITensegrityAcquisitionERC20(
                outputToken
            ).balanceOf(
                address(this)
            );

        _approveExact(
            amountIn
        );

        amountOut =
            ITensegritySlipstreamRouter(
                ROUTER
            ).exactInput(
                ITensegritySlipstreamRouter
                    .ExactInputParams({
                        path:
                            path,
                        recipient:
                            address(this),
                        deadline:
                            block.timestamp,
                        amountIn:
                            amountIn,
                        amountOutMinimum:
                            minimumOut
                    })
            );

        uint256 allowanceAfter =
            ITensegrityAcquisitionERC20(
                USDC
            ).allowance(
                address(this),
                ROUTER
            );

        if (allowanceAfter != 0) {
            revert ResidualAllowance(
                allowanceAfter
            );
        }

        uint256 outputAfter =
            ITensegrityAcquisitionERC20(
                outputToken
            ).balanceOf(
                address(this)
            );

        uint256 balanceDelta =
            outputAfter -
            outputBefore;

        if (
            balanceDelta !=
            amountOut
        ) {
            revert RouterOutputMismatch(
                amountOut,
                balanceDelta
            );
        }

        if (
            balanceDelta <
            minimumOut
        ) {
            revert OutputBelowMinimum(
                minimumOut,
                balanceDelta
            );
        }

        if (
            balanceDelta <
            HOLDER_DEVELOPMENT_DENOMINATOR
        ) {
            revert OutputTooSmall();
        }
    }

    function _splitAndTransfer(
        bytes32 acquisitionReference,
        address token,
        uint256 amount
    )
        private
        returns (
            uint256 holderAmount,
            uint256 developmentAmount
        )
    {
        developmentAmount =
            amount /
            HOLDER_DEVELOPMENT_DENOMINATOR;

        holderAmount =
            amount -
            developmentAmount;

        if (
            developmentAmount == 0 ||
            holderAmount == 0
        ) {
            revert OutputTooSmall();
        }

        _transferExact(
            token,
            HOLDER_RESERVE,
            holderAmount
        );

        ITensegrityAcquisitionReserveAccounting(
            HOLDER_RESERVE
        ).recordAcquisition(
            acquisitionReference,
            token,
            holderAmount
        );

        _transferExact(
            token,
            DEVELOPMENT_RESERVE,
            developmentAmount
        );

        ITensegrityAcquisitionReserveAccounting(
            DEVELOPMENT_RESERVE
        ).recordAcquisition(
            acquisitionReference,
            token,
            developmentAmount
        );
    }

    function _transferExact(
        address token,
        address recipient,
        uint256 amount
    )
        private
    {
        uint256 senderBefore =
            ITensegrityAcquisitionERC20(
                token
            ).balanceOf(
                address(this)
            );

        uint256 recipientBefore =
            ITensegrityAcquisitionERC20(
                token
            ).balanceOf(
                recipient
            );

        bool transferred =
            ITensegrityAcquisitionERC20(
                token
            ).transfer(
                recipient,
                amount
            );

        if (!transferred) {
            revert TokenTransferFailed();
        }

        uint256 senderAfter =
            ITensegrityAcquisitionERC20(
                token
            ).balanceOf(
                address(this)
            );

        uint256 recipientAfter =
            ITensegrityAcquisitionERC20(
                token
            ).balanceOf(
                recipient
            );

        if (
            senderBefore -
                senderAfter !=
                amount ||
            recipientAfter -
                recipientBefore !=
                amount
        ) {
            revert TokenTransferMismatch();
        }
    }

    function _approveExact(
        uint256 amount
    )
        private
    {
        uint256 currentAllowance =
            ITensegrityAcquisitionERC20(
                USDC
            ).allowance(
                address(this),
                ROUTER
            );

        if (currentAllowance != 0) {
            revert ExistingAllowance(
                currentAllowance
            );
        }

        bool approved =
            ITensegrityAcquisitionERC20(
                USDC
            ).approve(
                ROUTER,
                amount
            );

        if (!approved) {
            revert ApprovalFailed();
        }
    }

    function _requireReceiverBinding()
        private
        view
    {
        if (
            BASE_RECEIVER.USDC() !=
                USDC ||
            BASE_RECEIVER
                .ACQUISITION_EXECUTOR() !=
                address(this)
        ) {
            revert ReceiverBindingInvalid();
        }
    }

    function _checkSequencer()
        private
        view
    {
        (
            ,
            int256 answer,
            uint256 startedAt,
            ,
        ) =
            SEQUENCER_UPTIME_FEED
                .latestRoundData();

        if (answer != 0) {
            revert SequencerDown();
        }

        if (
            startedAt == 0 ||
            startedAt >
                block.timestamp ||
            block.timestamp -
                startedAt <=
                SEQUENCER_GRACE_PERIOD
        ) {
            revert SequencerGracePeriod();
        }
    }

    function _readPrice(
        ITensegrityAggregatorV3 feed,
        uint256 maxAge
    )
        private
        view
        returns (uint256)
    {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) =
            feed.latestRoundData();

        if (
            roundId == 0 ||
            answeredInRound <
                roundId ||
            updatedAt == 0
        ) {
            revert InvalidOracleRound(
                address(feed)
            );
        }

        if (answer <= 0) {
            revert InvalidOraclePrice(
                address(feed),
                answer
            );
        }

        if (
            updatedAt >
                block.timestamp ||
            block.timestamp -
                updatedAt >
                maxAge
        ) {
            revert StaleOracle(
                address(feed),
                updatedAt
            );
        }

        return
            uint256(answer);
    }

    function _btcPath(
        int24 firstHopTick
    )
        private
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                USDC,
                firstHopTick,
                CBBTC
            );
    }

    function _ltcPath(
        int24 firstHopTick
    )
        private
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                USDC,
                firstHopTick,
                CBBTC,
                POW_SECOND_HOP_TICK,
                CBLTC
            );
    }

    function _dogePath(
        int24 firstHopTick
    )
        private
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                USDC,
                firstHopTick,
                CBBTC,
                POW_SECOND_HOP_TICK,
                CBDOGE
            );
    }

    function _requireFirstHopTick(
        int24 tick
    )
        private
        pure
    {
        if (
            tick != 1 &&
            tick != 100 &&
            tick != 2000
        ) {
            revert InvalidFirstHopTick();
        }
    }

    function _requireContract(
        address dependency
    )
        private
        view
    {
        if (
            dependency.code.length == 0
        ) {
            revert DependencyNotContract(
                dependency
            );
        }
    }

    function _requireEightDecimals(
        address feed
    )
        private
        view
    {
        uint8 feedDecimals =
            ITensegrityAggregatorV3(
                feed
            ).decimals();

        if (feedDecimals != 8) {
            revert InvalidFeedDecimals(
                feed,
                feedDecimals
            );
        }
    }

    function _max(
        uint256 a,
        uint256 b
    )
        private
        pure
        returns (uint256)
    {
        return
            a > b
                ? a
                : b;
    }
}
