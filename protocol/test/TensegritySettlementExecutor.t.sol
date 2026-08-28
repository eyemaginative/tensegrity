// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../lib/uniswap-v4-core-deployed/lib/forge-std/src/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {
    TensegrityFeeHook
} from "../src/TensegrityFeeHook.sol";

import {
    TensegrityFeeVault
} from "../src/TensegrityFeeVault.sol";

import {
    TensegritySettlementExecutor,
    ITensegrityBridgeAdapter
} from "../src/TensegritySettlementExecutor.sol";

contract SettlementTestUSDG {
    mapping(address account => uint256 balance)
        public balanceOf;

    function mint(
        address recipient,
        uint256 amount
    )
        external
    {
        balanceOf[recipient] +=
            amount;
    }

    function transfer(
        address recipient,
        uint256 amount
    )
        external
        returns (bool)
    {
        uint256 current =
            balanceOf[msg.sender];

        require(
            current >= amount,
            "BALANCE"
        );

        unchecked {
            balanceOf[msg.sender] =
                current - amount;
        }

        balanceOf[recipient] +=
            amount;

        return true;
    }
}

contract SettlementTestBridgeAdapter
    is ITensegrityBridgeAdapter
{
    bool public shouldRevert;

    uint256 public totalReceived;
    uint256 public totalHolder;
    uint256 public totalDevelopment;

    bytes32 public lastSettlementId;
    bytes32 public lastBridgeReference;

    error BridgeFailed();

    function setShouldRevert(
        bool value
    )
        external
    {
        shouldRevert =
            value;
    }

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
        if (shouldRevert) {
            revert BridgeFailed();
        }

        totalReceived +=
            amount;

        totalHolder +=
            holderAmount;

        totalDevelopment +=
            developmentAmount;

        lastSettlementId =
            settlementId;

        bridgeReference =
            keccak256(
                abi.encode(
                    settlementId,
                    feeVault,
                    epochId,
                    sequence,
                    amount,
                    holderAmount,
                    developmentAmount
                )
            );

        lastBridgeReference =
            bridgeReference;
    }
}

contract TensegritySettlementExecutorTest
    is Test
{
    address internal constant USDG =
        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address internal constant LBP_STRATEGY =
        0x05d552391067389EE44fec3924157ed33F976000;

    SettlementTestBridgeAdapter
        internal adapter;

    TensegritySettlementExecutor
        internal executor;

    TensegrityFeeHook
        internal hook;

    TensegrityFeeVault
        internal vault;

    function setUp() public {
        SettlementTestUSDG implementation =
            new SettlementTestUSDG();

        vm.etch(
            USDG,
            address(implementation).code
        );

        adapter =
            new SettlementTestBridgeAdapter();

        executor =
            new TensegritySettlementExecutor(
                address(adapter)
            );

        hook =
            new TensegrityFeeHook(
                IPoolManager(
                    address(0x123456)
                ),
                address(executor),
                LBP_STRATEGY,
                2_500,
                60
            );

        vault =
            hook.feeVault();
    }

    function _recordFee(
        uint256 amount
    )
        internal
    {
        SettlementTestUSDG(USDG).mint(
            address(vault),
            amount
        );

        vm.prank(
            address(hook)
        );

        vault.recordFee(
            amount
        );
    }

    function testPermissionlessSettlementRoutesExactUSDG()
        public
    {
        _recordFee(
            3_250_000
        );

        vm.prank(
            address(0xBEEF)
        );

        (
            bytes32 settlementId,
            bytes32 bridgeReference,
            uint256 amount,
            uint256 holderAmount,
            uint256 developmentAmount
        ) =
            executor.settleEpoch(
                address(vault),
                1
            );

        assertTrue(
            settlementId != bytes32(0)
        );

        assertTrue(
            bridgeReference != bytes32(0)
        );

        assertEq(
            amount,
            3_250_000
        );

        assertEq(
            holderAmount,
            3_000_000
        );

        assertEq(
            developmentAmount,
            250_000
        );

        assertEq(
            SettlementTestUSDG(USDG)
                .balanceOf(
                    address(vault)
                ),
            0
        );

        assertEq(
            SettlementTestUSDG(USDG)
                .balanceOf(
                    address(executor)
                ),
            0
        );

        assertEq(
            SettlementTestUSDG(USDG)
                .balanceOf(
                    address(adapter)
                ),
            3_250_000
        );

        assertEq(
            adapter.totalHolder(),
            3_000_000
        );

        assertEq(
            adapter.totalDevelopment(),
            250_000
        );

        (
            uint64 count,
            uint256 total,
            uint256 holderTotal,
            uint256 developmentTotal
        ) =
            executor.getEpochSettlement(
                address(vault),
                1
            );

        assertEq(
            uint256(count),
            1
        );

        assertEq(
            total,
            3_250_000
        );

        assertEq(
            holderTotal,
            3_000_000
        );

        assertEq(
            developmentTotal,
            250_000
        );
    }

    function testMultipleReleasesPreserveCumulativeSplit()
        public
    {
        _recordFee(
            3_250_000
        );

        executor.settleEpoch(
            address(vault),
            1
        );

        _recordFee(
            3_359_174
        );

        (
            ,
            ,
            uint256 amount2,
            uint256 holder2,
            uint256 development2
        ) =
            executor.settleEpoch(
                address(vault),
                1
            );

        assertEq(
            amount2,
            3_359_174
        );

        assertEq(
            holder2,
            3_100_776
        );

        assertEq(
            development2,
            258_398
        );

        (
            uint64 count,
            uint256 total,
            uint256 holderTotal,
            uint256 developmentTotal
        ) =
            executor.getEpochSettlement(
                address(vault),
                1
            );

        assertEq(
            uint256(count),
            2
        );

        assertEq(
            total,
            6_609_174
        );

        assertEq(
            holderTotal,
            6_100_776
        );

        assertEq(
            developmentTotal,
            508_398
        );

        assertEq(
            adapter.totalReceived(),
            6_609_174
        );

        assertEq(
            adapter.totalHolder(),
            6_100_776
        );

        assertEq(
            adapter.totalDevelopment(),
            508_398
        );
    }

    function testRejectNonTensegrityVault()
        public
    {
        TensegrityFeeVault fakeVault =
            new TensegrityFeeVault(
                USDG,
                address(executor)
            );

        SettlementTestUSDG(USDG).mint(
            address(fakeVault),
            3_250_000
        );

        fakeVault.recordFee(
            3_250_000
        );

        vm.expectRevert(
            TensegritySettlementExecutor
                .InvalidFeeVault
                .selector
        );

        executor.settleEpoch(
            address(fakeVault),
            1
        );
    }

    function testBridgeFailureRollsBackFeeVaultRelease()
        public
    {
        _recordFee(
            3_250_000
        );

        adapter.setShouldRevert(
            true
        );

        vm.expectRevert(
            SettlementTestBridgeAdapter
                .BridgeFailed
                .selector
        );

        executor.settleEpoch(
            address(vault),
            1
        );

        assertEq(
            SettlementTestUSDG(USDG)
                .balanceOf(
                    address(vault)
                ),
            3_250_000
        );

        assertEq(
            SettlementTestUSDG(USDG)
                .balanceOf(
                    address(executor)
                ),
            0
        );

        assertEq(
            SettlementTestUSDG(USDG)
                .balanceOf(
                    address(adapter)
                ),
            0
        );

        assertEq(
            vault.accountedOutstanding(),
            3_250_000
        );

        (
            ,
            ,
            ,
            uint256 released,
            uint256 holderReleased,
            uint256 developmentReleased
        ) =
            vault.getEpochAccounting(
                1
            );

        assertEq(
            released,
            0
        );

        assertEq(
            holderReleased,
            0
        );

        assertEq(
            developmentReleased,
            0
        );
    }
}
