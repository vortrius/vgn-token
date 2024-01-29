// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @custom:security-contact support@vortrius.com
contract VGNRewards is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;

  //region Variables
  IERC20 public token;
  IERC20 public usdt;
  uint8 public currentMonth;
  VGNStake public stakeContract;
  VGNVestedStake public vestedStakeContract;

  bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

  struct Earnings {
    uint256 usdt;
    uint256 vgn;
    uint256 eth;
    bool deposited;
  }

  mapping(uint8 => Earnings) public monthEarnings;
  mapping(address => mapping(uint8 => mapping(uint16 => bool))) public stakeMonthHarvested;
  mapping(address => mapping(uint8 => mapping(uint16 => bool))) public vestedStakeMonthHarvested;

  //endregion

  //region Events

  event Harvested(
    address indexed user,
    uint16 indexed index,
    uint8 indexed month,
    bool isVested,
    uint256 usdt,
    uint256 vgn,
    uint256 eth
  );
  event Deposited(uint8 month, uint256 usdt, uint256 vgn, uint256 eth);
  event IncrementedMonth(uint8 lastMonth, uint8 currentMonth);

  //endregion

  function initialize(
    VGNStake _stakeContract,
    VGNVestedStake _vestedStakeContract,
    IERC20 _tokenAddress,
    IERC20 _usdtAddress
  ) public initializer {
    __AccessControl_init();
    __ReentrancyGuard_init();
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    stakeContract = _stakeContract;
    vestedStakeContract = _vestedStakeContract;
    token = _tokenAddress;
    usdt = _usdtAddress;
  }

  //region Public Functions

  function harvest(uint16 _index, uint8 _month, bool _isVested) public nonReentrant {
    //HNEM: Harvest: No earnings for this month
    require(monthEarnings[_month].deposited, "HNEM");

    if (_isVested) {
      //HII: Harvest: Invalid index
      require(vestedStakeContract.getStakesLength(msg.sender) > _index, "HII");
      //HIS: Harvest: Inactive stake
      require(!vestedStakeContract.getStakeAtIndex(msg.sender, _index).inactive, "HIS");
      //HAHM: Harvest: Already harvested for this month
      require(!vestedStakeMonthHarvested[msg.sender][_month][_index], "HAHM");
    } else {
      //HII: Harvest: Invalid index
      require(stakeContract.getStakesLength(msg.sender) > _index, "HII");
      //HIS: Harvest: Inactive stake
      require(!stakeContract.getStakeAtIndex(msg.sender, _index).inactive, "HIS");
      //HAHM: Harvest: Already harvested for this month
      require(!stakeMonthHarvested[msg.sender][_month][_index], "HAHM");
    }

    //HCNHCM: Harvest: Can't harvest for current month
    require(_month < currentMonth, "HCNHCM");

    uint256 realPercentage = _realPercentage(msg.sender, _index, _month, _isVested);

    if (_isVested) {
      vestedStakeMonthHarvested[msg.sender][_month][_index] = true;
    } else {
      stakeMonthHarvested[msg.sender][_month][_index] = true;
    }

    Earnings memory earnings = monthEarnings[_month];

    uint256 totalUsdt = (earnings.usdt * realPercentage) / 1 ether;
    uint256 totalVgn = (earnings.vgn * realPercentage) / 1 ether;
    uint256 totalEth = (earnings.eth * realPercentage) / 1 ether;

    emit Harvested(msg.sender, _index, _month, _isVested, totalUsdt, totalVgn, totalEth);

    if (earnings.usdt > 0) {
      usdt.safeTransfer(msg.sender, totalUsdt);
    }

    if (earnings.vgn > 0) {
      token.safeTransfer(msg.sender, totalVgn);
    }

    if (earnings.eth > 0) {
      payable(msg.sender).transfer(totalEth);
    }
  }

  //endregion

  //region Public Views

  function getAvailableHarvest(
    address _user,
    uint16 _index,
    uint8 _month,
    bool _isVested
  ) public view returns (uint256, uint256, uint256) {
    uint256 realPercentage = _realPercentage(_user, _index, _month, _isVested);

    Earnings memory earnings = monthEarnings[_month];

    uint256 usdtAmount = 0;
    uint256 vgnAmount = 0;
    uint256 ethAmount = 0;

    if (earnings.usdt > 0) {
      usdtAmount = (earnings.usdt * realPercentage) / 1 ether;
    }

    if (earnings.vgn > 0) {
      vgnAmount = (earnings.vgn * realPercentage) / 1 ether;
    }

    if (earnings.eth > 0) {
      ethAmount = (earnings.eth * realPercentage) / 1 ether;
    }

    return (usdtAmount, vgnAmount, ethAmount);
  }

  function getEarningsForEachMonth() public view returns (Earnings[] memory) {
    Earnings[] memory earnings = new Earnings[](currentMonth + 1);
    for (uint8 i = 0; i <= currentMonth; i++) {
      earnings[i] = monthEarnings[i];
    }
    return earnings;
  }

  function getEarningsPercentage(
    address _user,
    uint16 _index,
    uint8 _month,
    bool _isVested
  ) public view returns (uint256) {
    return _realPercentage(_user, _index, _month, _isVested);
  }

  //endregion

  //region OnlyOwner Functions

  function deposit(uint256 _usdt, uint256 _vgn) public payable onlyRole(DEPOSITOR_ROLE) nonReentrant {
    //DIUB: Deposit: Insufficient USDT balance
    require(usdt.balanceOf(msg.sender) >= _usdt, "DIUB");
    //DIVB: Deposit: Insufficient VGN balance
    require(token.balanceOf(msg.sender) >= _vgn, "DIVB");
    //DIEB: Deposit: Insufficient ETH balance
    require(address(this).balance >= msg.value, "DIEB");
    //DAD: Deposit: Already deposited for this month
    require(!monthEarnings[currentMonth].deposited, "DAD");

    monthEarnings[currentMonth].usdt = _usdt;
    monthEarnings[currentMonth].vgn = _vgn;
    monthEarnings[currentMonth].eth = msg.value;
    monthEarnings[currentMonth].deposited = true;

    usdt.safeTransferFrom(msg.sender, address(this), _usdt);
    token.safeTransferFrom(msg.sender, address(this), _vgn);

    emit Deposited(currentMonth, _usdt, _vgn, msg.value);
    _incrementMonth();
  }

  function _incrementMonth() internal {
    uint8 lastMonth = currentMonth;
    currentMonth++;
    stakeContract.updateTotalMonthStaked(lastMonth, currentMonth);
    stakeContract.updateCurrentMonth(currentMonth);
    vestedStakeContract.updateTotalMonthStaked(lastMonth, currentMonth);
    vestedStakeContract.updateCurrentMonth(currentMonth);
    emit IncrementedMonth(lastMonth, currentMonth);
  }

  //endregion

  //region Internals

  function _realPercentage(address _user, uint16 _index, uint8 _month, bool _isVested) internal view returns (uint256) {
    uint256 available;
    uint8 multiplier;

    uint256 totalStake = vestedStakeContract.totalMonthStaked(_month) + stakeContract.totalMonthStaked(_month);

    if (_isVested) {
      VGNVestedStake.VestedStake memory vestedStake = vestedStakeContract.getStakeAtIndex(_user, _index);
      available = (vestedStake.totalAmount - vestedStake.totalWithdrawn);
      multiplier = vestedStakeContract.getStakeMultiplier();
    } else {
      VGNStake.Stake memory stake = stakeContract.getStakeAtIndex(_user, _index);
      available = (stake.totalAmount - stake.totalWithdrawn);
      multiplier = stakeContract.getStakeMultiplier(_user, _index);
    }
    uint256 percentage = (available * 1 ether) / totalStake;

    return (percentage * multiplier) / 100;
  }

  //endregion
}

/// @custom:security-contact support@vortrius.com
contract VGNStake is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;
  //region Variables

  IERC20 public token;
  uint8 public currentMonth;

  bytes32 public constant REWARDS_ROLE = keccak256("REWARDS_ROLE");

  struct Stake {
    uint256 totalAmount;
    uint8 endLockMonth;
    uint8 startLockMonth;
    uint256 totalWithdrawn;
    uint8 lastWithdrawnMonth;
    bool inactive;
  }

  //Default Lock Periods
  uint8 public constant LOCK_PERIOD_1 = 3; //3 months
  uint8 public constant LOCK_PERIOD_2 = 6; //6 months
  uint8 public constant LOCK_PERIOD_3 = 9; //9 months

  //Default Multipliers values
  uint8 public constant MULTIPLIER_1 = 50; //30 days = 50%
  uint8 public constant MULTIPLIER_2 = 75; //60 days = 75%
  uint8 public constant MULTIPLIER_3 = 100; //90 days = 100%

  mapping(address => Stake[]) public stakes;

  mapping(uint8 => uint256) public totalMonthStaked;

  mapping(address => mapping(uint16 => mapping(uint8 => uint256))) public stakeWithdrawals;

  //endregion

  //region Events
  event StakeCreated(address indexed user, Stake stake);
  event Withdraw(address indexed user, uint16 indexed index, uint8 indexed month, uint256 amount, uint256 multiplier);

  //endregion

  function initialize(IERC20 _tokenAddress) public initializer {
    __AccessControl_init();
    __ReentrancyGuard_init();
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    token = _tokenAddress;
  }

  //region Public Functions

  function stake(uint256 _amount, uint8 _lockPeriod) public nonReentrant {
    //SAG0: Stake: Amount must be greater 0"
    require(_amount > 0, "SAG0");
    //SIB: Stake: Insufficient balance
    require(token.balanceOf(msg.sender) >= _amount, "SIB");
    //SILP: Stake: Invalid lock period
    require(_lockPeriod > 0 && _lockPeriod <= 3, "SILP");
    uint8 lockPeriod = _lockPeriod == 1 ? LOCK_PERIOD_1 : _lockPeriod == 2 ? LOCK_PERIOD_2 : LOCK_PERIOD_3;

    totalMonthStaked[currentMonth] += _amount;
    stakes[msg.sender].push(Stake(_amount, currentMonth + lockPeriod, currentMonth, 0, currentMonth, false));

    token.safeTransferFrom(msg.sender, address(this), _amount);
    emit StakeCreated(msg.sender, stakes[msg.sender][stakes[msg.sender].length - 1]);
  }

  function withdraw(uint16 _index, uint256 _amount) public nonReentrant {
    //WAG0: Withdraw: Amount must be greater 0
    require(_amount > 0, "WAG0");
    //WII: Withdraw: Invalid index
    require(stakes[msg.sender].length > _index, "WII");
    //WLPNOY: Withdraw: Lock period not over yet
    require(stakes[msg.sender][_index].endLockMonth <= currentMonth, "WLPNOY");
    //WIS: Withdraw: Inactive stake
    require(!stakes[msg.sender][_index].inactive, "WIS");

    uint256 availableForWithdrawal = stakes[msg.sender][_index].totalAmount - stakes[msg.sender][_index].totalWithdrawn;

    //WIB: Withdraw: Insufficient balance
    require(availableForWithdrawal >= _amount, "WIB");

    stakes[msg.sender][_index].totalWithdrawn += _amount;
    stakes[msg.sender][_index].lastWithdrawnMonth = currentMonth;

    if (availableForWithdrawal == _amount) {
      stakes[msg.sender][_index].inactive = true;
    }

    stakeWithdrawals[msg.sender][_index][currentMonth] += _amount;
    totalMonthStaked[currentMonth] -= _amount;
    token.safeTransfer(msg.sender, _amount);
    emit Withdraw(msg.sender, _index, currentMonth, _amount, getStakeMultiplier(msg.sender, _index));
  }

  //endregion

  //region Public Views

  function getStakes(address _user) public view returns (Stake[] memory) {
    return stakes[_user];
  }

  function getStakeUnlockTime(address _user, uint16 _index) public view returns (uint8) {
    uint8 endLockMonth;

    endLockMonth = stakes[_user][_index].endLockMonth;

    if (endLockMonth < currentMonth) {
      return 0;
    } else {
      return endLockMonth - currentMonth;
    }
  }

  function getStakeMultiplier(address _user, uint16 _index) public view returns (uint8) {
    uint8 monthsSinceLastWithdrawn;
    monthsSinceLastWithdrawn = currentMonth - stakes[_user][_index].lastWithdrawnMonth;

    if (stakes[_user][_index].totalWithdrawn == 0) {
      return MULTIPLIER_3;
    } else if (monthsSinceLastWithdrawn >= 2) {
      return MULTIPLIER_3;
    } else if (monthsSinceLastWithdrawn == 1) {
      return MULTIPLIER_2;
    } else {
      return MULTIPLIER_1;
    }
  }

  function getAvailableWithdrawal(address _user, uint16 _index) public view returns (uint256) {
    return stakes[_user][_index].totalAmount - stakes[_user][_index].totalWithdrawn;
  }

  function getVariables() public view returns (uint8[] memory, uint8[] memory, uint8) {
    uint8[] memory periods = new uint8[](3);
    periods[0] = LOCK_PERIOD_1;
    periods[1] = LOCK_PERIOD_2;
    periods[2] = LOCK_PERIOD_3;

    uint8[] memory multipliers = new uint8[](3);
    multipliers[0] = MULTIPLIER_1;
    multipliers[1] = MULTIPLIER_2;
    multipliers[2] = MULTIPLIER_3;

    return (periods, multipliers, currentMonth);
  }

  function getStakeWithdrawals(address _user, uint16 _index) public view returns (uint256[] memory) {
    uint256[] memory withdrawals = new uint256[](currentMonth + 1);
    for (uint8 i = 0; i <= currentMonth; i++) {
      withdrawals[i] = stakeWithdrawals[_user][_index][i];
    }
    return withdrawals;
  }

  function getStakedAmountForEachMonth() public view returns (uint256[] memory) {
    uint256[] memory stakedAmounts = new uint256[](currentMonth + 1);
    for (uint8 i = 0; i <= currentMonth; i++) {
      stakedAmounts[i] = totalMonthStaked[i];
    }
    return stakedAmounts;
  }

  function getStakeAtIndex(address _user, uint16 _index) public view returns (Stake memory) {
    return stakes[_user][_index];
  }

  function getStakesLength(address _user) public view returns (uint256) {
    return stakes[_user].length;
  }

  //endregion

  //region Admin Functions

  function updateTotalMonthStaked(uint8 _lastMonth, uint8 _month) public onlyRole(REWARDS_ROLE) {
    totalMonthStaked[_month] = totalMonthStaked[_lastMonth];
  }

  function updateCurrentMonth(uint8 _month) public onlyRole(REWARDS_ROLE) {
    currentMonth = _month;
  }

  //endregion
}

/// @custom:security-contact support@vortrius.com
contract VGNVestedStake is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;
  //region Variables
  IERC20 public token;
  IERC20 public usdt;
  uint8 public currentMonth;

  bytes32 public constant REWARDS_ROLE = keccak256("REWARDS_ROLE");
  bytes32 public constant STAKE_CREATOR = keccak256("STAKE_CREATOR");

  struct VestedStake {
    uint256 totalAmount;
    uint8 endLockMonth;
    uint8 startLockMonth;
    uint256 totalWithdrawn;
    uint8 lastWithdrawnMonth;
    uint8 endVestingMonth;
    uint8 startVestingMonth;
    bool inactive;
    bool claimedTGE;
  }

  mapping(address => VestedStake[]) public stakes;

  mapping(uint8 => uint256) public totalMonthStaked;

  mapping(address => mapping(uint16 => mapping(uint8 => uint256))) public stakeWithdrawals;

  //endregion

  //region Events

  event StakeCreated(address indexed user, VestedStake stake);
  event Withdraw(address indexed user, uint16 indexed index, uint8 indexed month, uint256 amount, uint256 multiplier);
  event ClaimedTGE(address indexed user, uint16 indexed index, uint8 indexed month, uint256 amount);
  event Transfer(address indexed from, address indexed to, uint16 indexed index, VestedStake stake);

  //endregion

  function initialize(IERC20 _tokenAddress) public initializer {
    __AccessControl_init();
    __ReentrancyGuard_init();
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    token = _tokenAddress;
  }

  //region Public Functions

  function withdraw(uint16 _index, uint256 _amount) public nonReentrant {
    //WAG0: Withdraw: Amount must be greater 0
    require(_amount > 0, "WAG0");
    //WII: Withdraw: Invalid index
    require(stakes[msg.sender].length > _index, "WII");
    //WLPNOY: Withdraw: Lock period not over yet
    require(stakes[msg.sender][_index].endLockMonth <= currentMonth, "WLPNOY");
    //WIVS: Withdraw: Inactive vested stake
    require(!stakes[msg.sender][_index].inactive, "WIS");

    uint256 availableForWithdrawal = getAvailableWithdrawal(msg.sender, _index);

    //WIVB: Withdraw: Insufficient vested balance
    require(availableForWithdrawal >= _amount, "WIVB");

    stakes[msg.sender][_index].totalWithdrawn += _amount;
    stakes[msg.sender][_index].lastWithdrawnMonth = currentMonth;

    if (availableForWithdrawal == _amount) {
      stakes[msg.sender][_index].inactive = true;
    }

    totalMonthStaked[currentMonth] += _amount;
    stakeWithdrawals[msg.sender][_index][currentMonth] += _amount;
    token.safeTransfer(msg.sender, _amount);
    emit Withdraw(msg.sender, _index, currentMonth, _amount, getStakeMultiplier());
  }

  function claimTGE(uint16 _index) public nonReentrant {
    //CTGEII: Claim TGE: Invalid index
    require(stakes[msg.sender].length > _index, "CTGEII");
    //CTGEAC: Claim TGE: Already claimed
    require(!stakes[msg.sender][_index].claimedTGE, "CTGEAC");

    uint256 amount = getTGEAmount(msg.sender, _index);

    //CTGEIB: Claim TGE: Insufficient balance
    require(amount > 0, "CTGEIB");

    stakes[msg.sender][_index].claimedTGE = true;

    token.safeTransfer(msg.sender, amount);
    emit ClaimedTGE(msg.sender, _index, currentMonth, amount);
  }

  //endregion

  //region Public Views

  function getStakes(address _user) public view returns (VestedStake[] memory) {
    return stakes[_user];
  }

  function getStakeUnlockTime(address _user, uint16 _index) public view returns (uint8) {
    uint8 endLockMonth = stakes[_user][_index].endLockMonth;

    if (endLockMonth < currentMonth) {
      return 0;
    } else {
      return endLockMonth - currentMonth;
    }
  }

  function getStakeMultiplier() public pure returns (uint8) {
    return 100;
  }

  function getAvailableWithdrawal(address _user, uint16 _index) public view returns (uint256) {
    if (currentMonth < stakes[_user][_index].startVestingMonth) {
      return 0;
    }
    uint256 vestingMonths = stakes[_user][_index].endVestingMonth - stakes[_user][_index].startVestingMonth;
    uint256 amountPerMonth = vestingMonths == 0
      ? stakes[_user][_index].totalAmount
      : stakes[_user][_index].totalAmount / vestingMonths;
    uint256 monthsSinceStart = currentMonth - stakes[_user][_index].startVestingMonth;

    if (monthsSinceStart >= vestingMonths) {
      return stakes[_user][_index].totalAmount - stakes[_user][_index].totalWithdrawn;
    }

    uint256 availableForWithdrawal = vestingMonths == 0
      ? stakes[_user][_index].totalAmount
      : (amountPerMonth * monthsSinceStart) - stakes[_user][_index].totalWithdrawn;

    return availableForWithdrawal;
  }

  function getTGEAmount(address _user, uint16 _index) public view returns (uint256) {
    if (!stakes[_user][_index].claimedTGE) {
      return stakes[_user][_index].totalAmount / 20;
    } else {
      return 0;
    }
  }

  function getStakeWithdrawals(address _user, uint16 _index) public view returns (uint256[] memory) {
    uint256[] memory withdrawals = new uint256[](currentMonth + 1);
    for (uint8 i = 0; i <= currentMonth; i++) {
      withdrawals[i] = stakeWithdrawals[_user][_index][i];
    }
    return withdrawals;
  }

  function getStakedAmountForEachMonth() public view returns (uint256[] memory) {
    uint256[] memory stakedAmounts = new uint256[](currentMonth + 1);
    for (uint8 i = 0; i <= currentMonth; i++) {
      stakedAmounts[i] = totalMonthStaked[i];
    }
    return stakedAmounts;
  }

  function getStakeAtIndex(address _user, uint16 _index) public view returns (VestedStake memory) {
    return stakes[_user][_index];
  }

  function getStakesLength(address _user) public view returns (uint256) {
    return stakes[_user].length;
  }

  //endregion

  //region Admin Functions

  function create(
    address _address,
    uint256 _amount,
    uint8 _lockMonths,
    uint8 _vestingMonths
  ) public onlyRole(STAKE_CREATOR) nonReentrant {
    //SAG0: Stake: Amount must be greater 0
    require(_amount > 0, "SAG0");
    //SIB: Stake: Insufficient balance
    require(token.balanceOf(msg.sender) >= _amount, "SIB");

    uint8 endLockMonth = currentMonth + _lockMonths;
    uint8 endVestingMonth = endLockMonth + _vestingMonths;

    totalMonthStaked[currentMonth] += _amount;
    stakes[_address].push(
      VestedStake(_amount, endLockMonth, currentMonth, 0, currentMonth, endVestingMonth, endLockMonth, false, false)
    );

    token.safeTransferFrom(msg.sender, address(this), _amount);

    emit StakeCreated(_address, stakes[_address][stakes[_address].length - 1]);
  }

  function updateTotalMonthStaked(uint8 _lastMonth, uint8 _month) public onlyRole(REWARDS_ROLE) {
    totalMonthStaked[_month] = totalMonthStaked[_lastMonth];
  }

  function updateCurrentMonth(uint8 _month) public onlyRole(REWARDS_ROLE) {
    currentMonth = _month;
  }

  function transfer(
    address _from,
    address _to,
    uint16 _index,
    uint256 _amount
  ) public onlyRole(STAKE_CREATOR) nonReentrant {
    require(stakes[_from].length > _index, "TII"); //TII: Transfer: Invalid index
    require(!stakes[_from][_index].inactive, "TSI"); //TSI: Transfer: Stake is inactive
    require(_from != _to, "TSFT"); //TSFT: Transfer: Can't transfer to same address
    require(_amount > 0, "TAMZ"); //TAMZ: Transfer: Amount must be greater 0
    require(stakes[_from][_index].totalAmount >= _amount, "TIB"); //TIB: Transfer: Insufficient balance
    require(stakes[_from][_index].claimedTGE, "TSC"); //TSC: Transfer: TGE not claimed yet

    stakes[_from][_index].totalAmount -= _amount;
    stakes[_to].push(
      VestedStake(
        _amount,
        stakes[_from][_index].endLockMonth,
        stakes[_from][_index].startLockMonth,
        0,
        stakes[_from][_index].lastWithdrawnMonth,
        stakes[_from][_index].endVestingMonth,
        stakes[_from][_index].startVestingMonth,
        false,
        true
      )
    );

    if (stakes[_from][_index].totalAmount == 0) {
      stakes[_from][_index].inactive = true;
    }

    emit Transfer(_from, _to, _index, stakes[_to][stakes[_to].length - 1]);
  }

  //endregion
}
