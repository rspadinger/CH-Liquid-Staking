import { assert, expect } from 'chai'
import {
  toEther,
  deploy,
  fromEther,
  deployUpgradeable,
  getAccounts,
  setupToken,
} from '../../utils/helpers'
import {
  ERC677,
  PriorityPool,
  StakingPool,
  StrategyMock,
  WithdrawalPool,
} from '../../../typechain-types'
import { ethers } from 'hardhat'
import { loadFixture, time } from '@nomicfoundation/hardhat-network-helpers'

describe('WithdrawalPool', () => {
  async function deployFixture() {
    const { accounts, signers } = await getAccounts()

    const token = (await deploy('contracts/core/tokens/base/ERC677.sol:ERC677', [
      'Chainlink',
      'LINK',
      1000000000,
    ])) as ERC677
    await setupToken(token, accounts, true)

    const stakingPool = (await deployUpgradeable('StakingPool', [
      token.target,
      'Staked LINK',
      'stLINK',
      [],
      toEther(10000),
    ])) as StakingPool

    const strategy = (await deployUpgradeable('StrategyMock', [
      token.target,
      stakingPool.target,
      toEther(1000000000),
      toEther(5000),
    ])) as StrategyMock

    const withdrawalPool = (await deployUpgradeable('WithdrawalPool', [
      token.target,
      stakingPool.target,
      accounts[0],
      toEther(10),
      86400,
    ])) as WithdrawalPool

    await stakingPool.addStrategy(strategy.target)
    await stakingPool.setPriorityPool(accounts[0])
    await stakingPool.setRebaseController(accounts[0])
    await token.approve(stakingPool.target, ethers.MaxUint256)
    await token.approve(withdrawalPool.target, ethers.MaxUint256)
    await stakingPool.approve(withdrawalPool.target, ethers.MaxUint256)

    await stakingPool.deposit(accounts[0], toEther(100000), ['0x'])
    await token.transfer(strategy.target, toEther(100000))
    await stakingPool.updateStrategyRewards([0], '0x')

    return { signers, accounts, token, stakingPool, strategy, withdrawalPool }
  }

  it('queueWithdrawal should work correctly', async () => {
    const { accounts, withdrawalPool, stakingPool } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(1000))
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(250))
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(500))

    assert.equal(fromEther(await stakingPool.balanceOf(withdrawalPool.target)), 1750)
    assert.equal(fromEther(await withdrawalPool.getTotalQueuedWithdrawals()), 1750)
    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])).map((id) => Number(id)),
      [1, 3]
    )
    assert.deepEqual(
      (await withdrawalPool.getWithdrawals([1, 2, 3])).map((d: any) => [
        fromEther(d[0]),
        fromEther(d[1]),
      ]),
      [
        [500, 0],
        [125, 0],
        [250, 0],
      ]
    )
  })

  it('deposit should work correctly', async () => {
    const { accounts, withdrawalPool, stakingPool, token } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(1000))
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(250))
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(500))
    await withdrawalPool.deposit(toEther(400))

    await expect(withdrawalPool.deposit(toEther(1751))).to.be.reverted

    assert.equal(fromEther(await token.balanceOf(withdrawalPool.target)), 400)
    assert.equal(fromEther(await stakingPool.balanceOf(withdrawalPool.target)), 1350)
    assert.equal(fromEther(await withdrawalPool.getTotalQueuedWithdrawals()), 1350)
    assert.equal(Number(await withdrawalPool.indexOfNextWithdrawal()), 1)
    assert.deepEqual(
      (await withdrawalPool.getWithdrawals([1, 2, 3])).map((d: any) => [
        fromEther(d[0]),
        fromEther(d[1]),
      ]),
      [
        [300, 400],
        [125, 0],
        [250, 0],
      ]
    )
    assert.deepEqual(
      (await withdrawalPool.getBatchIds([1, 2, 3])).map((d: any) => Number(d)),
      [0, 0, 0]
    )

    await withdrawalPool.deposit(toEther(700))

    assert.equal(fromEther(await token.balanceOf(withdrawalPool.target)), 1100)
    assert.equal(fromEther(await stakingPool.balanceOf(withdrawalPool.target)), 650)
    assert.equal(fromEther(await withdrawalPool.getTotalQueuedWithdrawals()), 650)
    assert.equal(Number(await withdrawalPool.indexOfNextWithdrawal()), 2)
    assert.deepEqual(
      (await withdrawalPool.getWithdrawals([1, 2, 3])).map((d: any) => [
        fromEther(d[0]),
        fromEther(d[1]),
      ]),
      [
        [300, 400],
        [75, 100],
        [250, 0],
      ]
    )
    assert.deepEqual(
      (await withdrawalPool.getBatchIds([1, 2, 3])).map((d: any) => Number(d)),
      [2, 0, 0]
    )

    await withdrawalPool.deposit(toEther(650))

    assert.equal(fromEther(await token.balanceOf(withdrawalPool.target)), 1750)
    assert.equal(fromEther(await stakingPool.balanceOf(withdrawalPool.target)), 0)
    assert.equal(fromEther(await withdrawalPool.getTotalQueuedWithdrawals()), 0)
    assert.equal(Number(await withdrawalPool.indexOfNextWithdrawal()), 4)
    assert.deepEqual(
      (await withdrawalPool.getWithdrawals([1, 2, 3])).map((d: any) => [
        fromEther(d[0]),
        fromEther(d[1]),
      ]),
      [
        [300, 400],
        [75, 100],
        [250, 0],
      ]
    )
    assert.deepEqual(
      (await withdrawalPool.getBatchIds([1, 2, 3])).map((d: any) => Number(d)),
      [2, 3, 3]
    )
  })

  it('withdraw should work correctly', async () => {
    const { signers, accounts, withdrawalPool, token } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(1000))
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(250))
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(500))
    await withdrawalPool.deposit(toEther(1200))

    await expect(withdrawalPool.withdraw([1, 2, 3], [1, 1, 0])).to.be.revertedWithCustomError(
      withdrawalPool,
      'SenderNotAuthorized()'
    )
    await expect(withdrawalPool.withdraw([1, 3], [1, 1])).to.be.revertedWithCustomError(
      withdrawalPool,
      'InvalidWithdrawalId()'
    )

    await withdrawalPool.deposit(toEther(550))

    await expect(withdrawalPool.withdraw([1], [2])).to.be.revertedWithCustomError(
      withdrawalPool,
      'InvalidWithdrawalId()'
    )

    let startingBalance = await token.balanceOf(accounts[1])
    await withdrawalPool.connect(signers[1]).withdraw([2], [2])
    assert.equal(fromEther((await token.balanceOf(accounts[1])) - startingBalance), 250)
    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[1])).map((id) => Number(id)),
      []
    )
    assert.deepEqual(
      (await withdrawalPool.getWithdrawals([2])).map((d: any) => [
        fromEther(d[0]),
        fromEther(d[1]),
      ]),
      [[0, 0]]
    )

    startingBalance = await token.balanceOf(accounts[0])
    await withdrawalPool.withdraw([1, 3], [1, 2])
    assert.equal(fromEther((await token.balanceOf(accounts[0])) - startingBalance), 1500)
    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[1])).map((id) => Number(id)),
      []
    )
    assert.deepEqual(
      (await withdrawalPool.getWithdrawals([1, 2, 3])).map((d: any) => [
        fromEther(d[0]),
        fromEther(d[1]),
      ]),
      [
        [0, 0],
        [0, 0],
        [0, 0],
      ]
    )
  })

  it('getWithdrawalIdsByOwner should work correctly', async () => {
    const { signers, accounts, withdrawalPool } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(1000))
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(250))
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(500))
    await withdrawalPool.deposit(toEther(600))

    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])).map((id) => Number(id)),
      [1, 3]
    )
    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[1])).map((id) => Number(id)),
      [2]
    )

    await withdrawalPool.withdraw([1], [0])

    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])).map((id) => Number(id)),
      [1, 3]
    )
    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[1])).map((id) => Number(id)),
      [2]
    )

    await withdrawalPool.deposit(toEther(1150))
    await withdrawalPool.withdraw([3], [2])

    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])).map((id) => Number(id)),
      [1]
    )
    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[1])).map((id) => Number(id)),
      [2]
    )

    await withdrawalPool.connect(signers[1]).withdraw([2], [2])

    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])).map((id) => Number(id)),
      [1]
    )
    assert.deepEqual(
      (await withdrawalPool.getWithdrawalIdsByOwner(accounts[1])).map((id) => Number(id)),
      []
    )
  })

  it('getBatchIdsByOwner should work correctly', async () => {
    const { accounts, withdrawalPool } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(1000))
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(250))
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(500))
    await withdrawalPool.deposit(toEther(600))

    assert.deepEqual(
      (await withdrawalPool.getBatchIds([1, 2, 3])).map((d: any) => Number(d)),
      [0, 0, 0]
    )

    await withdrawalPool.deposit(toEther(500))

    assert.deepEqual(
      (await withdrawalPool.getBatchIds([1, 2, 3])).map((d: any) => Number(d)),
      [2, 0, 0]
    )

    await withdrawalPool.deposit(toEther(50))
    await withdrawalPool.deposit(toEther(50))

    assert.deepEqual(
      (await withdrawalPool.getBatchIds([1, 2, 3])).map((d: any) => Number(d)),
      [2, 0, 0]
    )

    await withdrawalPool.deposit(toEther(550))

    assert.deepEqual(
      (await withdrawalPool.getBatchIds([1, 2, 3])).map((d: any) => Number(d)),
      [2, 5, 5]
    )
  })

  it.only('TEST - withdrawalBatchIdCutoff is not correctly set in updateWithdrawalBatchIdCutoff', async () => {
    const { signers, accounts, withdrawalPool } = await loadFixture(deployFixture)

    //we queue 3 withdrawals for accounts[0] => this will add 3 new Withdrawals (withdrawalId 1 to 3) to the queuedWithdrawals array
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) 
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) 
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) 
    
    //we make a first deposit of 200 => this will add a new WithdrawalBatch (withdrawalBatch 1) to the withdrawalBatches array 
    //and this will service withdrawalId 1 & 2 => indexOfNextWithdrawal = 3
    await withdrawalPool.deposit(toEther(200)) 

    //we make a second deposit of 100 => this will add a new WithdrawalBatch (withdrawalBatch 2) to the withdrawalBatches array 
    //and this will service withdrawalId 3 => indexOfNextWithdrawal = 4
    await withdrawalPool.deposit(toEther(100)) 
    
    //perform a withdraw for accounts[0] => but, only for withdrawalId 1 & 2 => both are in withdrawalBatch 1
    await withdrawalPool.connect(signers[0]).withdraw([ 1,2 ], [1,1])  

    //before calling updateWithdrawalBatchIdCutoff, the withdrawalBatchIdCutoff will be 0
    console.log("withdrawalBatchIdCutoff 1: ", await withdrawalPool.withdrawalBatchIdCutoff()) //0
    assert.equal(await withdrawalPool.withdrawalBatchIdCutoff(), 0)

    await withdrawalPool.updateWithdrawalBatchIdCutoff()

    //after calling updateWithdrawalBatchIdCutoff, the withdrawalBatchIdCutoff should be 2, but it is actually 1
    //all batches before withdrawalBatch 2 have had all withdrawal requests fully withdrawn => so, the correct value is 2 !
    console.log("withdrawalBatchIdCutoff 2: ", await withdrawalPool.withdrawalBatchIdCutoff()) //1 => should be 2 !!!
    
    //the following test fails until necessary corrections are made in updateWithdrawalBatchIdCutoff
    assert.equal(await withdrawalPool.withdrawalBatchIdCutoff(), 2)
  })

  it('TEST -  test withdrawal', async () => {
    const { signers, accounts, withdrawalPool } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) //Wid 1
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) //Wid 2
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) //Wid 3    
    //console.log("Ind next W: ", await withdrawalPool.indexOfNextWithdrawal()) //0   
    await withdrawalPool.deposit(toEther(200)) //3  => this will service Wid 1 & 2 => next is 3 
    //console.log("Ind next W: ", await withdrawalPool.indexOfNextWithdrawal()) //3
    await withdrawalPool.deposit(toEther(100)) // => this will service Wid 3 => next is 4
    
    //console.log("Ind next W: ", await withdrawalPool.indexOfNextWithdrawal()) //4
    // console.log("withdrawalBatchIdCutoff: ", await withdrawalPool.withdrawalBatchIdCutoff()) //0
    // console.log("withdrawalIdCutoff: ", await withdrawalPool.withdrawalIdCutoff()) //0

    // let wids = await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])
    // console.log("WIDs: ", wids) //1,2,3
    // console.log("BIDs: ", await withdrawalPool.getBatchIds([ 1,2,3 ])) //1,1,2

    //console.log("Before: ", await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])) //123
    await withdrawalPool.connect(signers[0]).withdraw([ 1,2 ], [1,1])   
    //console.log("After: ", await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])) //3

    console.log("withdrawalBatchIdCutoff 1: ", await withdrawalPool.withdrawalBatchIdCutoff()) //0
    await withdrawalPool.updateWithdrawalBatchIdCutoff()
    console.log("withdrawalBatchIdCutoff 2: ", await withdrawalPool.withdrawalBatchIdCutoff()) //1 => should be 2 !!!

    // console.log("withdrawalBatchIdCutoff 1: ", await withdrawalPool.withdrawalBatchIdCutoff())
    // await withdrawalPool.updateWithdrawalBatchIdCutoff()
    // console.log("withdrawalBatchIdCutoff 2: ", await withdrawalPool.withdrawalBatchIdCutoff())



  })

  it('TEST -  updateWithdrawalBatchIdCutoff index error', async () => {
    const { signers, accounts, withdrawalPool } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) //B1
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(100)) //B2
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) //B2
    await withdrawalPool.deposit(toEther(100)) //600
    //console.log("Ind next W: ", await withdrawalPool.indexOfNextWithdrawal()) //2
    await withdrawalPool.deposit(toEther(200)) // Tot: 1600   
    //console.log("Ind next W: ", await withdrawalPool.indexOfNextWithdrawal()) //4
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100))

    await withdrawalPool.deposit(toEther(100))
    //console.log("Ind next W: ", await withdrawalPool.indexOfNextWithdrawal()) //5
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100))
    await withdrawalPool.deposit(toEther(10))
    console.log("Ind next W: ", await withdrawalPool.indexOfNextWithdrawal()) //5

    let wids = await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])
    console.log("WIDs: ", wids) //1,3,4,5
    console.log("BIDs: ", await withdrawalPool.getBatchIds([ 1n, 3n, 4n, 5n ])) //1,2,3,0

    console.log("Before: ", await withdrawalPool.getWithdrawalIdsByOwner(accounts[0]))
    await withdrawalPool.connect(signers[0]).withdraw([ 1n, 3n, 4n ], [1n, 2n, 3n])
    await withdrawalPool.connect(signers[0]).withdraw([ 1n, 3n, 4n ], [1n, 2n, 3n])
    console.log("After: ", await withdrawalPool.getWithdrawalIdsByOwner(accounts[0]))

    console.log("withdrawalBatchIdCutoff 1: ", await withdrawalPool.withdrawalBatchIdCutoff())
    await withdrawalPool.updateWithdrawalBatchIdCutoff()
    console.log("withdrawalBatchIdCutoff 2: ", await withdrawalPool.withdrawalBatchIdCutoff())



  })

  it('TEST - getFinalizedWithdrawalIdsByOwner should work correctly', async () => {
    const { accounts, withdrawalPool } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) //B1
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(100)) //B2
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) //B2
    await withdrawalPool.deposit(toEther(100)) //600
    await withdrawalPool.deposit(toEther(200)) // Tot: 1600
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(100)) //B3
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100)) // Tot: 2000 --- 1800 //B5 partial
    await withdrawalPool.deposit(toEther(100)) // Tot: 1900
    await withdrawalPool.deposit(toEther(10)) // Tot: 1900
    await withdrawalPool.deposit(toEther(10)) // Tot: 420

    //await withdrawalPool.queueWithdrawal(accounts[1], toEther(100))
    //await withdrawalPool.deposit(toEther(10)) 
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(100))

    let wids = await withdrawalPool.getWithdrawalIdsByOwner(accounts[0])
    console.log("WIDs: ", wids)
    console.log("BIDs: ", await withdrawalPool.getBatchIds([ 1n, 3n, 5n, 6n ]))
    //await withdrawalPool.getBatchIds([1, 2, 3])

    // console.log("withdrawalBatchIdCutoff 1: ", await withdrawalPool.withdrawalBatchIdCutoff())
    // await withdrawalPool.updateWithdrawalBatchIdCutoff()
    // console.log("withdrawalBatchIdCutoff 2: ", await withdrawalPool.withdrawalBatchIdCutoff())
    // console.log("BIDs: ", await withdrawalPool.getBatchIds([ 1n, 3n, 5n, 6n ]))


    let data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[0])
    console.log(data[0], fromEther(data[1]))

    console.log("Before: ", await withdrawalPool.getWithdrawalIdsByOwner(accounts[0]))
    //await withdrawalPool.connect().withdraw([ 1n, 3n, 4n ], [1n, 2n, 3n])
    console.log("After: ", await withdrawalPool.getWithdrawalIdsByOwner(accounts[0]))

    console.log("withdrawalBatchIdCutoff 1: ", await withdrawalPool.withdrawalBatchIdCutoff())
    await withdrawalPool.updateWithdrawalBatchIdCutoff()
    console.log("withdrawalBatchIdCutoff 2: ", await withdrawalPool.withdrawalBatchIdCutoff())

    // data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[0])
    // assert.deepEqual(
    //   data[0].map((id) => Number(id)),
    //   []
    // )
    // assert.equal(fromEther(data[1]), 0)

    // await withdrawalPool.deposit(toEther(600))

    // data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[0])
    // assert.deepEqual(
    //   data[0].map((id) => Number(id)),
    //   [1]
    // )
    // assert.equal(fromEther(data[1]), 400)

    // data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[1])
    // assert.deepEqual(
    //   data[0].map((id) => Number(id)),
    //   [2]
    // )
    // assert.equal(fromEther(data[1]), 200)

    // await withdrawalPool.deposit(toEther(550))

    // data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[0])
    // assert.deepEqual(
    //   data[0].map((id) => Number(id)),
    //   [1, 3]
    // )
    // assert.equal(fromEther(data[1]), 900)

    // data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[1])
    // assert.deepEqual(
    //   data[0].map((id) => Number(id)),
    //   [2]
    // )
    // assert.equal(fromEther(data[1]), 250)
  })

  it('getFinalizedWithdrawalIdsByOwner should work correctly', async () => {
    const { accounts, withdrawalPool } = await loadFixture(deployFixture)

    await withdrawalPool.queueWithdrawal(accounts[0], toEther(1000))
    await withdrawalPool.queueWithdrawal(accounts[1], toEther(250))
    await withdrawalPool.queueWithdrawal(accounts[0], toEther(500))
    await withdrawalPool.deposit(toEther(600))

    let data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[0])
    assert.deepEqual(
      data[0].map((id) => Number(id)),
      [1]
    )
    assert.equal(fromEther(data[1]), 600)

    await withdrawalPool.withdraw([1], [0])

    data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[0])
    assert.deepEqual(
      data[0].map((id) => Number(id)),
      []
    )
    assert.equal(fromEther(data[1]), 0)

    await withdrawalPool.deposit(toEther(600))

    data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[0])
    assert.deepEqual(
      data[0].map((id) => Number(id)),
      [1]
    )
    assert.equal(fromEther(data[1]), 400)

    data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[1])
    assert.deepEqual(
      data[0].map((id) => Number(id)),
      [2]
    )
    assert.equal(fromEther(data[1]), 200)

    await withdrawalPool.deposit(toEther(550))

    data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[0])
    assert.deepEqual(
      data[0].map((id) => Number(id)),
      [1, 3]
    )
    assert.equal(fromEther(data[1]), 900)

    data = await withdrawalPool.getFinalizedWithdrawalIdsByOwner(accounts[1])
    assert.deepEqual(
      data[0].map((id) => Number(id)),
      [2]
    )
    assert.equal(fromEther(data[1]), 250)
  })

  it('checkUpkeep and performUpkeep should work correctly', async () => {
    const { accounts, stakingPool, token, strategy } = await loadFixture(deployFixture)

    let priorityPool = (await deployUpgradeable('PriorityPool', [
      token.target,
      stakingPool.target,
      accounts[0],
      0,
      0,
    ])) as PriorityPool
    const withdrawalPool = (await deployUpgradeable('WithdrawalPool', [
      stakingPool.target,
      stakingPool.target,
      priorityPool.target,
      toEther(10),
      86400,
    ])) as WithdrawalPool
    await stakingPool.approve(priorityPool.target, ethers.MaxUint256)
    await stakingPool.setPriorityPool(priorityPool.target)
    await priorityPool.setWithdrawalPool(withdrawalPool.target)

    await priorityPool.withdraw(toEther(199000), 0, 0, [], false, true)
    assert.deepEqual(await withdrawalPool.checkUpkeep('0x'), [false, '0x'])
    await expect(withdrawalPool.performUpkeep('0x')).to.be.revertedWithCustomError(
      withdrawalPool,
      'NoUpkeepNeeded()'
    )

    await time.increase(86400)
    assert.deepEqual(await withdrawalPool.checkUpkeep('0x'), [true, '0x'])
    await withdrawalPool.performUpkeep(
      ethers.AbiCoder.defaultAbiCoder().encode(['bytes[]'], [['0x']])
    )
    assert.equal(fromEther(await token.balanceOf(withdrawalPool.target)), 195000)
    assert.equal(fromEther(await stakingPool.balanceOf(withdrawalPool.target)), 4000)
    assert.equal(fromEther(await withdrawalPool.getTotalQueuedWithdrawals()), 4000)

    await time.increase(86400)
    assert.deepEqual(await withdrawalPool.checkUpkeep('0x'), [false, '0x'])
    await expect(withdrawalPool.performUpkeep('0x')).to.be.revertedWithCustomError(
      withdrawalPool,
      'NoUpkeepNeeded()'
    )

    await strategy.setMinDeposits(toEther(0))
    assert.deepEqual(await withdrawalPool.checkUpkeep('0x'), [true, '0x'])
    await withdrawalPool.performUpkeep(
      ethers.AbiCoder.defaultAbiCoder().encode(['bytes[]'], [['0x']])
    )
    assert.equal(fromEther(await token.balanceOf(withdrawalPool.target)), 199000)
    assert.equal(fromEther(await stakingPool.balanceOf(withdrawalPool.target)), 0)
    assert.equal(fromEther(await withdrawalPool.getTotalQueuedWithdrawals()), 0)
  })
})
