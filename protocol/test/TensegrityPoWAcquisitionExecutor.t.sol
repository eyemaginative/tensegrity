// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Test
} from "../lib/uniswap-v4-core-deployed/lib/forge-std/src/Test.sol";

import {
    TensegrityPoWAcquisitionExecutor,
    ITensegritySlipstreamRouter
} from "../src/TensegrityPoWAcquisitionExecutor.sol";

contract PoWAcquisitionTestToken {
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
        balanceOf[recipient] +=
            amount;
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
        require(
            balanceOf[msg.sender] >=
                amount,
            "BALANCE"
        );

        balanceOf[msg.sender] -=
            amount;

        balanceOf[recipient] +=
            amount;

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
        uint256 allowed =
            allowance[sender][msg.sender];

        require(
            allowed >= amount,
            "ALLOWANCE"
        );

        require(
            balanceOf[sender] >=
                amount,
            "BALANCE"
        );

        allowance[sender][msg.sender] =
            allowed -
            amount;

        balanceOf[sender] -=
            amount;

        balanceOf[recipient] +=
            amount;

        return true;
    }
}

contract PoWAcquisitionTestMarker {}

contract PoWAcquisitionTestReserve {
    mapping(address asset => uint256 amount)
        public accountedReserve;

    mapping(
        bytes32 acquisitionReference =>
            mapping(address asset => bool recorded)
    )
        public acquisitionRecorded;

    bool public forceRecordFailure;

    error ForcedReserveFailure();

    function ACQUISITION_EXECUTOR()
        external
        view
        returns (address)
    {
        return msg.sender;
    }

    function setForceRecordFailure(
        bool value
    )
        external
    {
        forceRecordFailure =
            value;
    }

    function recordAcquisition(
        bytes32 acquisitionReference,
        address asset,
        uint256 amount
    )
        external
    {
        if (forceRecordFailure) {
            revert ForcedReserveFailure();
        }

        require(
            acquisitionReference !=
                bytes32(0),
            "REFERENCE"
        );

        require(
            !acquisitionRecorded[
                acquisitionReference
            ][asset],
            "DUPLICATE"
        );

        uint256 nextAccounted =
            accountedReserve[asset] +
            amount;

        require(
            PoWAcquisitionTestToken(
                asset
            ).balanceOf(address(this)) >=
                nextAccounted,
            "PHYSICAL"
        );

        acquisitionRecorded[
            acquisitionReference
        ][asset] = true;

        accountedReserve[asset] =
            nextAccounted;
    }
}

contract PoWAcquisitionTestBadReserve {
    function ACQUISITION_EXECUTOR()
        external
        pure
        returns (address)
    {
        return address(0);
    }

    function recordAcquisition(
        bytes32,
        address,
        uint256
    )
        external
    {}
}

contract PoWAcquisitionTestFeed {
    uint8 public immutable decimals;

    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(
        uint8 feedDecimals,
        int256 initialAnswer,
        uint256 initialStartedAt,
        uint256 initialUpdatedAt
    ) {
        decimals =
            feedDecimals;

        answer =
            initialAnswer;

        startedAt =
            initialStartedAt;

        updatedAt =
            initialUpdatedAt;
    }

    function setAnswer(
        int256 value
    )
        external
    {
        answer =
            value;
    }

    function setStartedAt(
        uint256 value
    )
        external
    {
        startedAt =
            value;
    }

    function setUpdatedAt(
        uint256 value
    )
        external
    {
        updatedAt =
            value;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 currentAnswer,
            uint256 currentStartedAt,
            uint256 currentUpdatedAt,
            uint80 answeredInRound
        )
    {
        roundId =
            1;

        currentAnswer =
            answer;

        currentStartedAt =
            startedAt;

        currentUpdatedAt =
            updatedAt;

        answeredInRound =
            1;
    }
}

contract PoWAcquisitionTestReceiver {
    address public constant USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address public ACQUISITION_EXECUTOR;

    function setAcquisitionExecutor(
        address executor
    )
        external
    {
        ACQUISITION_EXECUTOR =
            executor;
    }

    function releaseToAcquisition(
        uint256 amount,
        bytes32 acquisitionReference
    )
        external
        returns (bytes32 releaseId)
    {
        require(
            msg.sender ==
                ACQUISITION_EXECUTOR,
            "EXECUTOR"
        );

        bool transferred =
            PoWAcquisitionTestToken(
                USDC
            ).transfer(
                msg.sender,
                amount
            );

        require(
            transferred,
            "TRANSFER"
        );

        releaseId =
            keccak256(
                abi.encode(
                    acquisitionReference,
                    amount
                )
            );
    }
}

contract PoWAcquisitionTestRouter {
    address internal constant USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant CBBTC =
        0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address internal constant CBLTC =
        0xcb17C9Db87B595717C857a08468793f5bAb6445F;

    address internal constant CBDOGE =
        0xcbD06E5A2B0C65597161de254AA074E489dEb510;

    address internal constant FACTORY =
        0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    address internal constant WETH =
        0x4200000000000000000000000000000000000006;

    bool public pullLess;
    address public failToken;
    address public underDeliverToken;

    error RouterMinimum(
        uint256 actual,
        uint256 minimum
    );

    error ForcedRouterFailure();

    function factory()
        external
        pure
        returns (address)
    {
        return FACTORY;
    }

    function WETH9()
        external
        pure
        returns (address)
    {
        return WETH;
    }

    function setPullLess(
        bool value
    )
        external
    {
        pullLess =
            value;
    }

    function setFailToken(
        address value
    )
        external
    {
        failToken =
            value;
    }

    function setUnderDeliverToken(
        address value
    )
        external
    {
        underDeliverToken =
            value;
    }

    function exactInput(
        ITensegritySlipstreamRouter
            .ExactInputParams calldata params
    )
        external
        payable
        returns (uint256 amountOut)
    {
        address outputToken =
            _lastAddress(
                params.path
            );

        if (
            outputToken ==
            failToken
        ) {
            revert ForcedRouterFailure();
        }

        uint256 pullAmount =
            pullLess
                ? params.amountIn - 1
                : params.amountIn;

        bool pulled =
            PoWAcquisitionTestToken(
                USDC
            ).transferFrom(
                msg.sender,
                address(this),
                pullAmount
            );

        require(
            pulled,
            "PULL"
        );

        if (outputToken == CBBTC) {
            amountOut =
                params.amountIn /
                800;
        }
        else if (
            outputToken ==
            CBLTC
        ) {
            amountOut =
                params.amountIn;
        }
        else if (
            outputToken ==
            CBDOGE
        ) {
            amountOut =
                params.amountIn *
                1000;
        }
        else {
            revert(
                "OUTPUT"
            );
        }

        if (
            outputToken ==
            underDeliverToken
        ) {
            amountOut =
                params.amountOutMinimum -
                1;
        }

        if (
            amountOut <
            params.amountOutMinimum
        ) {
            revert RouterMinimum(
                amountOut,
                params.amountOutMinimum
            );
        }

        PoWAcquisitionTestToken(
            outputToken
        ).mint(
            params.recipient,
            amountOut
        );
    }

    function _lastAddress(
        bytes calldata path
    )
        private
        pure
        returns (address result)
    {
        require(
            path.length >= 20,
            "PATH"
        );

        uint256 offset;

        assembly {
            offset :=
                add(
                    path.offset,
                    sub(
                        path.length,
                        20
                    )
                )

            result :=
                shr(
                    96,
                    calldataload(
                        offset
                    )
                )
        }
    }
}

contract TensegrityPoWAcquisitionExecutorTest
    is Test
{
    address internal constant USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant CBBTC =
        0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address internal constant CBLTC =
        0xcb17C9Db87B595717C857a08468793f5bAb6445F;

    address internal constant CBDOGE =
        0xcbD06E5A2B0C65597161de254AA074E489dEb510;

    address internal constant ROUTER =
        0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;

    address internal constant FACTORY =
        0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    uint256 internal constant NOW =
        1_800_000_000;

    PoWAcquisitionTestReceiver
        internal receiver;

    PoWAcquisitionTestReserve
        internal holderReserve;

    PoWAcquisitionTestReserve
        internal developmentReserve;

    PoWAcquisitionTestFeed
        internal usdcFeed;

    PoWAcquisitionTestFeed
        internal cbBtcFeed;

    PoWAcquisitionTestFeed
        internal ltcFeed;

    PoWAcquisitionTestFeed
        internal dogeFeed;

    PoWAcquisitionTestFeed
        internal sequencerFeed;

    TensegrityPoWAcquisitionExecutor
        internal executor;

    function setUp() public {
        vm.chainId(
            8453
        );

        vm.warp(
            NOW
        );

        PoWAcquisitionTestToken tokenImplementation =
            new PoWAcquisitionTestToken();

        vm.etch(
            USDC,
            address(tokenImplementation).code
        );

        vm.etch(
            CBBTC,
            address(tokenImplementation).code
        );

        vm.etch(
            CBLTC,
            address(tokenImplementation).code
        );

        vm.etch(
            CBDOGE,
            address(tokenImplementation).code
        );

        PoWAcquisitionTestMarker factoryImplementation =
            new PoWAcquisitionTestMarker();

        vm.etch(
            FACTORY,
            address(factoryImplementation).code
        );

        PoWAcquisitionTestRouter routerImplementation =
            new PoWAcquisitionTestRouter();

        vm.etch(
            ROUTER,
            address(routerImplementation).code
        );

        receiver =
            new PoWAcquisitionTestReceiver();

        holderReserve =
            new PoWAcquisitionTestReserve();

        developmentReserve =
            new PoWAcquisitionTestReserve();

        usdcFeed =
            new PoWAcquisitionTestFeed(
                8,
                100_000_000,
                NOW - 1 minutes,
                NOW - 1 minutes
            );

        cbBtcFeed =
            new PoWAcquisitionTestFeed(
                8,
                8_000_000_000_000,
                NOW - 1 minutes,
                NOW - 1 minutes
            );

        ltcFeed =
            new PoWAcquisitionTestFeed(
                8,
                10_000_000_000,
                NOW - 1 minutes,
                NOW - 1 minutes
            );

        dogeFeed =
            new PoWAcquisitionTestFeed(
                8,
                10_000_000,
                NOW - 1 minutes,
                NOW - 1 minutes
            );

        sequencerFeed =
            new PoWAcquisitionTestFeed(
                0,
                0,
                NOW - 2 hours,
                NOW - 1 minutes
            );

        executor =
            new TensegrityPoWAcquisitionExecutor(
                address(receiver),
                address(holderReserve),
                address(developmentReserve),
                address(usdcFeed),
                address(cbBtcFeed),
                address(ltcFeed),
                address(dogeFeed),
                address(sequencerFeed),
                2 hours,
                26 hours
            );

        receiver
            .setAcquisitionExecutor(
                address(executor)
            );

        PoWAcquisitionTestToken(
            USDC
        ).mint(
            address(receiver),
            500_000_000
        );
    }

    function _execute100Usdc()
        internal
        returns (bytes32)
    {
        return
            executor.acquire(
                100_000_000,
                2000,
                2000,
                100,
                1,
                1,
                1
            );
    }

    function testConstructorRequiresBase()
        public
    {
        vm.chainId(
            4663
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityPoWAcquisitionExecutor
                    .WrongChain
                    .selector,
                uint256(4663)
            )
        );

        new TensegrityPoWAcquisitionExecutor(
            address(receiver),
            address(holderReserve),
            address(developmentReserve),
            address(usdcFeed),
            address(cbBtcFeed),
            address(ltcFeed),
            address(dogeFeed),
            address(sequencerFeed),
            2 hours,
            26 hours
        );
    }

    function testPermissionlessAtomicAcquisitionAndReserveSplit()
        public
    {
        vm.prank(
            address(0xCAFE)
        );

        bytes32 acquisitionReference =
            _execute100Usdc();

        assertTrue(
            acquisitionReference !=
                bytes32(0)
        );

        assertEq(
            uint256(
                executor
                    .acquisitionCount()
            ),
            1
        );

        assertEq(
            executor
                .totalUsdcProcessed(),
            100_000_000
        );

        uint256 cbBtcAcquired =
            62_500;

        uint256 cbLtcAcquired =
            25_000_000;

        uint256 cbDogeAcquired =
            25_000_000_000;

        assertEq(
            executor
                .totalCbBtcAcquired(),
            cbBtcAcquired
        );

        assertEq(
            executor
                .totalCbLtcAcquired(),
            cbLtcAcquired
        );

        assertEq(
            executor
                .totalCbDogeAcquired(),
            cbDogeAcquired
        );

        uint256 devBtc =
            cbBtcAcquired / 13;

        uint256 devLtc =
            cbLtcAcquired / 13;

        uint256 devDoge =
            cbDogeAcquired / 13;

        assertEq(
            PoWAcquisitionTestToken(
                CBBTC
            ).balanceOf(
                address(holderReserve)
            ),
            cbBtcAcquired -
                devBtc
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBBTC
            ).balanceOf(
                address(developmentReserve)
            ),
            devBtc
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBLTC
            ).balanceOf(
                address(holderReserve)
            ),
            cbLtcAcquired -
                devLtc
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBLTC
            ).balanceOf(
                address(developmentReserve)
            ),
            devLtc
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBDOGE
            ).balanceOf(
                address(holderReserve)
            ),
            cbDogeAcquired -
                devDoge
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBDOGE
            ).balanceOf(
                address(developmentReserve)
            ),
            devDoge
        );

        assertEq(
            holderReserve
                .accountedReserve(CBBTC),
            cbBtcAcquired - devBtc
        );

        assertEq(
            holderReserve
                .accountedReserve(CBLTC),
            cbLtcAcquired - devLtc
        );

        assertEq(
            holderReserve
                .accountedReserve(CBDOGE),
            cbDogeAcquired - devDoge
        );

        assertEq(
            developmentReserve
                .accountedReserve(CBBTC),
            devBtc
        );

        assertEq(
            developmentReserve
                .accountedReserve(CBLTC),
            devLtc
        );

        assertEq(
            developmentReserve
                .accountedReserve(CBDOGE),
            devDoge
        );

        assertTrue(
            holderReserve
                .acquisitionRecorded(
                    acquisitionReference,
                    CBBTC
                )
        );

        assertTrue(
            holderReserve
                .acquisitionRecorded(
                    acquisitionReference,
                    CBLTC
                )
        );

        assertTrue(
            holderReserve
                .acquisitionRecorded(
                    acquisitionReference,
                    CBDOGE
                )
        );

        assertTrue(
            developmentReserve
                .acquisitionRecorded(
                    acquisitionReference,
                    CBBTC
                )
        );

        assertTrue(
            developmentReserve
                .acquisitionRecorded(
                    acquisitionReference,
                    CBLTC
                )
        );

        assertTrue(
            developmentReserve
                .acquisitionRecorded(
                    acquisitionReference,
                    CBDOGE
                )
        );

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            400_000_000
        );

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(executor)
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).allowance(
                address(executor),
                ROUTER
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBBTC
            ).balanceOf(
                address(executor)
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBLTC
            ).balanceOf(
                address(executor)
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBDOGE
            ).balanceOf(
                address(executor)
            ),
            0
        );
    }

    function testConstructorRejectsReserveBindingMismatch()
        public
    {
        PoWAcquisitionTestBadReserve badReserve =
            new PoWAcquisitionTestBadReserve();

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityPoWAcquisitionExecutor
                    .ReserveBindingInvalid
                    .selector,
                address(badReserve),
                address(0)
            )
        );

        new TensegrityPoWAcquisitionExecutor(
            address(receiver),
            address(badReserve),
            address(developmentReserve),
            address(usdcFeed),
            address(cbBtcFeed),
            address(ltcFeed),
            address(dogeFeed),
            address(sequencerFeed),
            2 hours,
            26 hours
        );
    }

    function testHolderAccountingFailureRollsBackEntireAcquisition()
        public
    {
        holderReserve
            .setForceRecordFailure(true);

        vm.expectRevert(
            PoWAcquisitionTestReserve
                .ForcedReserveFailure
                .selector
        );

        _execute100Usdc();

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            500_000_000
        );

        assertEq(
            uint256(
                executor
                    .acquisitionCount()
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBBTC
            ).balanceOf(
                address(holderReserve)
            ),
            0
        );

        assertEq(
            holderReserve
                .accountedReserve(CBBTC),
            0
        );
    }

    function testDevelopmentAccountingFailureRollsBackEntireAcquisition()
        public
    {
        developmentReserve
            .setForceRecordFailure(true);

        vm.expectRevert(
            PoWAcquisitionTestReserve
                .ForcedReserveFailure
                .selector
        );

        _execute100Usdc();

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            500_000_000
        );

        assertEq(
            uint256(
                executor
                    .acquisitionCount()
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBBTC
            ).balanceOf(
                address(holderReserve)
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBBTC
            ).balanceOf(
                address(developmentReserve)
            ),
            0
        );

        assertEq(
            holderReserve
                .accountedReserve(CBBTC),
            0
        );

        assertEq(
            developmentReserve
                .accountedReserve(CBBTC),
            0
        );
    }

    function testInvalidTickRejectedBeforeFunding()
        public
    {
        vm.expectRevert(
            TensegrityPoWAcquisitionExecutor
                .InvalidFirstHopTick
                .selector
        );

        executor.acquire(
            100_000_000,
            50,
            100,
            100,
            1,
            1,
            1
        );

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            500_000_000
        );
    }

    function testStaleOracleRejectedBeforeFunding()
        public
    {
        uint256 staleTime =
            NOW -
            2 hours -
            1;

        cbBtcFeed
            .setUpdatedAt(
                staleTime
            );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityPoWAcquisitionExecutor
                    .StaleOracle
                    .selector,
                address(cbBtcFeed),
                staleTime
            )
        );

        _execute100Usdc();

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            500_000_000
        );
    }

    function testSequencerDownRejected()
        public
    {
        sequencerFeed
            .setAnswer(
                1
            );

        vm.expectRevert(
            TensegrityPoWAcquisitionExecutor
                .SequencerDown
                .selector
        );

        _execute100Usdc();
    }

    function testSequencerGracePeriodRejected()
        public
    {
        sequencerFeed
            .setStartedAt(
                NOW -
                30 minutes
            );

        vm.expectRevert(
            TensegrityPoWAcquisitionExecutor
                .SequencerGracePeriod
                .selector
        );

        _execute100Usdc();
    }

    function testOracleFloorOverridesWeakCallerMinimumAndRollsBack()
        public
    {
        (
            uint256 minimumCbBtc,
            ,
        ) =
            executor
                .previewOracleMinimums(
                    100_000_000
                );

        PoWAcquisitionTestRouter(
            ROUTER
        ).setUnderDeliverToken(
            CBBTC
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PoWAcquisitionTestRouter
                    .RouterMinimum
                    .selector,
                minimumCbBtc - 1,
                minimumCbBtc
            )
        );

        _execute100Usdc();

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            500_000_000
        );

        assertEq(
            uint256(
                executor
                    .acquisitionCount()
            ),
            0
        );
    }

    function testPartialRouterPullLeavesAllowanceAndRollsBack()
        public
    {
        PoWAcquisitionTestRouter(
            ROUTER
        ).setPullLess(
            true
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityPoWAcquisitionExecutor
                    .ResidualAllowance
                    .selector,
                uint256(1)
            )
        );

        _execute100Usdc();

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            500_000_000
        );

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                ROUTER
            ),
            0
        );

        assertEq(
            uint256(
                executor
                    .acquisitionCount()
            ),
            0
        );
    }

    function testSecondLegFailureRollsBackEntireAcquisition()
        public
    {
        PoWAcquisitionTestRouter(
            ROUTER
        ).setFailToken(
            CBLTC
        );

        vm.expectRevert(
            PoWAcquisitionTestRouter
                .ForcedRouterFailure
                .selector
        );

        _execute100Usdc();

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            500_000_000
        );

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                ROUTER
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBBTC
            ).balanceOf(
                address(holderReserve)
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBLTC
            ).balanceOf(
                address(holderReserve)
            ),
            0
        );

        assertEq(
            PoWAcquisitionTestToken(
                CBDOGE
            ).balanceOf(
                address(holderReserve)
            ),
            0
        );
    }

    function testReceiverBindingRequired()
        public
    {
        receiver
            .setAcquisitionExecutor(
                address(0xBAD)
            );

        vm.expectRevert(
            TensegrityPoWAcquisitionExecutor
                .ReceiverBindingInvalid
                .selector
        );

        _execute100Usdc();

        assertEq(
            PoWAcquisitionTestToken(
                USDC
            ).balanceOf(
                address(receiver)
            ),
            500_000_000
        );
    }

    function testCumulativeBudgetRoundingPreservesBasket()
        public
    {
        (
            uint256 btcInitial,
            uint256 ltcInitial,
            uint256 dogeInitial
        ) =
            executor.previewBudgets(
                100_000_001
            );

        assertEq(
            btcInitial,
            50_000_000
        );

        assertEq(
            ltcInitial,
            25_000_000
        );

        assertEq(
            dogeInitial,
            25_000_001
        );

        _execute100Usdc();

        (
            uint256 btcNext,
            uint256 ltcNext,
            uint256 dogeNext
        ) =
            executor.previewBudgets(
                5
            );

        assertEq(
            btcNext,
            2
        );

        assertEq(
            ltcNext,
            1
        );

        assertEq(
            dogeNext,
            2
        );

        assertEq(
            btcNext +
                ltcNext +
                dogeNext,
            5
        );
    }
}
