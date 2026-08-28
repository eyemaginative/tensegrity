// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Test
} from "../lib/uniswap-v4-core-deployed/lib/forge-std/src/Test.sol";

import {
    TensegrityBaseReceiver
} from "../src/TensegrityBaseReceiver.sol";

contract BaseReceiverTestUSDC {
    mapping(address account => uint256 balance)
        public balanceOf;

    bool public transferLess;

    function mint(
        address recipient,
        uint256 amount
    )
        external
    {
        balanceOf[recipient] +=
            amount;
    }

    function setTransferLess(
        bool value
    )
        external
    {
        transferLess =
            value;
    }

    function transfer(
        address recipient,
        uint256 amount
    )
        external
        returns (bool)
    {
        uint256 sendAmount =
            transferLess
                ? amount - 1
                : amount;

        require(
            balanceOf[msg.sender] >=
                sendAmount,
            "BALANCE"
        );

        balanceOf[msg.sender] -=
            sendAmount;

        balanceOf[recipient] +=
            sendAmount;

        return true;
    }
}

contract BaseReceiverNativeSender {
    function send(
        address payable target
    )
        external
        payable
    {
        (
            bool ok,
            bytes memory data
        ) =
            target.call{
                value: msg.value
            }("");

        if (!ok) {
            assembly {
                revert(
                    add(data, 32),
                    mload(data)
                )
            }
        }
    }
}

contract TensegrityBaseReceiverTest
    is Test
{
    address internal constant USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant ACQUISITION_EXECUTOR =
        address(0xA11CE);

    BaseReceiverTestUSDC internal usdc;

    TensegrityBaseReceiver
        internal receiver;

    function setUp() public {
        vm.chainId(
            8453
        );

        BaseReceiverTestUSDC implementation =
            new BaseReceiverTestUSDC();

        vm.etch(
            USDC,
            address(implementation).code
        );

        usdc =
            BaseReceiverTestUSDC(
                USDC
            );

        receiver =
            new TensegrityBaseReceiver(
                ACQUISITION_EXECUTOR
            );
    }

    function _sync(
        uint256 amount
    )
        internal
        returns (
            bytes32 receiptId
        )
    {
        usdc.mint(
            address(receiver),
            amount
        );

        (
            receiptId,
        ) =
            receiver.sync();
    }

    function testConstructorRequiresBaseAndNonzeroExecutor()
        public
    {
        vm.chainId(
            4663
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityBaseReceiver
                    .WrongChain
                    .selector,
                uint256(4663)
            )
        );

        new TensegrityBaseReceiver(
            ACQUISITION_EXECUTOR
        );

        vm.chainId(
            8453
        );

        vm.expectRevert(
            TensegrityBaseReceiver
                .ZeroAcquisitionExecutor
                .selector
        );

        new TensegrityBaseReceiver(
            address(0)
        );
    }

    function testSyncAccountsCanonicalUsdcPermissionlessly()
        public
    {
        uint256 amount =
            99_900_773;

        usdc.mint(
            address(receiver),
            amount
        );

        vm.prank(
            address(0xCAFE)
        );

        (
            bytes32 receiptId,
            uint256 syncedAmount
        ) =
            receiver.sync();

        assertTrue(
            receiptId != bytes32(0)
        );

        assertEq(
            syncedAmount,
            amount
        );

        assertEq(
            receiver.totalReceived(),
            amount
        );

        assertEq(
            receiver
                .availableForAcquisition(),
            amount
        );

        assertEq(
            receiver.unsyncedUsdc(),
            0
        );

        assertEq(
            uint256(
                receiver.receiptCount()
            ),
            1
        );
    }

    function testMultipleSyncsAccountOnlyNewUsdc()
        public
    {
        _sync(
            10_000_000
        );

        _sync(
            20_000_000
        );

        assertEq(
            receiver.totalReceived(),
            30_000_000
        );

        assertEq(
            receiver
                .availableForAcquisition(),
            30_000_000
        );

        assertEq(
            uint256(
                receiver.receiptCount()
            ),
            2
        );
    }

    function testOnlyAcquisitionExecutorCanRelease()
        public
    {
        _sync(
            10_000_000
        );

        vm.expectRevert(
            TensegrityBaseReceiver
                .OnlyAcquisitionExecutor
                .selector
        );

        receiver
            .releaseToAcquisition(
                1_000_000,
                keccak256(
                    "ACQ-1"
                )
            );
    }

    function testExactReleaseIsAuditable()
        public
    {
        uint256 received =
            10_000_000;

        uint256 released =
            6_000_000;

        _sync(
            received
        );

        bytes32 acquisitionReference =
            keccak256(
                "ACQ-2"
            );

        vm.prank(
            ACQUISITION_EXECUTOR
        );

        bytes32 releaseId =
            receiver
                .releaseToAcquisition(
                    released,
                    acquisitionReference
                );

        assertTrue(
            releaseId != bytes32(0)
        );

        assertEq(
            usdc.balanceOf(
                ACQUISITION_EXECUTOR
            ),
            released
        );

        assertEq(
            usdc.balanceOf(
                address(receiver)
            ),
            received - released
        );

        assertEq(
            receiver.totalReleased(),
            released
        );

        assertEq(
            receiver
                .availableForAcquisition(),
            received - released
        );

        assertTrue(
            receiver
                .acquisitionReferenceUsed(
                    acquisitionReference
                )
        );
    }

    function testUnsyncedUsdcCannotBeReleased()
        public
    {
        usdc.mint(
            address(receiver),
            10_000_000
        );

        vm.prank(
            ACQUISITION_EXECUTOR
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityBaseReceiver
                    .InsufficientAccountedUsdc
                    .selector,
                uint256(1_000_000),
                uint256(0)
            )
        );

        receiver
            .releaseToAcquisition(
                1_000_000,
                keccak256(
                    "ACQ-3"
                )
            );

        assertEq(
            receiver.totalReleased(),
            0
        );

        assertEq(
            receiver.unsyncedUsdc(),
            10_000_000
        );
    }

    function testPartialTokenTransferRollsBackEntireRelease()
        public
    {
        uint256 amount =
            10_000_000;

        _sync(
            amount
        );

        usdc.setTransferLess(
            true
        );

        vm.prank(
            ACQUISITION_EXECUTOR
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityBaseReceiver
                    .TransferBalanceMismatch
                    .selector,
                uint256(0),
                uint256(1)
            )
        );

        receiver
            .releaseToAcquisition(
                amount,
                keccak256(
                    "ACQ-4"
                )
            );

        assertEq(
            receiver.totalReleased(),
            0
        );

        assertEq(
            usdc.balanceOf(
                address(receiver)
            ),
            amount
        );

        assertEq(
            usdc.balanceOf(
                ACQUISITION_EXECUTOR
            ),
            0
        );
    }

    function testNewReceiptAfterPriorReleaseUsesCorrectDelta()
        public
    {
        _sync(
            10_000_000
        );

        vm.prank(
            ACQUISITION_EXECUTOR
        );

        receiver
            .releaseToAcquisition(
                6_000_000,
                keccak256(
                    "ACQ-5"
                )
            );

        usdc.mint(
            address(receiver),
            2_000_000
        );

        assertEq(
            receiver.unsyncedUsdc(),
            2_000_000
        );

        (
            ,
            uint256 syncedAmount
        ) =
            receiver.sync();

        assertEq(
            syncedAmount,
            2_000_000
        );

        assertEq(
            receiver.totalReceived(),
            12_000_000
        );

        assertEq(
            receiver.totalReleased(),
            6_000_000
        );

        assertEq(
            receiver
                .availableForAcquisition(),
            6_000_000
        );
    }

    function testDuplicateAcquisitionReferenceRejected()
        public
    {
        _sync(
            10_000_000
        );

        bytes32 acquisitionReference =
            keccak256(
                "ACQ-6"
            );

        vm.startPrank(
            ACQUISITION_EXECUTOR
        );

        receiver
            .releaseToAcquisition(
                2_000_000,
                acquisitionReference
            );

        vm.expectRevert(
            TensegrityBaseReceiver
                .DuplicateAcquisitionReference
                .selector
        );

        receiver
            .releaseToAcquisition(
                1_000_000,
                acquisitionReference
            );

        vm.stopPrank();

        assertEq(
            receiver.totalReleased(),
            2_000_000
        );
    }

    function testNativeAssetRejected()
        public
    {
        BaseReceiverNativeSender sender =
            new BaseReceiverNativeSender();

        vm.deal(
            address(this),
            1 ether
        );

        vm.expectRevert(
            TensegrityBaseReceiver
                .NativeAssetRejected
                .selector
        );

        sender.send{
            value: 1 wei
        }(
            payable(
                address(receiver)
            )
        );
    }
}
