// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.15;

import "./base/VaultControllerStrategy.sol";
import "./interfaces/ICommunityVault.sol";

import "hardhat/console.sol";

/**
 * @title Community Vault Controller Strategy
 * @notice Implemented strategy for managing multiple Chainlink community staking vaults
 */
contract CommunityVCS is VaultControllerStrategy {
    // min number of non-full vaults before a new batch is deployed
    uint128 public vaultDeploymentThreshold;
    // number of vaults to deploy when threshold is met
    uint128 public vaultDeploymentAmount;

    event SetVaultDeploymentParams(uint128 vaultDeploymentThreshold, uint128 vaultDeploymentAmount);

    error VaultsAboveThreshold();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes contract
     * @param _token address of LINK token
     * @param _stakingPool address of the staking pool that controls this strategy
     * @param _stakeController address of Chainlink staking contract
     * @param _vaultImplementation address of the implementation contract to use when deploying new vaults
     * @param _fees list of fees to be paid on rewards
     * @param _maxDepositSizeBP max basis point amount of the deposit room in the Chainlink staking contract
     * that can be deposited at once
     * @param _vaultMaxDeposits max number of tokens that a vault can hold
     * @param _vaultDeploymentThreshold min number of non-full vaults before a new batch is deployed
     * @param _vaultDeploymentAmount number of vaults to deploy when threshold is met
     * @param _vaultDepositController address of vault deposit controller
     *
     */
    function initialize(
        address _token,
        address _stakingPool,
        address _stakeController,
        address _vaultImplementation,
        Fee[] memory _fees,
        uint256 _maxDepositSizeBP,
        uint256 _vaultMaxDeposits,
        uint128 _vaultDeploymentThreshold,
        uint128 _vaultDeploymentAmount,
        address _vaultDepositController
    ) public initializer {
        if (address(token) == address(0)) {
            __VaultControllerStrategy_init(
                _token,
                _stakingPool,
                _stakeController,
                _vaultImplementation,
                _fees,
                _maxDepositSizeBP,
                _vaultMaxDeposits,
                _vaultDepositController
            );

            vaultDeploymentThreshold = _vaultDeploymentThreshold;
            vaultDeploymentAmount = _vaultDeploymentAmount;
            _deployVaults(_vaultDeploymentAmount);
            globalVaultState = GlobalVaultState(5, 0, 0, 0);
        } else {
            //this has already been deployed - update some params
            globalVaultState = GlobalVaultState(5, 0, 0, uint64(maxDepositSizeBP + 1));
            maxDepositSizeBP = _maxDepositSizeBP;
            delete fundFlowController;
            vaultMaxDeposits = _vaultMaxDeposits;
        }

        //@audit-ok this should not be required if we already initialized this contract => second case above
        //console.log("Push Vaults");
        for (uint64 i = 0; i < 5; ++i) {
            vaultGroups.push(VaultGroup(i, 0));
        }
    }

    /**
     * @notice Deposits tokens from the staking pool into vaults
     * @param _amount amount to deposit
     * @param _data encoded vault deposit order
     */
    function deposit(uint256 _amount, bytes calldata _data) external override onlyStakingPool {
        (, uint256 maxDeposits) = getVaultDepositLimits();

        // if vault deposit limit has changed in Chainlink staking contract, make adjustments
        if (maxDeposits > vaultMaxDeposits) {
            uint256 diff = maxDeposits - vaultMaxDeposits; // 200
            uint256 totalVaults = globalVaultState.depositIndex; // 13  index of next non-group vault to receive deposits
            uint256 numVaultGroups = globalVaultState.numVaultGroups; // 5

            uint256 vaultsPerGroup = totalVaults / numVaultGroups; // 13/5 = 2
            uint256 remainder = totalVaults % numVaultGroups; // 13%5 = 3

            // for our example, we need to add 3 vaults
            for (uint256 i = 0; i < numVaultGroups; ++i) {
                uint256 numVaults = vaultsPerGroup; // 13/5 = 2
                if (i < remainder) {
                    numVaults += 1; // 1 vault will be added for indexes: 0,1,2 => total: 3 vaults
                }

                //re-calc totalDepositRoom for each vaultGroup
                vaultGroups[i].totalDepositRoom += uint128(numVaults * diff);
            }

            vaultMaxDeposits = maxDeposits;
        }

        if (vaultDepositController == address(0)) revert VaultDepositControllerNotSet();

        (bool success, ) = vaultDepositController.delegatecall(
            abi.encodeWithSelector(VaultDepositController.deposit.selector, _amount, _data)
        );

        if (!success) revert DepositFailed();
    }

    /**
     * @notice Claims Chanlink staking rewards from vaults
     * @param _vaults list if vault indexes to claim from
     * @param _minRewards min amount of rewards per vault required to claim
     */
    function claimRewards(
        uint256[] calldata _vaults,
        uint256 _minRewards
    ) external returns (uint256) {
        address receiver = address(this);
        uint256 balanceBefore = token.balanceOf(address(this));

        for (uint256 i = 0; i < _vaults.length; ++i) {
            ICommunityVault(address(vaults[_vaults[i]])).claimRewards(_minRewards, receiver);
        }
        uint256 balanceAfter = token.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    /**
     * @notice Returns the maximum amount of tokens this strategy can hold
     * @return maximum deposits
     */
    function getMaxDeposits() public view virtual override returns (uint256) {
        //@audit-ok why 0 if we find a MR ?
        return stakeController.getMerkleRoot() == bytes32(0) ? super.getMaxDeposits() : 0;
    }

    /**
     * @notice Returns whether a new batch of vaults should be deployed
     * @return true if new batch should be deployed, false otherwise
     */
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        // min number of non-full vaults before a new batch is deployed
        //@audit-ok  should be: ...  <= vaultDeploymentThreshold according to docs
        return (
            //10 - 7 = 3 ==> 4 non-full vaults  < 3
            (vaults.length - globalVaultState.depositIndex) < vaultDeploymentThreshold,
            bytes("")
        );
    }

    /**
     * @notice Deploys a new batch of vaults
     */
    function performUpkeep(bytes calldata) external {
        //@audit-ok should be: ...  > vaultDeploymentThreshold according to docs
        //10-7 = 3 (4 non-full) >= 3
        if ((vaults.length - globalVaultState.depositIndex) >= vaultDeploymentThreshold)
            revert VaultsAboveThreshold();
        _deployVaults(vaultDeploymentAmount);
    }

    /**
     * @notice Deploys a new batch of vaults
     * @param _numVaults number of vaults to deploy
     */
    function addVaults(uint256 _numVaults) external onlyOwner {
        _deployVaults(_numVaults);
    }

    /**
     * @notice Sets the vault deployment parameters
     * @param _vaultDeploymentThreshold the min number of non-full vaults before a new batch is deployed
     * @param _vaultDeploymentAmount amount of vaults to deploy when threshold is met
     */
    function setVaultDeploymentParams(
        uint128 _vaultDeploymentThreshold,
        uint128 _vaultDeploymentAmount
    ) external onlyOwner {
        vaultDeploymentThreshold = _vaultDeploymentThreshold;
        vaultDeploymentAmount = _vaultDeploymentAmount;
        emit SetVaultDeploymentParams(_vaultDeploymentThreshold, _vaultDeploymentAmount);
    }

    /**
     * @notice Deploys new vaults
     * @param _numVaults number of vaults to deploy
     */
    function _deployVaults(uint256 _numVaults) internal {
        //sig of CommunityVault
        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            address(this),
            address(stakeController),
            stakeController.getRewardVault()
        );

        for (uint256 i = 0; i < _numVaults; i++) {
            _deployVault(data);
        }
    }
}
