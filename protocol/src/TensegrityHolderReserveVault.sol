// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITensegrityReserveAsset {
    function balanceOf(address account)
        external
        view
        returns (uint256);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);
}

contract TensegrityHolderReserveVault {
    uint256 public constant BASE_CHAIN_ID = 8453;

    address public constant CBBTC =
        0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address public constant CBLTC =
        0xcb17C9Db87B595717C857a08468793f5bAb6445F;

    address public constant CBDOGE =
        0xcbD06E5A2B0C65597161de254AA074E489dEb510;

    address public immutable ACQUISITION_EXECUTOR;
    address public immutable REWARD_DISTRIBUTOR;

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
    error DistributorMustBeContract(address distributor);
    error UnauthorizedAcquisitionExecutor(address caller);
    error UnauthorizedRewardDistributor(address caller);
    error UnsupportedAsset(address asset);
    error InvalidAcquisitionReference();
    error ZeroAmount();
    error InvalidRecipient(address recipient);

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
        uint256 recipientIncrease,
        uint256 expectedAmount
    );

    error NativeAssetRejected();

    event AcquisitionRecorded(
        bytes32 indexed acquisitionReference,
        address indexed asset,
        uint256 amount,
        uint256 accountedReserveAfter
    );

    event RewardReleased(
        bytes32 indexed epochId,
        address indexed asset,
        address indexed recipient,
        uint256 amount,
        uint256 accountedReserveAfter
    );

    constructor(
        address acquisitionExecutor,
        address rewardDistributor
    ) {
        if (block.chainid != BASE_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        if (
            acquisitionExecutor == address(0) ||
            rewardDistributor == address(0)
        ) {
            revert ZeroAddress();
        }

        if (acquisitionExecutor == rewardDistributor) {
            revert SameAuthority();
        }

        if (rewardDistributor.code.length == 0) {
            revert DistributorMustBeContract(
                rewardDistributor
            );
        }

        ACQUISITION_EXECUTOR =
            acquisitionExecutor;

        REWARD_DISTRIBUTOR =
            rewardDistributor;
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
            ITensegrityReserveAsset(asset)
                .balanceOf(address(this));

        if (physicalBalance < requiredBalance) {
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

    function releaseReward(
        bytes32 epochId,
        address asset,
        address recipient,
        uint256 amount
    )
        external
    {
        if (msg.sender != REWARD_DISTRIBUTOR) {
            revert UnauthorizedRewardDistributor(
                msg.sender
            );
        }

        _requireSupportedAsset(asset);

        if (
            recipient == address(0) ||
            recipient == address(this)
        ) {
            revert InvalidRecipient(recipient);
        }

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

        ITensegrityReserveAsset token =
            ITensegrityReserveAsset(asset);

        uint256 vaultBalanceBefore =
            token.balanceOf(address(this));

        uint256 recipientBalanceBefore =
            token.balanceOf(recipient);

        accountedReserve[asset] =
            available - amount;

        totalReleased[asset] += amount;

        bool ok =
            token.transfer(
                recipient,
                amount
            );

        if (!ok) {
            revert TokenTransferFailed(
                asset,
                recipient,
                amount
            );
        }

        uint256 vaultBalanceAfter =
            token.balanceOf(address(this));

        uint256 recipientBalanceAfter =
            token.balanceOf(recipient);

        uint256 vaultDecrease;

        if (
            vaultBalanceBefore >=
            vaultBalanceAfter
        ) {
            vaultDecrease =
                vaultBalanceBefore -
                vaultBalanceAfter;
        }

        uint256 recipientIncrease;

        if (
            recipientBalanceAfter >=
            recipientBalanceBefore
        ) {
            recipientIncrease =
                recipientBalanceAfter -
                recipientBalanceBefore;
        }

        if (
            vaultDecrease != amount ||
            recipientIncrease != amount
        ) {
            revert InexactTransfer(
                asset,
                vaultDecrease,
                recipientIncrease,
                amount
            );
        }

        emit RewardReleased(
            epochId,
            asset,
            recipient,
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
            ITensegrityReserveAsset(asset)
                .balanceOf(address(this));

        accountedBalance =
            accountedReserve[asset];

        if (physicalBalance >= accountedBalance) {
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