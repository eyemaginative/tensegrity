// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITensegrityDevelopmentReserveAsset {
    function balanceOf(address account)
        external
        view
        returns (uint256);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);
}

contract TensegrityDevelopmentReserve {
    uint256 public constant BASE_CHAIN_ID = 8453;

    address public constant CBBTC =
        0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address public constant CBLTC =
        0xcb17C9Db87B595717C857a08468793f5bAb6445F;

    address public constant CBDOGE =
        0xcbD06E5A2B0C65597161de254AA074E489dEb510;

    address public immutable ACQUISITION_EXECUTOR;
    address public immutable DEVELOPMENT_BENEFICIARY;

    mapping(address asset => uint256 amount)
        public accountedReserve;

    mapping(address asset => uint256 amount)
        public totalRecorded;

    mapping(address asset => uint256 amount)
        public totalReleased;

    mapping(
        bytes32 acquisitionReference =>
            mapping(address asset => bool recorded)
    )
        public acquisitionRecorded;

    error WrongChain(uint256 chainId);
    error ZeroAddress();
    error SameAuthority();

    error UnauthorizedAcquisitionExecutor(
        address caller
    );

    error UnauthorizedDevelopmentBeneficiary(
        address caller
    );

    error UnsupportedAsset(address asset);
    error InvalidAcquisitionReference();
    error ZeroAmount();

    error AcquisitionAlreadyRecorded(
        bytes32 acquisitionReference,
        address asset
    );

    error InsufficientPhysicalReserve(
        address asset,
        uint256 physicalBalance,
        uint256 requiredBalance
    );

    error InsufficientAccountedReserve(
        address asset,
        uint256 available,
        uint256 requested
    );

    error TokenTransferFailed(
        address asset,
        address recipient,
        uint256 amount
    );

    error InexactTransfer(
        address asset,
        uint256 vaultDecrease,
        uint256 beneficiaryIncrease,
        uint256 expectedAmount
    );

    error NativeAssetRejected();

    event AcquisitionRecorded(
        bytes32 indexed acquisitionReference,
        address indexed asset,
        uint256 amount,
        uint256 accountedReserveAfter
    );

    event DevelopmentReleased(
        address indexed asset,
        address indexed beneficiary,
        uint256 amount,
        uint256 accountedReserveAfter
    );

    constructor(
        address acquisitionExecutor,
        address developmentBeneficiary
    ) {
        if (block.chainid != BASE_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        if (
            acquisitionExecutor == address(0) ||
            developmentBeneficiary == address(0)
        ) {
            revert ZeroAddress();
        }

        if (
            acquisitionExecutor ==
            developmentBeneficiary
        ) {
            revert SameAuthority();
        }

        ACQUISITION_EXECUTOR =
            acquisitionExecutor;

        DEVELOPMENT_BENEFICIARY =
            developmentBeneficiary;
    }

    receive() external payable {
        revert NativeAssetRejected();
    }

    function isSupportedAsset(address asset)
        public
        pure
        returns (bool)
    {
        return
            asset == CBBTC ||
            asset == CBLTC ||
            asset == CBDOGE;
    }

    function recordAcquisition(
        bytes32 acquisitionReference,
        address asset,
        uint256 amount
    )
        external
    {
        if (msg.sender != ACQUISITION_EXECUTOR) {
            revert UnauthorizedAcquisitionExecutor(
                msg.sender
            );
        }

        _requireSupportedAsset(asset);

        if (acquisitionReference == bytes32(0)) {
            revert InvalidAcquisitionReference();
        }

        if (amount == 0) {
            revert ZeroAmount();
        }

        if (
            acquisitionRecorded[
                acquisitionReference
            ][asset]
        ) {
            revert AcquisitionAlreadyRecorded(
                acquisitionReference,
                asset
            );
        }

        uint256 currentAccounted =
            accountedReserve[asset];

        uint256 requiredBalance =
            currentAccounted + amount;

        uint256 physicalBalance =
            ITensegrityDevelopmentReserveAsset(
                asset
            ).balanceOf(address(this));

        if (
            physicalBalance <
            requiredBalance
        ) {
            revert InsufficientPhysicalReserve(
                asset,
                physicalBalance,
                requiredBalance
            );
        }

        acquisitionRecorded[
            acquisitionReference
        ][asset] = true;

        accountedReserve[asset] =
            requiredBalance;

        totalRecorded[asset] += amount;

        emit AcquisitionRecorded(
            acquisitionReference,
            asset,
            amount,
            requiredBalance
        );
    }

    function releaseDevelopment(
        address asset,
        uint256 amount
    )
        external
    {
        if (
            msg.sender !=
            DEVELOPMENT_BENEFICIARY
        ) {
            revert UnauthorizedDevelopmentBeneficiary(
                msg.sender
            );
        }

        _requireSupportedAsset(asset);

        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 available =
            accountedReserve[asset];

        if (amount > available) {
            revert InsufficientAccountedReserve(
                asset,
                available,
                amount
            );
        }

        ITensegrityDevelopmentReserveAsset token =
            ITensegrityDevelopmentReserveAsset(
                asset
            );

        uint256 vaultBalanceBefore =
            token.balanceOf(address(this));

        uint256 beneficiaryBalanceBefore =
            token.balanceOf(
                DEVELOPMENT_BENEFICIARY
            );

        accountedReserve[asset] =
            available - amount;

        totalReleased[asset] += amount;

        bool ok =
            token.transfer(
                DEVELOPMENT_BENEFICIARY,
                amount
            );

        if (!ok) {
            revert TokenTransferFailed(
                asset,
                DEVELOPMENT_BENEFICIARY,
                amount
            );
        }

        uint256 vaultBalanceAfter =
            token.balanceOf(address(this));

        uint256 beneficiaryBalanceAfter =
            token.balanceOf(
                DEVELOPMENT_BENEFICIARY
            );

        uint256 vaultDecrease;

        if (
            vaultBalanceBefore >=
            vaultBalanceAfter
        ) {
            vaultDecrease =
                vaultBalanceBefore -
                vaultBalanceAfter;
        }

        uint256 beneficiaryIncrease;

        if (
            beneficiaryBalanceAfter >=
            beneficiaryBalanceBefore
        ) {
            beneficiaryIncrease =
                beneficiaryBalanceAfter -
                beneficiaryBalanceBefore;
        }

        if (
            vaultDecrease != amount ||
            beneficiaryIncrease != amount
        ) {
            revert InexactTransfer(
                asset,
                vaultDecrease,
                beneficiaryIncrease,
                amount
            );
        }

        emit DevelopmentReleased(
            asset,
            DEVELOPMENT_BENEFICIARY,
            amount,
            available - amount
        );
    }

    function reserveStatus(address asset)
        external
        view
        returns (
            uint256 physicalBalance,
            uint256 accountedBalance,
            uint256 surplus,
            uint256 deficit,
            uint256 recorded,
            uint256 released
        )
    {
        _requireSupportedAsset(asset);

        physicalBalance =
            ITensegrityDevelopmentReserveAsset(
                asset
            ).balanceOf(address(this));

        accountedBalance =
            accountedReserve[asset];

        if (
            physicalBalance >=
            accountedBalance
        ) {
            surplus =
                physicalBalance -
                accountedBalance;
        } else {
            deficit =
                accountedBalance -
                physicalBalance;
        }

        recorded =
            totalRecorded[asset];

        released =
            totalReleased[asset];
    }

    function _requireSupportedAsset(address asset)
        private
        pure
    {
        if (!isSupportedAsset(asset)) {
            revert UnsupportedAsset(asset);
        }
    }
}