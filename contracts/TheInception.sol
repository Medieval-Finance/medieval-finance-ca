// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/SafeMath.sol";

contract TheInception is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 depFee; // deposit fee that is applied to created pool.
        address depFeeWallet; // address that receives the deposit fee
        uint256 allocPoint; // How many allocation points assigned to this pool. SHIELDs to distribute per block.
        uint256 lastRewardTime; // Last time that SHIELDs distribution occurs.
        uint256 accSHIELDPerShare; // Accumulated SHIELDs per share, times 1e18. See below.
    }
    
    IERC20 public SHIELD;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // The time when SHIELD mining starts.
    uint256 public poolStartTime;

    // The time when SHIELD mining ends.
    uint256 public poolEndTime;
    uint256 public runningTime = 7 days;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _SHIELD,
        uint256 _poolStartTime
        ) {

        require(block.timestamp < _poolStartTime, "The Inception: pool cant be started in the past");
        if (_SHIELD != address(0)) SHIELD = IERC20(_SHIELD);

        poolStartTime = _poolStartTime;
        poolEndTime = _poolStartTime + runningTime;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "The Inception: caller is not the operator");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "The Inception: existing pool?");
        }
    }

    // bulk add pools
    function addBulk(
        uint256[] calldata _allocPoints,
        uint256[] calldata _depFees,
        address[] calldata _depFeeWallets,
        IERC20[] calldata _tokens,
        bool _withUpdate,
        uint256 _lastRewardTime
        ) external onlyOperator {
        require(
            _allocPoints.length == _depFees.length &&
            _allocPoints.length == _depFeeWallets.length &&
            _allocPoints.length == _tokens.length,
            "The Inception: invalid length"
        );
        for (uint256 i = 0; i < _allocPoints.length; i++) {
            add(_allocPoints[i], _depFees[i], _depFeeWallets[i], _tokens[i], _withUpdate, _lastRewardTime);
        }
    }

    // Add new lp to the pool. Can only be called by operator.
    function add(
        uint256 _allocPoint,
        uint256 _depFee,
        address _depFeeWallet,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime
        ) public onlyOperator {
        require(_depFee <= 100, "The Inception: deposit fee cant be more than 1%");  // deposit fee cant be more than 1%;
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime < poolStartTime) {
                _lastRewardTime = poolStartTime;
            }
        } else {
            // chef is cooking
            if (_lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        poolInfo.push(PoolInfo({
            token: _token,
            depFee: _depFee,
            depFeeWallet: _depFeeWallet,
            allocPoint: _allocPoint,
            lastRewardTime: _lastRewardTime,
            accSHIELDPerShare: 0
        }));
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
    }

    // Update the given pool's SHIELD allocation point. Can only be called by the operator.
    function set(uint256 _pid, uint256 _allocPoint, uint256 _depFee, address _depFeeWallet) public onlyOperator {
        massUpdatePools();

        PoolInfo storage pool = poolInfo[_pid];
        require(_depFee <= 100, "The Inception: deposit fee cant be more than 1%");  // deposit fee cant be more than 1%;
        pool.depFee = _depFee;
        pool.depFeeWallet = _depFeeWallet;
        totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        pool.allocPoint = _allocPoint;
    }

    // bulk set pools
    function bulkSet(uint256[] calldata _pids, uint256[] calldata _allocPoints, uint256[] calldata _depFees, address[] calldata _depFeeWallets) external onlyOperator {
        require(
            _pids.length == _allocPoints.length &&
            _pids.length == _depFees.length &&
            _pids.length == _depFeeWallets.length,
            "TheInception: invalid length");
        for (uint256 i = 0; i < _pids.length; i++) {
            set(_pids[i], _allocPoints[i], _depFees[i], _depFeeWallets[i]);
        }
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(totalAllocPoint);
            return poolEndTime.sub(_fromTime).mul(totalAllocPoint);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(totalAllocPoint);
            return _toTime.sub(_fromTime).mul(totalAllocPoint);
        }
    }

    // View function to see pending SHIELDs on frontend.
    function pendingSHIELD(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSHIELDPerShare = pool.accSHIELDPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _SHIELDReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accSHIELDPerShare = accSHIELDPerShare.add(_SHIELDReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accSHIELDPerShare).div(1e18).sub(user.rewardDebt);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) private {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _SHIELDReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accSHIELDPerShare = pool.accSHIELDPerShare.add(_SHIELDReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accSHIELDPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeSHIELDTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0 ) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            uint256 depositDebt = _amount.mul(pool.depFee).div(10000);
            user.amount = user.amount.add(_amount.sub(depositDebt));
            pool.token.safeTransfer(pool.depFeeWallet, depositDebt);
        }
        user.rewardDebt = user.amount.mul(pool.accSHIELDPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "TheInception: user does not have enough balance deposited");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accSHIELDPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeSHIELDTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSHIELDPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe SHIELD transfer function, just in case if rounding error causes pool to not have enough SHIELDs.
    function safeSHIELDTransfer(address _to, uint256 _amount) internal {
        uint256 _SHIELDBalance = SHIELD.balanceOf(address(this));
        if (_SHIELDBalance > 0) {
            if (_amount > _SHIELDBalance) {
                SHIELD.safeTransfer(_to, _SHIELDBalance);
            } else {
                SHIELD.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        require(block.timestamp > poolEndTime + 15 days, "TheInception: cannot recover tokens till after 15 days have passed");
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            require(_token != pool.token, "TheInception: token cannot be pool token");
        }
        _token.safeTransfer(to, amount);
    }
}