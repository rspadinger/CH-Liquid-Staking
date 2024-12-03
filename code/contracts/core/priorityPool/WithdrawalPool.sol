// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.15;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IStakingPool.sol";
import "../interfaces/IPriorityPool.sol";

import "hardhat/console.sol";

/**
 * @title Withdrawal Pool
 * @notice Allows users to queue LST withdrawals if there is insufficient liquidity to satisfy the withdrawal amount.
 * @dev LST withdrawals will be added to a FIFO queue and will be fulfuilled as funds become available.
 */
contract WithdrawalPool is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // a withdrawal request made by an account
    struct Withdrawal {
        // number of LST shares remaining (may be withdrawable or not)
        uint128 sharesRemaining;
        // number of tokens that can be withdrawn
        uint128 partiallyWithdrawableAmount;
    }

    // a withdrawal batch created when some withdrawals were finalized
    struct WithdrawalBatch {
        // index of last withdrawal that was finalized in this batch
        uint128 indexOfLastWithdrawal;
        // the exchange rate of LSTs per underlying shares at the time of this batch
        uint128 stakePerShares;
    }

    // address of staking token
    IERC20Upgradeable public token;
    // address of liquid staking token
    IERC20Upgradeable public lst;
    // address of priority pool
    IPriorityPool public priorityPool;

    // list of withdrawal requests in order of creation
    Withdrawal[] internal queuedWithdrawals;
    // stores a list of withdrawal requests for each account
    mapping(address => uint256[]) internal queuedWithdrawalsByAccount;
    // mapping of withdrawal request index to the request owner
    mapping(uint256 => address) internal withdrawalOwners;

    // total number of LST shares queued for withdrawal
    uint256 internal totalQueuedShareWithdrawals;
    // index of the withdrawal that's at the front of the queue
    uint256 public indexOfNextWithdrawal;

    // list of withdrawal batches in order of creation
    WithdrawalBatch[] internal withdrawalBatches;
    // all batches before this index have had all withdrawal requests fully withdrawn
    uint128 public withdrawalBatchIdCutoff;
    // all withdrawal requests before this index have been fully withdrawn
    uint128 public withdrawalIdCutoff;

    // min amount of LSTs that can be queued for withdrawal
    uint256 public minWithdrawalAmount;

    // min amount of time between execution of withdrawals
    uint64 public minTimeBetweenWithdrawals;
    // time of last execution of withdrawals
    uint64 public timeOfLastWithdrawal;

    event QueueWithdrawal(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event WithdrawalsFinalized(uint256 amount);
    event SetMinWithdrawalAmount(uint256 minWithdrawalAmount);
    event SetMinTimeBetweenWithdrawals(uint64 minTimeBetweenWithdrawals);

    error SenderNotAuthorized();
    error InvalidWithdrawalId();
    error AmountTooSmall();
    error NoUpkeepNeeded();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes contract
     * @param _token address of asset token
     * @param _lst address of liquid staking token
     * @param _priorityPool address of priority pool
     * @param _minWithdrawalAmount minimum amount of LSTs that can be queued for withdrawal
     * @param _minTimeBetweenWithdrawals min amount of time between execution of withdrawals
     */
    function initialize(
        address _token,
        address _lst,
        address _priorityPool,
        uint256 _minWithdrawalAmount,
        uint64 _minTimeBetweenWithdrawals
    ) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init();

        token = IERC20Upgradeable(_token);
        lst = IERC20Upgradeable(_lst);
        lst.safeApprove(_priorityPool, type(uint256).max);
        priorityPool = IPriorityPool(_priorityPool);
        minWithdrawalAmount = _minWithdrawalAmount;
        withdrawalBatches.push(WithdrawalBatch(0, 0));
        queuedWithdrawals.push(Withdrawal(0, 0));
        minTimeBetweenWithdrawals = _minTimeBetweenWithdrawals;
        timeOfLastWithdrawal = uint64(block.timestamp);
    }

    /**
     * @notice Reverts if sender is not priority pool
     */
    modifier onlyPriorityPool() {
        if (msg.sender != address(priorityPool)) revert SenderNotAuthorized();
        _;
    }

    /**
     * @notice Returns the total amount of liquid staking tokens queued for withdrawal
     * @return total amount queued for withdrawal
     */
    function getTotalQueuedWithdrawals() external view returns (uint256) {
        return _getStakeByShares(totalQueuedShareWithdrawals);
    }

    /**
     * @notice Returns a list of withdrawals
     * @param _withdrawalIds list of withdrawal ids
     * @return list of withdrawals corresponding to withdrawal ids
     */
    function getWithdrawals(
        uint256[] calldata _withdrawalIds
    ) external view returns (Withdrawal[] memory) {
        Withdrawal[] memory withdrawals = new Withdrawal[](_withdrawalIds.length);

        for (uint256 i = 0; i < _withdrawalIds.length; ++i) {
            withdrawals[i] = queuedWithdrawals[_withdrawalIds[i]];
        }

        return withdrawals;
    }

    /**
     * @notice Returns batch ids for a list of withdrawals
     * @param _withdrawalIds list of withrawal ids
     * @return list of batch ids corresponding to withdrawal ids
     */
    function getBatchIds(uint256[] memory _withdrawalIds) public view returns (uint256[] memory) {
        uint256[] memory batchIds = new uint256[](_withdrawalIds.length);

        for (uint256 i = 0; i < _withdrawalIds.length; ++i) {
            uint256 batchId;
            uint256 withdrawalId = _withdrawalIds[i];

            for (uint256 j = withdrawalBatchIdCutoff; j < withdrawalBatches.length; ++j) {
                uint256 indexOfLastWithdrawal = withdrawalBatches[j].indexOfLastWithdrawal;

                if (withdrawalId <= indexOfLastWithdrawal) {
                    batchId = j;
                    break;
                }
            }

            batchIds[i] = batchId;
        }

        return batchIds;
    }

    /**
     * @notice Returns a list of withdrawal ids owned by an account
     * @param _account address of account
     * @return list of withdrawal ids
     */
    function getWithdrawalIdsByOwner(address _account) public view returns (uint256[] memory) {
        uint256[] memory activeWithdrawals = new uint256[](
            queuedWithdrawalsByAccount[_account].length
        );
        uint256 totalActiveWithdrawals;

        for (uint256 i = 0; i < activeWithdrawals.length; ++i) {
            uint256 withdrawalId = queuedWithdrawalsByAccount[_account][i];
            Withdrawal memory withdrawal = queuedWithdrawals[withdrawalId];

            if (withdrawal.sharesRemaining != 0 || withdrawal.partiallyWithdrawableAmount != 0) {
                activeWithdrawals[i] = withdrawalId;
                totalActiveWithdrawals++;
            }
        }

        uint256[] memory withdrawalIds = new uint256[](totalActiveWithdrawals);
        uint256 withdrawalIdsAdded;
        for (uint256 i = 0; i < activeWithdrawals.length; ++i) {
            if (activeWithdrawals[i] != 0) {
                withdrawalIds[withdrawalIdsAdded] = activeWithdrawals[i];
                withdrawalIdsAdded++;
            }
        }

        return withdrawalIds;
    }

    /**
     * @notice Returns a list of finalized and partially finalized withdrawal ids owned by an account
     * @dev these withdrawals have funds available for the owner to withdraw
     * @param _account address of account
     * @return list of withdrawal ids
     * @return total withdrawable across all account's withdrawals
     */
    function getFinalizedWithdrawalIdsByOwner(
        address _account
    ) external view returns (uint256[] memory, uint256) {
        uint256[] memory withdrawalIds = getWithdrawalIdsByOwner(_account); //1, 3
        //console.log(withdrawalIds[0], withdrawalIds[1]);

        //ids of batches where those wiithdrawalIds can be found
        //@note size of batchIds is the same as size of withdrawalIds => but, some elements may be 0 (no corresp batchId found)
        uint256[] memory batchIds = getBatchIds(withdrawalIds); // 1, 0
        console.log(batchIds[0], batchIds[1]);
        console.log(
            "WB length: ",
            withdrawalBatchIdCutoff,
            withdrawalBatches[0].indexOfLastWithdrawal,
            withdrawalBatches[1].indexOfLastWithdrawal
        );
        //console.log(withdrawalBatches[0].indexOfLastWithdrawal);

        uint256[] memory finalizedWithdrawals = new uint256[](withdrawalIds.length);
        uint256 totalFinalizedWithdrawals;
        uint256 totalWithdrawable;

        //all withdrawals of the acc must be in one of the batchIds => we iterate over all those batches
        //some corresp batchIds may be 0 => no batchId found
        for (uint256 i = 0; i < batchIds.length; ++i) {
            Withdrawal memory withdrawal = queuedWithdrawals[withdrawalIds[i]];

            if (batchIds[i] != 0 || withdrawal.partiallyWithdrawableAmount != 0) {
                finalizedWithdrawals[i] = withdrawalIds[i];
                totalFinalizedWithdrawals++;
                totalWithdrawable += withdrawal.partiallyWithdrawableAmount;

                if (batchIds[i] != 0) {
                    totalWithdrawable +=
                        (uint256(withdrawalBatches[batchIds[i]].stakePerShares) *
                            uint256(withdrawal.sharesRemaining)) /
                        1e18;
                }
            } else {
                //@audit-ok should we really quit the loop ? => find a config where batchIds[i] = 0 && withdrawal.partiallyWithdrawableAmount = 0
                //and where we have a following element in the queuedWithdrawals[withdrawalIds[i]] array, where withdrawal.partiallyWithdrawableAmount != 0
                //eg: withdrawal.sharesRemaining != 0 && withdrawal.partiallyWithdrawableAmount = 0
                console.log("BREAK");
                break;
            }
        }

        uint256[] memory retFinalizedWithdrawals = new uint256[](totalFinalizedWithdrawals);
        uint256 withdrawalsAdded;

        for (uint256 i = 0; i < totalFinalizedWithdrawals; ++i) {
            uint256 withdrawalId = finalizedWithdrawals[i];

            if (withdrawalId != 0) {
                retFinalizedWithdrawals[withdrawalsAdded] = withdrawalId;
                withdrawalsAdded++;
            }
        }

        return (retFinalizedWithdrawals, totalWithdrawable);
    }

    /**
     * @notice Executes a group of fully and/or partially finalized withdrawals owned by the sender
     * @param _withdrawalIds list of withdrawal ids to execute
     * @param _batchIds list of batch ids corresponding to withdrawal ids
     */
    //transfer LINK to msg.sender
    function withdraw(uint256[] calldata _withdrawalIds, uint256[] calldata _batchIds) external {
        address owner = msg.sender;
        uint256 amountToWithdraw;

        for (uint256 i = 0; i < _withdrawalIds.length; ++i) {
            uint256 withdrawalId = _withdrawalIds[i];
            Withdrawal memory withdrawal = queuedWithdrawals[_withdrawalIds[i]];

            uint256 batchId = _batchIds[i];
            WithdrawalBatch memory batch = withdrawalBatches[batchId];

            if (withdrawalOwners[withdrawalId] != owner) revert SenderNotAuthorized();

            //@audit-ok why batchId - 1 => our withdrawalId should not be <=  previous batch last withdrawal
            if (
                batchId != 0 && withdrawalId <= withdrawalBatches[batchId - 1].indexOfLastWithdrawal
            ) revert InvalidWithdrawalId();

            //withdrawalId > batch.indexOfLastWithdrawal => hasn't been withdrawn yet => no shares available
            if (
                batchId != 0 &&
                withdrawalId > batch.indexOfLastWithdrawal &&
                withdrawal.partiallyWithdrawableAmount == 0
            ) revert InvalidWithdrawalId();

            //@audit-ok check => seems like, indexOfLastWithdrawal is not updated
            //console.log("withdraw func: ", withdrawalId, batch.indexOfLastWithdrawal);
            if (withdrawalId <= batch.indexOfLastWithdrawal) {
                //already withdrawn => shares available
                amountToWithdraw +=
                    withdrawal.partiallyWithdrawableAmount +
                    (uint256(batch.stakePerShares) * uint256(withdrawal.sharesRemaining)) /
                    1e18;

                //@audit-ok check if we need to reset other vars: queuedWithdrawalsByAccount...
                //set in: queueWithdrawal --- used in: getWithdrawalIdsByOwner
                delete queuedWithdrawals[withdrawalId]; //here, we delete both values of the struct
                delete withdrawalOwners[withdrawalId];

                //comments below are not relevant: this feature is implemented in: getWithdrawalIdsByOwner() => no need to delete queuedWithdrawalsByAccount
                //TEST: call withdraw => check: getWithdrawalIdsByOwner(owner)
                //delete withdrawalId from queuedWithdrawalsByAccount[owner] => queuedWithdrawalsByAccount[_account].push(withdrawalId);
                // uint256[] queuedOwnerWithdrawals = queuedWithdrawalsByAccount[owner]
                // for (uint256 j = 0; j < queuedOwnerWithdrawals.length; ++i) {
                //     if (queuedOwnerWithdrawals[j] == withdrawalId) {
                //         queuedOwnerWithdrawals[j] = queuedOwnerWithdrawals[queuedOwnerWithdrawals.length - 1];
                //         queuedOwnerWithdrawals.pop();
                //         break;
                //     }
                // }
            } else {
                amountToWithdraw += withdrawal.partiallyWithdrawableAmount;
                queuedWithdrawals[withdrawalId].partiallyWithdrawableAmount = 0; //here, we only delete one value of the struct
            }
        }

        token.safeTransfer(owner, amountToWithdraw);
        emit Withdraw(owner, amountToWithdraw);
    }

    /**
     * @notice Queues a withdrawal of liquid staking tokens for an account
     * @param _account address of account
     * @param _amount amount of LST
     */
    //provide LST & get corresp amount of LINK
    function queueWithdrawal(address _account, uint256 _amount) external onlyPriorityPool {
        if (_amount < minWithdrawalAmount) revert AmountTooSmall();

        lst.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 sharesAmount = _getSharesByStake(_amount);
        //console.log("queueWithdrawal: ", sharesAmount, _amount);
        queuedWithdrawals.push(Withdrawal(uint128(sharesAmount), 0));
        totalQueuedShareWithdrawals += sharesAmount;

        uint256 withdrawalId = queuedWithdrawals.length - 1;
        queuedWithdrawalsByAccount[_account].push(withdrawalId);
        withdrawalOwners[withdrawalId] = _account;

        emit QueueWithdrawal(_account, _amount);
    }

    /**
     * @notice Deposits asset tokens in exchange for liquid staking tokens, finalizing withdrawals
     * starting from the front of the queue
     * @param _amount amount of tokens to deposit
     */
    //PP sends LINK => WP sends LST back to PP
    function deposit(uint256 _amount) external onlyPriorityPool {
        token.safeTransferFrom(msg.sender, address(this), _amount);
        lst.safeTransfer(msg.sender, _amount);
        _finalizeWithdrawals(_amount);
    }

    /**
     * @notice Returns whether withdrawals should be executed based on available withdrawal space
     * @return true if withdrawal should be executed, false otherwise
     */
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        if (
            _getStakeByShares(totalQueuedShareWithdrawals) != 0 &&
            priorityPool.canWithdraw(address(this), 0) != 0 &&
            block.timestamp > timeOfLastWithdrawal + minTimeBetweenWithdrawals
        ) {
            return (true, "");
        }
        return (false, "");
    }

    /**
     * @notice Executes withdrawals if there is sufficient available withdrawal space
     * @param _performData encoded list of withdrawal data passed to staking pool strategies
     */
    //withdraw LST
    function performUpkeep(bytes calldata _performData) external {
        uint256 canWithdraw = priorityPool.canWithdraw(address(this), 0);
        uint256 totalQueued = _getStakeByShares(totalQueuedShareWithdrawals);

        if (
            totalQueued == 0 ||
            canWithdraw == 0 ||
            block.timestamp <= timeOfLastWithdrawal + minTimeBetweenWithdrawals
        ) revert NoUpkeepNeeded();

        timeOfLastWithdrawal = uint64(block.timestamp);

        uint256 toWithdraw = totalQueued > canWithdraw ? canWithdraw : totalQueued;
        bytes[] memory data = abi.decode(_performData, (bytes[]));

        priorityPool.executeQueuedWithdrawals(toWithdraw, data); //send LINK to WithdrawalPool & withdraws LST from WP to PP

        _finalizeWithdrawals(toWithdraw);
    }

    /**
     * @notice Updates the withdrawalBatchIdCutoff
     * @dev this value is used to more efficiently return data in getBatchIds by skipping old withdrawal batches
     */
    function updateWithdrawalBatchIdCutoff() external {
        uint256 numWithdrawals = queuedWithdrawals.length; //10
        uint256 newWithdrawalIdCutoff = withdrawalIdCutoff; //3

        // find the first withdrawal that has funds remaining
        for (uint256 i = newWithdrawalIdCutoff; i < numWithdrawals; ++i) {
            //iterate 3 => 9
            newWithdrawalIdCutoff = i;

            Withdrawal memory withdrawal = queuedWithdrawals[i];
            if (withdrawal.sharesRemaining != 0 || withdrawal.partiallyWithdrawableAmount != 0) {
                break;
            }
        }

        uint256 numBatches = withdrawalBatches.length; //10
        uint256 newWithdrawalBatchIdCutoff = withdrawalBatchIdCutoff; //3

        // find the last batch where all withdrawals have no funds remaining
        for (uint256 i = newWithdrawalBatchIdCutoff; i < numBatches; ++i) {
            // correct
            newWithdrawalBatchIdCutoff = i; //first: 3 => second: 4

            if (withdrawalBatches[i].indexOfLastWithdrawal >= newWithdrawalIdCutoff) {
                break;
            }
        }

        withdrawalIdCutoff = uint128(newWithdrawalIdCutoff);
        withdrawalBatchIdCutoff = uint128(newWithdrawalBatchIdCutoff);
    }

    /**
     * @notice Sets the minimum amount of liquid staking tokens that can be queued for withdrawal
     * @param _minWithdrawalAmount minimum token amount
     */
    function setMinWithdrawalAmount(uint256 _minWithdrawalAmount) external onlyOwner {
        minWithdrawalAmount = _minWithdrawalAmount;
        emit SetMinWithdrawalAmount(_minWithdrawalAmount);
    }

    /**
     * @notice Sets the minimum amount of of time between calls to performUpkeep to finalize withdrawals
     * @param _minTimeBetweenWithdrawals minimum time
     */
    function setMinTimeBetweenWithdrawals(uint64 _minTimeBetweenWithdrawals) external onlyOwner {
        minTimeBetweenWithdrawals = _minTimeBetweenWithdrawals;
        emit SetMinTimeBetweenWithdrawals(_minTimeBetweenWithdrawals);
    }

    /**
     * @notice Finalizes withdrawal accounting after withdrawals have been executed
     * @param _amount amount to finalize
     */
    //called after deposit => acc provides LINK & withdraws LST => add to internal accounting
    //also executed after upkeep => withdraw LST
    function _finalizeWithdrawals(uint256 _amount) internal {
        //the WP just received some LINK (amount) => queued LST withdrawals can be serviced up to that amount
        uint256 sharesToWithdraw = _getSharesByStake(_amount);
        uint256 numWithdrawals = queuedWithdrawals.length;

        //we deduct, because we deposit LINK
        totalQueuedShareWithdrawals -= sharesToWithdraw;

        //indexOfNextWithdrawal needs to be incr each time a withdrawal is serviced
        for (uint256 i = indexOfNextWithdrawal; i < numWithdrawals; ++i) {
            uint256 sharesRemaining = queuedWithdrawals[i].sharesRemaining;

            //queued withdrawal amount can be fully serviced & there is some leftover for other withdrawals
            if (sharesRemaining < sharesToWithdraw) {
                // fully finalize withdrawal
                sharesToWithdraw -= sharesRemaining;

                //### we need to incr indexOfNextWithdrawal
                continue;
            }

            //queued withdrawal amount cannot be fully serviced => update Withdrawal
            //remember, when we queue a withdrawal: queuedWithdrawals.push(Withdrawal(uint128(sharesAmount), 0));
            if (sharesRemaining > sharesToWithdraw) {
                // partially finalize withdrawal => update W: LST shares remaining & withdrawable shares
                //console.log("Update Withdrawal: ", uint128(sharesRemaining - sharesToWithdraw));
                queuedWithdrawals[i] = Withdrawal(
                    uint128(sharesRemaining - sharesToWithdraw),
                    uint128(
                        queuedWithdrawals[i].partiallyWithdrawableAmount +
                            _getStakeByShares(sharesToWithdraw)
                    )
                );

                //we are finished & indexOfNextWithdrawal stays the same
                indexOfNextWithdrawal = i;
                //console.log("P1");
                withdrawalBatches.push(
                    WithdrawalBatch(uint128(i - 1), uint128(_getStakeByShares(1 ether)))
                );
                //queued withdrawal amount can be fully & exactly serviced
            } else {
                // fully finalize withdrawal :: sharesRemaining = sharesToWithdraw
                //we are finished & indexOfNextWithdrawal needs to be incr
                indexOfNextWithdrawal = i + 1;
                //create new WBatch with current id & current exchange rate (# LST for 10**18 shares)
                //console.log("P2");
                withdrawalBatches.push(
                    WithdrawalBatch(uint128(i), uint128(_getStakeByShares(1 ether)))
                );
            }

            sharesToWithdraw = 0;
            break;
        }

        // entire amount must be accounted for
        assert(sharesToWithdraw == 0);

        emit WithdrawalsFinalized(_amount);
    }

    /**
     * @notice Returns the amount of LST that corresponds to an amount of shares
     * @param _sharesAmount amount of shares
     * @return amount of stake
     */
    function _getStakeByShares(uint256 _sharesAmount) internal view virtual returns (uint256) {
        return IStakingPool(address(lst)).getStakeByShares(_sharesAmount);
    }

    /**
     * @notice Returns the amount of shares that corresponds to an amount of LST
     * @param _amount amount of stake
     * @return amount of shares
     */
    function _getSharesByStake(uint256 _amount) internal view virtual returns (uint256) {
        return IStakingPool(address(lst)).getSharesByStake(_amount);
    }

    /**
     * @dev Checks authorization for contract upgrades
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
