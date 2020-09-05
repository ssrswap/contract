pragma solidity ^0.5.9;

import "./SunshineRanchToken.sol";


contract TRONRanch is Ownable {

    using SafeMath for uint256;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 rewardPending;
    }


    // Info of each pool.
    struct PoolInfo {
        TRC20 lpToken;

        uint256 allocPoint;

        uint256 lastRewardBlock;

        uint256 accSSRPerShare;

        uint256 totalPool;
    }

    SunshineToken public ssr;
    address public devaddr;
    uint256 public bonusEndBlock;
    uint256 public ssrPerBlock;
    uint256 public constant BONUS_MULTIPLIER = 10;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 0;
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        SunshineToken _ssr,
        address _devaddr,
        uint256 _ssrPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        ssr = _ssr;
        devaddr = _devaddr;
        ssrPerBlock = _ssrPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function setStartBlock(uint256 _startBlock,uint256 _bonusEndBlock) public onlyOwner{
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function setPerBlock(uint256 _ssrPerBlock) public onlyOwner {

        ssrPerBlock = _ssrPerBlock;
    }

    function add(uint256 _allocPoint, TRC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accSSRPerShare : 0,
            totalPool : 0
            }));
    }


    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }


    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    function pendingSSR(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSSRPerShare = pool.accSSRPerShare;
        uint256 lpSupply = pool.totalPool;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 sushiReward = multiplier.mul(ssrPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accSSRPerShare = accSSRPerShare.add(sushiReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accSSRPerShare).div(1e12).sub(user.rewardDebt).add(user.rewardPending);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.totalPool;

        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        
        uint256 sushiReward = multiplier.mul(ssrPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        ssr.mint(devaddr, sushiReward.div(1));
        ssr.mint(address(this), sushiReward);
        pool.accSSRPerShare = pool.accSSRPerShare.add(sushiReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    function deposit(uint256 _pid, uint256 _amount) public payable {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accSSRPerShare).div(1e12).sub(user.rewardDebt);
            //            safeSushiTransfer(msg.sender, pending);
            user.rewardPending = user.rewardPending.add(pending);
        }
        if (address(pool.lpToken) == address(0)) {
            _amount = msg.value;
        } else {
            pool.lpToken.transferFrom(address(msg.sender), address(this), _amount);
        }
        pool.totalPool = pool.totalPool.add(_amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accSSRPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public returns (uint){
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        pool.totalPool = pool.totalPool.sub(_amount);
        uint256 pending = user.amount.mul(pool.accSSRPerShare).div(1e12).sub(user.rewardDebt) + user.rewardPending;
        safeSushiTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardPending = 0;
        user.rewardDebt = user.amount.mul(pool.accSSRPerShare).div(1e12);
        if (address(pool.lpToken) == address(0)) {
            address(msg.sender).transfer(_amount);
        } else {
            pool.lpToken.transfer(address(msg.sender), _amount);
        }
        emit Withdraw(msg.sender, _pid, _amount);

        return pending;
    }

    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (address(pool.lpToken) == address(0)) {
            address(msg.sender).transfer(user.amount);
        } else {
            pool.lpToken.transfer(address(msg.sender), user.amount);
        }
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardPending = 0;
    }

    function safeSushiTransfer(address _to, uint256 _amount) internal {
        uint256 sushiBal = ssr.balanceOf(address(this));
        if (_amount > sushiBal) {
            ssr.transfer(_to, sushiBal);
        } else {
            ssr.transfer(_to, _amount);
        }
    }

    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function transferSSROwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0));

        ssr.transferOwnership(newOwner);
    }

    function transfer(uint256 _pid, address payable _to, uint256 _amount) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        if (address(pool.lpToken) == address(0)) {
            _to.transfer(_amount);
        } else {
            pool.lpToken.transfer(_to, _amount);
        }
    }
}

