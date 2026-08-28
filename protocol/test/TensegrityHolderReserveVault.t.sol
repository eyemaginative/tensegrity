// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Test
} from "../lib/uniswap-v4-core-deployed/lib/forge-std/src/Test.sol";

import {
    TensegrityHolderReserveVault
} from "../src/TensegrityHolderReserveVault.sol";

contract HolderReserveTestToken {
    mapping(address account => uint256 balance)
        public balanceOf;

    bool public failTransfers;
    uint256 public transferShortfall;

    function mint(address recipient, uint256 amount)
        external
    {
        balanceOf[recipient] += amount;
    }

    function setFailTransfers(bool value)
        external
    {
        failTransfers = value;
    }

    function setTransferShortfall(uint256 value)
        external
    {
        transferShortfall = value;
    }

    function transfer(address recipient, uint256 amount)
        external
        returns (bool)
    {
        if (failTransfers) {
            return false;
        }

        require(
            balanceOf[msg.sender] >= amount,
            "BALANCE"
        );

        balanceOf[msg.sender] -= amount;

        uint256 delivered = amount;

        if (
            transferShortfall > 0 &&
            amount > transferShortfall
        ) {
            delivered =
                amount -
                transferShortfall;
        }

        balanceOf[recipient] += delivered;

        return true;
    }
}

contract HolderReserveTestDistributor {
    function release(
        TensegrityHolderReserveVault vault,
        bytes32 epochId,
        address asset,
        address recipient,
        uint256 amount
    )
        external
    {
        vault.releaseReward(
            epochId,
            asset,
            recipient,
            amount
        );
    }
}

contract TensegrityHolderReserveVaultTest
    is Test
{
    address internal constant CBBTC =
        0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address internal constant CBLTC =
        0xcb17C9Db87B595717C857a08468793f5bAb6445F;

    address internal constant CBDOGE =
        0xcbD06E5A2B0C65597161de254AA074E489dEb510;

    address internal constant ACQUISITION_EXECUTOR =
        address(0xA11CE);

    address internal constant HOLDER =
        address(0xB0B);

    bytes32 internal constant ACQUISITION_REFERENCE =
        keccak256("ACQUISITION-1");

    bytes32 internal constant EPOCH_ID =
        keccak256("EPOCH-1");

    HolderReserveTestDistributor
        internal distributor;

    TensegrityHolderReserveVault
        internal vault;

    function setUp() public {
        vm.chainId(8453);

        HolderReserveTestToken tokenImplementation =
            new HolderReserveTestToken();

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

        distributor =
            new HolderReserveTestDistributor();

        vault =
            new TensegrityHolderReserveVault(
                ACQUISITION_EXECUTOR,
                address(distributor)
            );
    }

    function testConstructorRequiresBase()
        public
    {
        vm.chainId(4663);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .WrongChain.selector,
                uint256(4663)
            )
        );

        new TensegrityHolderReserveVault(
            ACQUISITION_EXECUTOR,
            address(distributor)
        );
    }

    function testConstructorRequiresNonzeroAuthorities()
        public
    {
        vm.expectRevert(
            TensegrityHolderReserveVault
                .ZeroAddress.selector
        );

        new TensegrityHolderReserveVault(
            address(0),
            address(distributor)
        );

        vm.expectRevert(
            TensegrityHolderReserveVault
                .ZeroAddress.selector
        );

        new TensegrityHolderReserveVault(
            ACQUISITION_EXECUTOR,
            address(0)
        );
    }

    function testDistributorMustBeContract()
        public
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .DistributorMustBeContract.selector,
                address(0xD157)
            )
        );

        new TensegrityHolderReserveVault(
            ACQUISITION_EXECUTOR,
            address(0xD157)
        );
    }

    function testAuthoritiesMustDiffer()
        public
    {
        address same =
            address(distributor);

        vm.expectRevert(
            TensegrityHolderReserveVault
                .SameAuthority.selector
        );

        new TensegrityHolderReserveVault(
            same,
            same
        );
    }

    function testCanonicalAssetsAndBindings()
        public
        view
    {
        assertEq(
            vault.BASE_CHAIN_ID(),
            8453
        );

        assertEq(vault.CBBTC(), CBBTC);
        assertEq(vault.CBLTC(), CBLTC);
        assertEq(vault.CBDOGE(), CBDOGE);

        assertEq(
            vault.ACQUISITION_EXECUTOR(),
            ACQUISITION_EXECUTOR
        );

        assertEq(
            vault.REWARD_DISTRIBUTOR(),
            address(distributor)
        );

        assertTrue(
            vault.isSupportedAsset(CBBTC)
        );

        assertTrue(
            vault.isSupportedAsset(CBLTC)
        );

        assertTrue(
            vault.isSupportedAsset(CBDOGE)
        );

        assertFalse(
            vault.isSupportedAsset(
                address(0xDEAD)
            )
        );
    }

    function testOnlyAcquisitionExecutorCanRecord()
        public
    {
        _mintToVault(CBBTC, 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .UnauthorizedAcquisitionExecutor
                    .selector,
                address(this)
            )
        );

        vault.recordAcquisition(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );
    }

    function testRecordRequiresPhysicalReserve()
        public
    {
        vm.prank(ACQUISITION_EXECUTOR);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .InsufficientPhysicalReserve
                    .selector,
                CBBTC,
                uint256(0),
                uint256(100)
            )
        );

        vault.recordAcquisition(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );
    }

    function testRecordTracksAccountedAndSurplus()
        public
    {
        _mintToVault(CBBTC, 110);

        _record(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );

        assertEq(
            vault.accountedReserve(CBBTC),
            100
        );

        assertEq(
            vault.totalRecorded(CBBTC),
            100
        );

        assertEq(
            vault.totalReleased(CBBTC),
            0
        );

        (
            uint256 physical,
            uint256 accounted,
            uint256 surplus,
            uint256 deficit,
            uint256 recorded,
            uint256 released
        ) =
            vault.reserveStatus(CBBTC);

        assertEq(physical, 110);
        assertEq(accounted, 100);
        assertEq(surplus, 10);
        assertEq(deficit, 0);
        assertEq(recorded, 100);
        assertEq(released, 0);
    }

    function testDuplicateReferenceIsPerAsset()
        public
    {
        _mintToVault(CBBTC, 100);
        _mintToVault(CBLTC, 200);

        _record(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );

        _record(
            ACQUISITION_REFERENCE,
            CBLTC,
            200
        );

        vm.prank(ACQUISITION_EXECUTOR);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .AcquisitionAlreadyRecorded
                    .selector,
                ACQUISITION_REFERENCE,
                CBBTC
            )
        );

        vault.recordAcquisition(
            ACQUISITION_REFERENCE,
            CBBTC,
            1
        );

        assertEq(
            vault.accountedReserve(CBBTC),
            100
        );

        assertEq(
            vault.accountedReserve(CBLTC),
            200
        );
    }

    function testOnlyRewardDistributorCanRelease()
        public
    {
        _fundAndRecord(CBBTC, 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .UnauthorizedRewardDistributor
                    .selector,
                address(this)
            )
        );

        vault.releaseReward(
            EPOCH_ID,
            CBBTC,
            HOLDER,
            10
        );
    }

    function testReleaseUpdatesAccounting()
        public
    {
        _fundAndRecord(CBBTC, 100);

        distributor.release(
            vault,
            EPOCH_ID,
            CBBTC,
            HOLDER,
            40
        );

        assertEq(
            HolderReserveTestToken(CBBTC)
                .balanceOf(HOLDER),
            40
        );

        assertEq(
            vault.accountedReserve(CBBTC),
            60
        );

        assertEq(
            vault.totalRecorded(CBBTC),
            100
        );

        assertEq(
            vault.totalReleased(CBBTC),
            40
        );

        (
            uint256 physical,
            uint256 accounted,
            uint256 surplus,
            uint256 deficit,
            ,
        ) =
            vault.reserveStatus(CBBTC);

        assertEq(physical, 60);
        assertEq(accounted, 60);
        assertEq(surplus, 0);
        assertEq(deficit, 0);
    }

    function testSurplusCannotBeReleased()
        public
    {
        _mintToVault(CBBTC, 150);

        _record(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .InsufficientAccountedReserve
                    .selector,
                CBBTC,
                uint256(100),
                uint256(101)
            )
        );

        distributor.release(
            vault,
            EPOCH_ID,
            CBBTC,
            HOLDER,
            101
        );

        assertEq(
            HolderReserveTestToken(CBBTC)
                .balanceOf(address(vault)),
            150
        );

        assertEq(
            vault.accountedReserve(CBBTC),
            100
        );
    }

    function testTransferFailureRollsBack()
        public
    {
        _fundAndRecord(CBBTC, 100);

        HolderReserveTestToken(CBBTC)
            .setFailTransfers(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .TokenTransferFailed
                    .selector,
                CBBTC,
                HOLDER,
                uint256(40)
            )
        );

        distributor.release(
            vault,
            EPOCH_ID,
            CBBTC,
            HOLDER,
            40
        );

        assertEq(
            vault.accountedReserve(CBBTC),
            100
        );

        assertEq(
            vault.totalReleased(CBBTC),
            0
        );

        assertEq(
            HolderReserveTestToken(CBBTC)
                .balanceOf(address(vault)),
            100
        );
    }

    function testInexactTransferRollsBack()
        public
    {
        _fundAndRecord(CBBTC, 100);

        HolderReserveTestToken(CBBTC)
            .setTransferShortfall(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .InexactTransfer
                    .selector,
                CBBTC,
                uint256(40),
                uint256(39),
                uint256(40)
            )
        );

        distributor.release(
            vault,
            EPOCH_ID,
            CBBTC,
            HOLDER,
            40
        );

        assertEq(
            vault.accountedReserve(CBBTC),
            100
        );

        assertEq(
            vault.totalReleased(CBBTC),
            0
        );

        assertEq(
            HolderReserveTestToken(CBBTC)
                .balanceOf(HOLDER),
            0
        );

        assertEq(
            HolderReserveTestToken(CBBTC)
                .balanceOf(address(vault)),
            100
        );
    }

    function testUnsupportedAssetRejected()
        public
    {
        address unsupported =
            address(0xDEAD);

        vm.prank(ACQUISITION_EXECUTOR);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .UnsupportedAsset.selector,
                unsupported
            )
        );

        vault.recordAcquisition(
            ACQUISITION_REFERENCE,
            unsupported,
            1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .UnsupportedAsset.selector,
                unsupported
            )
        );

        distributor.release(
            vault,
            EPOCH_ID,
            unsupported,
            HOLDER,
            1
        );
    }

    function testZeroAmountAndInvalidRecipientRejected()
        public
    {
        _fundAndRecord(CBBTC, 100);

        vm.expectRevert(
            TensegrityHolderReserveVault
                .ZeroAmount.selector
        );

        distributor.release(
            vault,
            EPOCH_ID,
            CBBTC,
            HOLDER,
            0
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .InvalidRecipient.selector,
                address(0)
            )
        );

        distributor.release(
            vault,
            EPOCH_ID,
            CBBTC,
            address(0),
            1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityHolderReserveVault
                    .InvalidRecipient.selector,
                address(vault)
            )
        );

        distributor.release(
            vault,
            EPOCH_ID,
            CBBTC,
            address(vault),
            1
        );
    }

    function testNativeEthRejected()
        public
    {
        vm.deal(address(this), 1 ether);

        (bool ok,) =
            address(vault).call{
                value: 1
            }("");

        assertFalse(ok);

        assertEq(
            address(vault).balance,
            0
        );
    }

    function _fundAndRecord(
        address asset,
        uint256 amount
    )
        private
    {
        _mintToVault(asset, amount);

        _record(
            ACQUISITION_REFERENCE,
            asset,
            amount
        );
    }

    function _mintToVault(
        address asset,
        uint256 amount
    )
        private
    {
        HolderReserveTestToken(asset)
            .mint(
                address(vault),
                amount
            );
    }

    function _record(
        bytes32 acquisitionReference,
        address asset,
        uint256 amount
    )
        private
    {
        vm.prank(ACQUISITION_EXECUTOR);

        vault.recordAcquisition(
            acquisitionReference,
            asset,
            amount
        );
    }
}