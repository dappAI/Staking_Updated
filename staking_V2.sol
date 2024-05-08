

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;


import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/ReentrancyGuard.sol" ;


// Contract definition inheriting from Ownable and ReentrancyGuard
contract DAPPAIStaking is Ownable, ReentrancyGuard {
    // Struct to store information about each staking pool
    struct PoolInfo {
        uint256 lockupDuration; // Duration for which funds are locked up
        uint256 returnPer; // Return percentage for the pool APY
    }

    // Struct to store information about each staking order
    struct OrderInfo {
        address beneficiary; // Address of the staker
        uint256 amount; // Amount of tokens staked
        uint256 lockupDuration; // Duration for which the stake is locked up
        uint256 returnPer; // Return percentage for the stake
        uint256 starttime; // Start time of the stake
        uint256 endtime; // End time of the stake
        uint256 claimedReward; // Amount of claimed rewards
        bool claimed; // Flag indicating whether rewards are claimed
    }

    // Constants defining various durations in seconds
    uint256 private constant _days0 = 1 minutes;
    uint256 private constant _days7 = 7 days;
    uint256 private constant _days14 = 14 days;
    uint256 private constant _days30 = 30 days;
    uint256 private constant _days365 = 365 days;

    // Public variables
    IERC20 public token; // Token being staked
    bool public started = true; // Flag indicating whether staking has started
    uint256 public emergencyWithdrawFeesPercentage = 2; // Fees percentage for emergency withdrawals

    // Percentage returns for different lockup durations
    uint256 private _0daysPercentage = 20;
    uint256 private _7daysPercentage = 30;
    uint256 private _14daysPercentage = 45;
    uint256 private _30daysPercentage = 60;

    // Tracking variables
    uint256 private latestOrderId = 0; // Latest staking order ID
    uint public totalStakers; // Total number of unique stakers
    uint public totalStaked; // Total amount of tokens staked
    uint256 public totalStake = 0; // Total amount of tokens currently staked
    uint256 public totalWithdrawal = 0; // Total amount withdrawn by users
    uint256 public totalRewardPending = 0; // Total pending rewards
    uint256 public totalRewardsDistribution = 0; // Total rewards distributed

     // Modifier to allow only EOA callers
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "DAPPAIStaking: Caller must be an EOA");
        _;
    }

    // Mappings to store data
    mapping(uint256 => PoolInfo) public pooldata; // Mapping of lockup duration to pool info
    mapping(address => uint256) public balanceOf; // Balance of tokens for each address
    mapping(address => uint256) public totalRewardEarn; // Total rewards earned by each address
    mapping(uint256 => OrderInfo) public orders; // Mapping of order ID to order info
    mapping(address => uint256[]) private orderIds; // Mapping of address to array of order IDs

    // Additional mappings for tracking staking status
    mapping(address => mapping(uint => bool)) public hasStaked; // Mapping of address and lockup duration to staking status
    mapping(uint => uint) public stakeOnPool; // Total staked amount on each pool
    mapping(uint => uint) public rewardOnPool; // Total rewards on each pool
    mapping(uint => uint) public stakersPlan; // Total number of stakers on each lockup duration

    // Events
    event Deposit(
        address indexed user,
        uint256 indexed lockupDuration,
        uint256 amount,
        uint256 returnPer
    );
    event Withdraw(
        address indexed user,
        uint256 amount,
        uint256 reward,
        uint256 total
    );
    event WithdrawAll(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);
    event RefRewardClaimed(address indexed user, uint256 reward);

    // Constructor function
    constructor(address _token, bool _started) Ownable(msg.sender){
        token = IERC20(_token);
        started = _started;

        // Initialize pooldata with lockup durations and return percentages APY 
        pooldata[1].lockupDuration = _days0; // 0 days
        pooldata[1].returnPer = _0daysPercentage;

        pooldata[2].lockupDuration = _days7; // 7 days
        pooldata[2].returnPer = _7daysPercentage;

        pooldata[3].lockupDuration = _days14; // 14 days
        pooldata[3].returnPer = _14daysPercentage;

        pooldata[4].lockupDuration = _days30; // 30 days
        pooldata[4].returnPer = _30daysPercentage;
    }

    // Function to deposit tokens into the staking contract
    function deposit(uint256 _amount, uint256 _lockupDuration) external onlyEOA {
        // Retrieve pool info based on lockup duration
        PoolInfo storage pool = pooldata[_lockupDuration];
        
        // Check validity of staking parameters
        require(pool.lockupDuration > 0, "TokenStakingDAPPAI: asked pool does not exist");
        require(started, "TokenStakingDAPPAI: staking not yet started");
        require(_amount > 0, "TokenStakingDAPPAI: stake amount must be non-zero");

        // Calculate APY (Annual Percentage Yield) and user reward
        uint256 APY = (_amount * pool.returnPer) / 100;
        uint256 userReward = (APY * pool.lockupDuration) / _days365;

        // Transfer tokens from user to staking contract
        require(token.transferFrom(_msgSender(), address(this), _amount), "TokenStakingDAPPAI: token transferFrom via deposit not succeeded");

        // Update staking information
        orders[++latestOrderId] = OrderInfo(
            _msgSender(),
            _amount,
            pool.lockupDuration,
            pool.returnPer,
            block.timestamp,
            block.timestamp + pool.lockupDuration,
            0,
            false
        );

        // Update staking status
        if (!hasStaked[msg.sender][_lockupDuration]) {
            stakersPlan[_lockupDuration] = stakersPlan[_lockupDuration] + 1;
            totalStakers = totalStakers + 1;
        }
        hasStaked[msg.sender][_lockupDuration] = true;
        stakeOnPool[_lockupDuration] = stakeOnPool[_lockupDuration] + _amount;
        totalStaked = totalStaked + _amount;
        totalStake += _amount;
        totalRewardPending += userReward;
        balanceOf[_msgSender()] += _amount;
        orderIds[_msgSender()].push(latestOrderId);

        // Emit deposit event
        emit Deposit(_msgSender(), pool.lockupDuration, _amount, pool.returnPer);
    }

    // Function to withdraw tokens and rewards
    function withdraw(uint256 orderId) external nonReentrant {
        // Retrieve order info based on order ID
        OrderInfo storage orderInfo = orders[orderId];

        // Check validity of order and caller
        require(orderId <= latestOrderId, "TokenStakingDAPPAI: INVALID orderId, orderId greater than latestOrderId");
        require(_msgSender() == orderInfo.beneficiary, "TokenStakingDAPPAI: caller is not the beneficiary");
        require(!orderInfo.claimed, "TokenStakingDAPPAI: order already unstaked");
        require(block.timestamp >= orderInfo.endtime, "TokenStakingDAPPAI: stake locked until lock duration completion");

        // Calculate available rewards for claiming
        uint256 claimAvailable = pendingRewards(orderId);
        uint256 total = orderInfo.amount + claimAvailable;

        // Update reward and withdrawal information
        totalRewardEarn[_msgSender()] += claimAvailable;
        totalRewardsDistribution += claimAvailable;
        orderInfo.claimedReward += claimAvailable;
        totalRewardPending -= claimAvailable;

        // Update balance and staking information
        balanceOf[_msgSender()] -= orderInfo.amount;
        totalWithdrawal += orderInfo.amount;
        orderInfo.claimed = true;
        totalStake -= orderInfo.amount;

        // Transfer tokens to the beneficiary
        require(token.transfer(address(_msgSender()), total), "TokenStakingDAPPAI: token transfer via withdraw not succeeded");
        rewardOnPool[orderInfo.lockupDuration] = rewardOnPool[orderInfo.lockupDuration] + claimAvailable;

        // Emit withdrawal event
        emit Withdraw(_msgSender(), orderInfo.amount, claimAvailable, total);
    }

    // Function to claim rewards
    function claimRewards(uint256 orderId) external nonReentrant {
        // Retrieve order info based on order ID
        OrderInfo storage orderInfo = orders[orderId];

        // Check validity of order and caller
        require(orderId <= latestOrderId, "TokenStakingDAPPAI: INVALID orderId, orderId greater than latestOrderId");
        require(_msgSender() == orderInfo.beneficiary, "TokenStakingDAPPAI: caller is not the beneficiary");
        require(!orderInfo.claimed, "TokenStakingDAPPAI: order already unstaked");

        // Calculate available rewards for claiming
        uint256 claimAvailable = pendingRewards(orderId);

        // Update reward information
        totalRewardEarn[_msgSender()] += claimAvailable;
        totalRewardsDistribution += claimAvailable;
        totalRewardPending -= claimAvailable;
        orderInfo.claimedReward += claimAvailable;

        // Transfer tokens to the beneficiary
        require(token.transfer(address(_msgSender()), claimAvailable), "TokenStakingDAPPAI: token transfer via claim rewards not succeeded");
        rewardOnPool[orderInfo.lockupDuration] = rewardOnPool[orderInfo.lockupDuration] + claimAvailable;

        // Emit reward claimed event
        emit RewardClaimed(address(_msgSender()), claimAvailable);
    }

    // Function to calculate pending rewards for a given order
    function pendingRewards(uint256 orderId) public view returns (uint256) {
        // Retrieve order info based on order ID
        OrderInfo storage orderInfo = orders[orderId];

        // Check if rewards are claimed
        if (!orderInfo.claimed) {
            if (block.timestamp >= orderInfo.endtime) {
                // Calculate rewards if stake duration has ended
                uint256 APY = (orderInfo.amount * orderInfo.returnPer) / 100;
                uint256 reward = (APY * orderInfo.lockupDuration) / _days365;
                uint256 claimAvailable = reward - orderInfo.claimedReward;
                return claimAvailable;
            } else {
                // Calculate rewards based on current time if stake is still active
                uint256 stakeTime = block.timestamp - orderInfo.starttime;
                uint256 APY = (orderInfo.amount * orderInfo.returnPer) / 100;
                uint256 reward = (APY * stakeTime) / _days365;
                uint256 claimAvailableNow = reward - orderInfo.claimedReward;
                return claimAvailableNow;
            }
        } else {
            return 0;
        }
    }

    // Function for emergency withdrawal
    function emergencyWithdraw(uint256 orderId) external nonReentrant {
        // Retrieve order info based on order ID
        OrderInfo storage orderInfo = orders[orderId];

        // Check validity of order and caller
        require(orderId <= latestOrderId, "TokenStakingDAPPAI: INVALID orderId, orderId greater than latestOrderId");
        require(orderInfo.lockupDuration == _days0, "Please run Withdraw function for unstake");
        require(_msgSender() == orderInfo.beneficiary, "TokenStakingDAPPAI: caller is not the beneficiary");
        require(!orderInfo.claimed, "TokenStakingDAPPAI: order already unstaked");

        // Calculate available rewards for claiming
        uint256 claimAvailable = pendingRewards(orderId);
        uint256 fees = (orderInfo.amount * emergencyWithdrawFeesPercentage) / 1000;
        orderInfo.amount -= fees;
        uint256 total = orderInfo.amount + claimAvailable;

        // Update reward information
        totalRewardEarn[_msgSender()] += claimAvailable;
        totalRewardsDistribution += claimAvailable;
        totalRewardPending -= claimAvailable;
        orderInfo.claimedReward += claimAvailable;

        // Calculate total reward for the stake
        uint256 APY = ((orderInfo.amount + fees) * orderInfo.returnPer) / 100;
        uint256 totalReward = (APY * orderInfo.lockupDuration) / _days365;
        totalRewardPending -= (totalReward - orderInfo.claimedReward);

        // Update balance and withdrawal information
        balanceOf[_msgSender()] -= (orderInfo.amount + fees);
        totalWithdrawal += (orderInfo.amount + fees);
        orderInfo.claimed = true;

        // Transfer tokens to the beneficiary and fees to the owner
        require(token.transfer(address(_msgSender()), total), "TokenStakingDAPPAI: token transfer via emergency withdraw not succeeded");
        require(token.transfer(owner(), fees), "TokenStakingDAPPAI: token transfer via emergency withdraw to admin is not succeeded");

        // Emit withdrawal event
        emit WithdrawAll(_msgSender(), total);
    }

    // Function to toggle staking status
    function toggleStaking(bool _start) external onlyOwner returns (bool) {
        started = _start;
        return true;
    }

    // Function to get order IDs of an investor
    function investorOrderIds(address investor) external view returns (uint256[] memory ids) {
        uint256[] memory arr = orderIds[investor];
        return arr;
    }

    // Function to calculate total rewards of an address
    function _totalRewards(address ref) private view returns (uint256) {
        uint256 rewards;
        uint256[] memory arr = orderIds[ref];
        for (uint256 i = 0; i < arr.length; i++) {
            OrderInfo memory order = orders[arr[i]];
            rewards += (order.claimedReward + pendingRewards(arr[i]));
        }
        return rewards;
    }

    // Function to transfer remaining tokens to the owner
    function transferToken() external onlyOwner {
        uint256 amount = IERC20(token).balanceOf(address(this));
        uint256 transferAmount = amount - totalStake;
        IERC20(token).transfer(owner(), transferAmount);
    }
}
