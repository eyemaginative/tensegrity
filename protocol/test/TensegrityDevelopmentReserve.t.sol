// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Test
} from "../lib/uniswap-v4-core-deployed/lib/forge-std/src/Test.sol";

import {
    TensegrityDevelopmentReserve
} from "../src/TensegrityDevelopmentReserve.sol";

contract DevelopmentReserveTestToken {
    mapping(address account => uint256 balance)
        public balanceOf;

    bool public transfersReturnFalse;

    uint256 public transferShortfall;

    function mint(
        address recipient,
        uint256 amount
    )
        external
    {
        balanceOf[recipient] += amount;
    }

    function setTransfersReturnFalse(
        bool value
    )
        external
    {
        transfersReturnFalse = value;
    }

    function setTransferShortfall(
        uint256 value
    )
        external
    {
        transferShortfall = value;
    }

    function transfer(
        address recipient,
        uint256 amount
    )
        external
        returns (bool)
    {
        if (transfersReturnFalse) {
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

contract TensegrityDevelopmentReserveTest
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

    address internal constant DEVELOPMENT_BENEFICIARY =
        address(0xD3E);

    bytes32 internal constant ACQUISITION_REFERENCE =
        keccak256("DEV-ACQUISITION-1");

    TensegrityDevelopmentReserve
        internal reserve;

    function setUp() public {
        vm.chainId(8453);

        DevelopmentReserveTestToken
            tokenImplementation =
                new DevelopmentReserveTestToken();

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

        reserve =
            new TensegrityDevelopmentReserve(
                ACQUISITION_EXECUTOR,
                DEVELOPMENT_BENEFICIARY
            );
    }

    function testConstructorRequiresBase()
        public
    {
        vm.chainId(4663);

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .WrongChain.selector,
                uint256(4663)
            )
        );

        new TensegrityDevelopmentReserve(
            ACQUISITION_EXECUTOR,
            DEVELOPMENT_BENEFICIARY
        );
    }

    function testConstructorRequiresNonzeroAuthorities()
        public
    {
        vm.expectRevert(
            TensegrityDevelopmentReserve
                .ZeroAddress.selector
        );

        new TensegrityDevelopmentReserve(
            address(0),
            DEVELOPMENT_BENEFICIARY
        );

        vm.expectRevert(
            TensegrityDevelopmentReserve
                .ZeroAddress.selector
        );

        new TensegrityDevelopmentReserve(
            ACQUISITION_EXECUTOR,
            address(0)
        );
    }

    function testAuthoritiesMustDiffer()
        public
    {
        address same =
            DEVELOPMENT_BENEFICIARY;

        vm.expectRevert(
            TensegrityDevelopmentReserve
                .SameAuthority.selector
        );

        new TensegrityDevelopmentReserve(
            same,
            same
        );
    }

    function testCanonicalAssetsAndBindings()
        public
        view
    {
        assertEq(
            reserve.BASE_CHAIN_ID(),
            8453
        );

        assertEq(
            reserve.CBBTC(),
            CBBTC
        );

        assertEq(
            reserve.CBLTC(),
            CBLTC
        );

        assertEq(
            reserve.CBDOGE(),
            CBDOGE
        );

        assertEq(
            reserve.ACQUISITION_EXECUTOR(),
            ACQUISITION_EXECUTOR
        );

        assertEq(
            reserve.DEVELOPMENT_BENEFICIARY(),
            DEVELOPMENT_BENEFICIARY
        );

        assertTrue(
            reserve.isSupportedAsset(CBBTC)
        );

        assertTrue(
            reserve.isSupportedAsset(CBLTC)
        );

        assertTrue(
            reserve.isSupportedAsset(CBDOGE)
        );

        assertFalse(
            reserve.isSupportedAsset(
                address(0xDEAD)
            )
        );
    }

    function testOnlyAcquisitionExecutorCanRecord()
        public
    {
        _mintToReserve(
            CBBTC,
            100
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .UnauthorizedAcquisitionExecutor
                    .selector,
                address(this)
            )
        );

        reserve.recordAcquisition(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );
    }

    function testRecordRequiresPhysicalReserve()
        public
    {
        vm.prank(
            ACQUISITION_EXECUTOR
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .InsufficientPhysicalReserve
                    .selector,
                CBBTC,
                uint256(0),
                uint256(100)
            )
        );

        reserve.recordAcquisition(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );
    }

    function testRecordRejectsInvalidReferenceAndZeroAmount()
        public
    {
        _mintToReserve(
            CBBTC,
            100
        );

        vm.prank(
            ACQUISITION_EXECUTOR
        );

        vm.expectRevert(
            TensegrityDevelopmentReserve
                .InvalidAcquisitionReference
                .selector
        );

        reserve.recordAcquisition(
            bytes32(0),
            CBBTC,
            100
        );

        vm.prank(
            ACQUISITION_EXECUTOR
        );

        vm.expectRevert(
            TensegrityDevelopmentReserve
                .ZeroAmount.selector
        );

        reserve.recordAcquisition(
            ACQUISITION_REFERENCE,
            CBBTC,
            0
        );
    }

    function testRecordTracksAccountedAndSurplus()
        public
    {
        _mintToReserve(
            CBBTC,
            110
        );

        _record(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );

        assertEq(
            reserve.accountedReserve(CBBTC),
            100
        );

        assertEq(
            reserve.totalRecorded(CBBTC),
            100
        );

        assertEq(
            reserve.totalReleased(CBBTC),
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
            reserve.reserveStatus(CBBTC);

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
        _mintToReserve(
            CBBTC,
            100
        );

        _mintToReserve(
            CBLTC,
            200
        );

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

        vm.prank(
            ACQUISITION_EXECUTOR
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .AcquisitionAlreadyRecorded
                    .selector,
                ACQUISITION_REFERENCE,
                CBBTC
            )
        );

        reserve.recordAcquisition(
            ACQUISITION_REFERENCE,
            CBBTC,
            1
        );

        assertEq(
            reserve.accountedReserve(CBBTC),
            100
        );

        assertEq(
            reserve.accountedReserve(CBLTC),
            200
        );
    }

    function testOnlyBeneficiaryCanRelease()
        public
    {
        _fundAndRecord(
            CBBTC,
            100
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .UnauthorizedDevelopmentBeneficiary
                    .selector,
                address(this)
            )
        );

        reserve.releaseDevelopment(
            CBBTC,
            10
        );
    }

    function testReleasePaysImmutableBeneficiary()
        public
    {
        _fundAndRecord(
            CBBTC,
            100
        );

        address unrelated =
            address(0xB0B);

        vm.prank(
            DEVELOPMENT_BENEFICIARY
        );

        reserve.releaseDevelopment(
            CBBTC,
            40
        );

        assertEq(
            DevelopmentReserveTestToken(
                CBBTC
            ).balanceOf(
                DEVELOPMENT_BENEFICIARY
            ),
            40
        );

        assertEq(
            DevelopmentReserveTestToken(
                CBBTC
            ).balanceOf(unrelated),
            0
        );
    }

    function testReleaseUpdatesAccounting()
        public
    {
        _fundAndRecord(
            CBBTC,
            100
        );

        vm.prank(
            DEVELOPMENT_BENEFICIARY
        );

        reserve.releaseDevelopment(
            CBBTC,
            40
        );

        assertEq(
            reserve.accountedReserve(CBBTC),
            60
        );

        assertEq(
            reserve.totalRecorded(CBBTC),
            100
        );

        assertEq(
            reserve.totalReleased(CBBTC),
            40
        );

        (
            uint256 physical,
            uint256 accounted,
            uint256 surplus,
            uint256 deficit,
            ,
        ) =
            reserve.reserveStatus(CBBTC);

        assertEq(physical, 60);
        assertEq(accounted, 60);
        assertEq(surplus, 0);
        assertEq(deficit, 0);
    }

    function testSurplusCannotBeReleased()
        public
    {
        _mintToReserve(
            CBBTC,
            150
        );

        _record(
            ACQUISITION_REFERENCE,
            CBBTC,
            100
        );

        vm.prank(
            DEVELOPMENT_BENEFICIARY
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .InsufficientAccountedReserve
                    .selector,
                CBBTC,
                uint256(100),
                uint256(101)
            )
        );

        reserve.releaseDevelopment(
            CBBTC,
            101
        );

        assertEq(
            DevelopmentReserveTestToken(
                CBBTC
            ).balanceOf(
                address(reserve)
            ),
            150
        );

        assertEq(
            reserve.accountedReserve(CBBTC),
            100
        );
    }

    function testTransferFailureRollsBack()
        public
    {
        _fundAndRecord(
            CBBTC,
            100
        );

        DevelopmentReserveTestToken(
            CBBTC
        ).setTransfersReturnFalse(true);

        vm.prank(
            DEVELOPMENT_BENEFICIARY
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .TokenTransferFailed
                    .selector,
                CBBTC,
                DEVELOPMENT_BENEFICIARY,
                uint256(40)
            )
        );

        reserve.releaseDevelopment(
            CBBTC,
            40
        );

        assertEq(
            reserve.accountedReserve(CBBTC),
            100
        );

        assertEq(
            reserve.totalReleased(CBBTC),
            0
        );

        assertEq(
            DevelopmentReserveTestToken(
                CBBTC
            ).balanceOf(
                address(reserve)
            ),
            100
        );
    }

    function testInexactTransferRollsBack()
        public
    {
        _fundAndRecord(
            CBBTC,
            100
        );

        DevelopmentReserveTestToken(
            CBBTC
        ).setTransferShortfall(1);

        vm.prank(
            DEVELOPMENT_BENEFICIARY
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .InexactTransfer.selector,
                CBBTC,
                uint256(40),
                uint256(39),
                uint256(40)
            )
        );

        reserve.releaseDevelopment(
            CBBTC,
            40
        );

        assertEq(
            reserve.accountedReserve(CBBTC),
            100
        );

        assertEq(
            reserve.totalReleased(CBBTC),
            0
        );

        assertEq(
            DevelopmentReserveTestToken(
                CBBTC
            ).balanceOf(
                DEVELOPMENT_BENEFICIARY
            ),
            0
        );

        assertEq(
            DevelopmentReserveTestToken(
                CBBTC
            ).balanceOf(
                address(reserve)
            ),
            100
        );
    }

    function testUnsupportedAssetRejected()
        public
    {
        address unsupported =
            address(0xDEAD);

        vm.prank(
            ACQUISITION_EXECUTOR
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .UnsupportedAsset.selector,
                unsupported
            )
        );

        reserve.recordAcquisition(
            ACQUISITION_REFERENCE,
            unsupported,
            1
        );

        vm.prank(
            DEVELOPMENT_BENEFICIARY
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TensegrityDevelopmentReserve
                    .UnsupportedAsset.selector,
                unsupported
            )
        );

        reserve.releaseDevelopment(
            unsupported,
            1
        );
    }

    function testReleaseRejectsZeroAmount()
        public
    {
        _fundAndRecord(
            CBBTC,
            100
        );

        vm.prank(
            DEVELOPMENT_BENEFICIARY
        );

        vm.expectRevert(
            TensegrityDevelopmentReserve
                .ZeroAmount.selector
        );

        reserve.releaseDevelopment(
            CBBTC,
            0
        );
    }

    function testNativeEthRejected()
        public
    {
        vm.deal(
            address(this),
            1 ether
        );

        (bool ok,) =
            address(reserve).call{
                value: 1
            }("");

        assertFalse(ok);

        assertEq(
            address(reserve).balance,
            0
        );
    }

    function _fundAndRecord(
        address asset,
        uint256 amount
    )
        private
    {
        _mintToReserve(
            asset,
            amount
        );

        _record(
            ACQUISITION_REFERENCE,
            asset,
            amount
        );
    }

    function _mintToReserve(
        address asset,
        uint256 amount
    )
        private
    {
        DevelopmentReserveTestToken(
            asset
        ).mint(
            address(reserve),
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
        vm.prank(
            ACQUISITION_EXECUTOR
        );

        reserve.recordAcquisition(
            acquisitionReference,
            asset,
            amount
        );
    }
}