// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Test
} from "../lib/uniswap-v4-core-deployed/lib/forge-std/src/Test.sol";

import {
    TensegrityRelayBridgeAdapter
} from "../src/TensegrityRelayBridgeAdapter.sol";

import {
    TensegrityRelayOrderV1Hasher
} from "../src/TensegrityRelayOrderV1Hasher.sol";

contract RelayAdapterTestUSDG {
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

        uint256 balance =
            balanceOf[sender];

        require(
            balance >= amount,
            "BALANCE"
        );

        allowance[sender][msg.sender] =
            allowed -
            amount;

        balanceOf[sender] =
            balance -
            amount;

        balanceOf[recipient] +=
            amount;

        return true;
    }
}

contract RelayAdapterTestDepository {
    bool public pullLess;

    address public lastDepositor;
    address public lastToken;
    uint256 public lastAmount;
    bytes32 public lastId;

    function setPullLess(
        bool value
    )
        external
    {
        pullLess =
            value;
    }

    function depositErc20(
        address depositor,
        address token,
        uint256 amount,
        bytes32 id
    )
        external
    {
        uint256 pullAmount =
            pullLess
                ? amount - 1
                : amount;

        bool ok =
            RelayAdapterTestUSDG(token)
                .transferFrom(
                    msg.sender,
                    address(this),
                    pullAmount
                );

        require(
            ok,
            "TRANSFER_FROM"
        );

        lastDepositor =
            depositor;

        lastToken =
            token;

        lastAmount =
            amount;

        lastId =
            id;
    }
}

contract TensegrityRelayBridgeAdapterTest
    is Test
{
    address internal constant USDG =
        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address internal constant BASE_USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant EXECUTOR =
        address(0x1111);

    address internal constant BASE_RECEIVER =
        address(0x2222);

    address internal constant ROUTER =
        address(0x3333);

    uint256 internal constant SOLVER_PK =
        0xA11CE;

    address internal solver;

    RelayAdapterTestUSDG internal usdg;
    RelayAdapterTestDepository internal depository;

    TensegrityRelayBridgeAdapter
        internal adapter;

    function setUp() public {
        vm.chainId(
            4663
        );

        RelayAdapterTestUSDG implementation =
            new RelayAdapterTestUSDG();

        vm.etch(
            USDG,
            address(implementation).code
        );

        usdg =
            RelayAdapterTestUSDG(
                USDG
            );

        depository =
            new RelayAdapterTestDepository();

        solver =
            vm.addr(
                SOLVER_PK
            );

        adapter =
            new TensegrityRelayBridgeAdapter(
                EXECUTOR,
                BASE_RECEIVER,
                address(depository),
                solver,
                ROUTER
            );
    }

    function _stage(
        uint64 sequence,
        uint256 amount,
        uint256 holderAmount,
        uint256 developmentAmount
    )
        internal
        returns (bytes32 bridgeReference)
    {
        bytes32 settlementId =
            keccak256(
                abi.encode(
                    sequence,
                    amount,
                    holderAmount,
                    developmentAmount
                )
            );

        usdg.mint(
            address(adapter),
            amount
        );

        vm.prank(
            EXECUTOR
        );

        bridgeReference =
            adapter.acceptSettlement(
                settlementId,
                address(0x4444),
                1,
                sequence,
                amount,
                holderAmount,
                developmentAmount
            );
    }

    function _ceilBps(
        uint256 amount,
        uint256 bps
    )
        internal
        pure
        returns (uint256)
    {
        uint256 q =
            amount /
            10_000;

        uint256 r =
            amount %
            10_000;

        uint256 result =
            q *
            bps;

        uint256 p =
            r *
            bps;

        if (p != 0) {
            result +=
                (
                    p +
                    9_999
                ) /
                10_000;
        }

        return result;
    }

    function _buildOrder(
        uint256 amount,
        uint256 salt
    )
        internal
        view
        returns (
            TensegrityRelayOrderV1Hasher.Order memory order
        )
    {
        uint32 deadline =
            uint32(
                block.timestamp +
                7 days
            );

        bytes memory routerExtra =
            abi.encode(
                ROUTER
            );

        order.version =
            "v1";

        order.solverChainId =
            "base";

        order.solver =
            solver;

        order.salt =
            salt;

        order.inputs =
            new TensegrityRelayOrderV1Hasher.Input[](1);

        order.inputs[0].payment =
            TensegrityRelayOrderV1Hasher.InputPayment({
                chainId:
                    "robinhood",
                currency:
                    abi.encodePacked(
                        USDG
                    ),
                amount:
                    amount,
                weight:
                    1
            });

        order.inputs[0].refunds =
            new TensegrityRelayOrderV1Hasher.InputRefund[](2);

        order.inputs[0].refunds[0] =
            TensegrityRelayOrderV1Hasher.InputRefund({
                chainId:
                    "robinhood",
                recipient:
                    abi.encodePacked(
                        address(adapter)
                    ),
                currency:
                    abi.encodePacked(
                        USDG
                    ),
                minimumAmount:
                    0,
                deadline:
                    deadline,
                extraData:
                    routerExtra
            });

        order.inputs[0].refunds[1] =
            TensegrityRelayOrderV1Hasher.InputRefund({
                chainId:
                    "base",
                recipient:
                    abi.encodePacked(
                        BASE_RECEIVER
                    ),
                currency:
                    abi.encodePacked(
                        BASE_USDC
                    ),
                minimumAmount:
                    0,
                deadline:
                    deadline,
                extraData:
                    routerExtra
            });

        order.output.chainId =
            "base";

        order.output.payments =
            new TensegrityRelayOrderV1Hasher.OutputPayment[](1);

        uint256 expectedAmount =
            _ceilBps(
                amount,
                9_990
            );

        uint256 minimumAmount =
            _ceilBps(
                expectedAmount,
                9_950
            );

        order.output.payments[0] =
            TensegrityRelayOrderV1Hasher.OutputPayment({
                recipient:
                    abi.encodePacked(
                        BASE_RECEIVER
                    ),
                currency:
                    abi.encodePacked(
                        BASE_USDC
                    ),
                minimumAmount:
                    minimumAmount,
                expectedAmount:
                    expectedAmount
            });

        order.output.deadline =
            deadline;

        order.output.calls =
            new bytes[](0);

        order.output.extraData =
            routerExtra;

        order.fees =
            new TensegrityRelayOrderV1Hasher.Fee[](0);
    }

    function _sign(
        TensegrityRelayOrderV1Hasher.Order memory order,
        uint256 privateKey
    )
        internal
        returns (bytes memory)
    {
        bytes32 orderId =
            adapter.hashOrder(
                order
            );

        bytes32 digest =
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    orderId
                )
            );

        (
            uint8 v,
            bytes32 r,
            bytes32 s
        ) =
            vm.sign(
                privateKey,
                digest
            );

        return
            abi.encodePacked(
                r,
                s,
                v
            );
    }

    function testAcceptSettlementRequiresExecutorAndBacking()
        public
    {
        uint256 amount =
            3_250_000;

        bytes32 settlementId =
            keccak256(
                "SETTLEMENT"
            );

        usdg.mint(
            address(adapter),
            amount
        );

        vm.expectRevert(
            TensegrityRelayBridgeAdapter
                .OnlySettlementExecutor
                .selector
        );

        adapter.acceptSettlement(
            settlementId,
            address(0x4444),
            1,
            1,
            amount,
            3_000_000,
            250_000
        );

        vm.prank(
            EXECUTOR
        );

        bytes32 bridgeReference =
            adapter.acceptSettlement(
                settlementId,
                address(0x4444),
                1,
                1,
                amount,
                3_000_000,
                250_000
            );

        assertTrue(
            bridgeReference !=
                bytes32(0)
        );

        assertEq(
            uint256(
                adapter
                    .acceptedSettlementCount()
            ),
            1
        );

        (
            uint256 staged,
            uint256 holder,
            uint256 development
        ) =
            adapter.stagedTotals();

        assertEq(
            staged,
            amount
        );

        assertEq(
            holder,
            3_000_000
        );

        assertEq(
            development,
            250_000
        );
    }

    function testPermissionlessRelayUsesExactFiniteApproval()
        public
    {
        uint256 amount =
            3_250_000;

        bytes32 bridgeReference =
            _stage(
                1,
                amount,
                3_000_000,
                250_000
            );

        TensegrityRelayOrderV1Hasher.Order
            memory order =
                _buildOrder(
                    amount,
                    1
                );

        bytes memory signature =
            _sign(
                order,
                SOLVER_PK
            );

        vm.prank(
            address(0xCAFE)
        );

        bytes32 orderId =
            adapter.executeRelay(
                1,
                order,
                signature
            );

        assertTrue(
            orderId != bytes32(0)
        );

        assertEq(
            usdg.balanceOf(
                address(adapter)
            ),
            0
        );

        assertEq(
            usdg.balanceOf(
                address(depository)
            ),
            amount
        );

        assertEq(
            usdg.allowance(
                address(adapter),
                address(depository)
            ),
            0
        );

        assertEq(
            depository.lastDepositor(),
            address(adapter)
        );

        assertEq(
            depository.lastToken(),
            USDG
        );

        assertEq(
            depository.lastAmount(),
            amount
        );

        assertEq(
            depository.lastId(),
            orderId
        );

        (
            ,
            ,
            ,
            ,
            uint64 acceptedIndex,
            ,
            ,
            ,
            bool bridged
        ) =
            adapter.getSettlement(
                bridgeReference
            );

        assertEq(
            uint256(acceptedIndex),
            1
        );

        assertTrue(
            bridged
        );
    }

    function testCumulativeBatchAggregatesFragmentedSettlements()
        public
    {
        _stage(
            1,
            3_250_000,
            3_000_000,
            250_000
        );

        _stage(
            2,
            3_359_174,
            3_100_776,
            258_398
        );

        (
            uint64 fromSettlement,
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        ) =
            adapter.previewBatch(
                2
            );

        assertEq(
            uint256(fromSettlement),
            1
        );

        assertEq(
            amount,
            6_609_174
        );

        assertEq(
            holderAmount,
            6_100_776
        );

        assertEq(
            developmentAmount,
            508_398
        );

        TensegrityRelayOrderV1Hasher.Order
            memory order =
                _buildOrder(
                    amount,
                    2
                );

        bytes memory signature =
            _sign(
                order,
                SOLVER_PK
            );

        adapter.executeRelay(
            2,
            order,
            signature
        );

        assertEq(
            uint256(
                adapter
                    .bridgedSettlementCount()
            ),
            2
        );

        assertEq(
            adapter.totalBridgedAmount(),
            amount
        );

        assertEq(
            adapter.totalBridgedHolder(),
            holderAmount
        );

        assertEq(
            adapter
                .totalBridgedDevelopment(),
            developmentAmount
        );
    }

    function testNewSettlementDoesNotInvalidateQuotedPrefix()
        public
    {
        uint256 firstAmount =
            3_250_000;

        _stage(
            1,
            firstAmount,
            3_000_000,
            250_000
        );

        TensegrityRelayOrderV1Hasher.Order
            memory firstOrder =
                _buildOrder(
                    firstAmount,
                    3
                );

        bytes memory firstSignature =
            _sign(
                firstOrder,
                SOLVER_PK
            );

        _stage(
            2,
            3_359_174,
            3_100_776,
            258_398
        );

        adapter.executeRelay(
            1,
            firstOrder,
            firstSignature
        );

        assertEq(
            uint256(
                adapter
                    .bridgedSettlementCount()
            ),
            1
        );

        (
            uint256 staged,
            uint256 holder,
            uint256 development
        ) =
            adapter.stagedTotals();

        assertEq(
            staged,
            3_359_174
        );

        assertEq(
            holder,
            3_100_776
        );

        assertEq(
            development,
            258_398
        );
    }

    function testRejectsUnsafeBaseCurrency()
        public
    {
        uint256 amount =
            3_250_000;

        _stage(
            1,
            amount,
            3_000_000,
            250_000
        );

        TensegrityRelayOrderV1Hasher.Order
            memory order =
                _buildOrder(
                    amount,
                    4
                );

        order.output.payments[0].currency =
            abi.encodePacked(
                address(0x9999)
            );

        bytes memory signature =
            _sign(
                order,
                SOLVER_PK
            );

        vm.expectRevert(
            TensegrityRelayBridgeAdapter
                .InvalidOutput
                .selector
        );

        adapter.executeRelay(
            1,
            order,
            signature
        );

        assertEq(
            usdg.balanceOf(
                address(adapter)
            ),
            amount
        );
    }

    function testRejectsQuoteGapAboveFiftyBps()
        public
    {
        uint256 amount =
            3_250_000;

        _stage(
            1,
            amount,
            3_000_000,
            250_000
        );

        TensegrityRelayOrderV1Hasher.Order
            memory order =
                _buildOrder(
                    amount,
                    5
                );

        uint256 expected =
            order.output
                .payments[0]
                .expectedAmount;

        order.output
            .payments[0]
            .minimumAmount =
                _ceilBps(
                    expected,
                    9_949
                );

        bytes memory signature =
            _sign(
                order,
                SOLVER_PK
            );

        vm.expectRevert(
            TensegrityRelayBridgeAdapter
                .QuoteGapTooWide
                .selector
        );

        adapter.executeRelay(
            1,
            order,
            signature
        );
    }

    function testRejectsAllInOutputBelowNinetyNinePercent()
        public
    {
        uint256 amount =
            3_250_000;

        _stage(
            1,
            amount,
            3_000_000,
            250_000
        );

        TensegrityRelayOrderV1Hasher.Order
            memory order =
                _buildOrder(
                    amount,
                    6
                );

        uint256 expected =
            _ceilBps(
                amount,
                9_800
            );

        order.output
            .payments[0]
            .expectedAmount =
                expected;

        order.output
            .payments[0]
            .minimumAmount =
                _ceilBps(
                    expected,
                    9_950
                );

        bytes memory signature =
            _sign(
                order,
                SOLVER_PK
            );

        vm.expectRevert(
            TensegrityRelayBridgeAdapter
                .MinimumOutputTooLow
                .selector
        );

        adapter.executeRelay(
            1,
            order,
            signature
        );
    }

    function testRejectsDestinationCalls()
        public
    {
        uint256 amount =
            3_250_000;

        _stage(
            1,
            amount,
            3_000_000,
            250_000
        );

        TensegrityRelayOrderV1Hasher.Order
            memory order =
                _buildOrder(
                    amount,
                    7
                );

        order.output.calls =
            new bytes[](1);

        order.output.calls[0] =
            hex"1234";

        bytes memory signature =
            _sign(
                order,
                SOLVER_PK
            );

        vm.expectRevert(
            TensegrityRelayBridgeAdapter
                .UnexpectedDestinationCalls
                .selector
        );

        adapter.executeRelay(
            1,
            order,
            signature
        );
    }

    function testRejectsWrongSolverSignature()
        public
    {
        uint256 amount =
            3_250_000;

        _stage(
            1,
            amount,
            3_000_000,
            250_000
        );

        TensegrityRelayOrderV1Hasher.Order
            memory order =
                _buildOrder(
                    amount,
                    8
                );

        bytes memory signature =
            _sign(
                order,
                0xB0B
            );

        vm.expectRevert(
            TensegrityRelayBridgeAdapter
                .InvalidOrderSignature
                .selector
        );

        adapter.executeRelay(
            1,
            order,
            signature
        );
    }

    function testPartialDepositoryPullRollsBackEntireExecution()
        public
    {
        uint256 amount =
            3_250_000;

        _stage(
            1,
            amount,
            3_000_000,
            250_000
        );

        TensegrityRelayOrderV1Hasher.Order
            memory order =
                _buildOrder(
                    amount,
                    9
                );

        bytes memory signature =
            _sign(
                order,
                SOLVER_PK
            );

        depository.setPullLess(
            true
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityRelayBridgeAdapter
                    .ResidualAllowance
                    .selector,
                uint256(1)
            )
        );

        adapter.executeRelay(
            1,
            order,
            signature
        );

        assertEq(
            uint256(
                adapter
                    .bridgedSettlementCount()
            ),
            0
        );

        assertEq(
            usdg.balanceOf(
                address(adapter)
            ),
            amount
        );

        assertEq(
            usdg.balanceOf(
                address(depository)
            ),
            0
        );

        assertEq(
            usdg.allowance(
                address(adapter),
                address(depository)
            ),
            0
        );
    }
}
