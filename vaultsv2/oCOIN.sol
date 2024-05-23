// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import './helpers/ReentrancyGuard.sol';

interface IMasterChef {
    function mintRewards(address _receiver, uint256 _amount) external;
}

interface IERC20Burnable is IERC20 {
    function burn(uint256 amount) external;
}

interface IPancakeV3Pool { // IRamsesV2Pool
        function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s,
            uint160[] memory secondsPerBoostedLiquidityPeriodX128s
        );
}

library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    function getSqrtRatioAtTick(
        int24 tick
    ) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0
            ? uint256(-int256(tick))
            : uint256(int256(tick));
        require(absTick <= uint256(uint24(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0)
            ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0)
            ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0)
            ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0)
            ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0)
            ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0)
            ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0)
            ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0)
            ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0)
            ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0)
            ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0)
            ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0)
            ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0)
            ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0)
            ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0)
            ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0)
            ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0)
            ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0)
            ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0)
            ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160(
            (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1)
        );
    }
}

contract oCOIN is ERC20("oCOIN Token", "oCOIN"), Ownable, ReentrancyGuard { 
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    IUniswapV2Pair public uniswapV2Pair;

    uint256 public constant PRECISION = 100;
    bool public optionEnabled = true;
    address public weth;
    address public coinToken;
    uint256 public rewardRate;
    address public masterChef;
    address public _operator;
    uint256 public exitRatio = 30; // get 30% liquid
    uint256 public exitRatioBond = 150; // 1.5x

    uint32 public duration = 30; // 30 secs ago
    bool public usingLegacyPair = false; // defaults to using V3
    address public tokenV3PoolAddress; // starts null

    mapping(address => bool) public minters;

    constructor(address _weth, address _coinToken) {
        _operator = msg.sender;
        weth = _weth;
        coinToken = _coinToken;
    }

    modifier onlyMinter() {
        require(minters[msg.sender] == true, "Only minters allowed");
        _;
    }

    modifier onlyMasterChef() {
        require(msg.sender == masterChef, "Caller is not MasterChef contract");
        _;
    }

    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    struct vestPosition {
        uint256 totalVested;
        uint256 lastInteractionTime;
        uint256 VestPeriod;
    }

    mapping (address => vestPosition[]) public userInfo;
    mapping (address => uint256) public userPositions;

    uint256 public vestingPeriod = 60 days;
    uint256 public bondVestingPeriod = 150 days;

    function mint(address recipient_, uint256 amount_) external onlyMinter returns (bool) {
        _mint(recipient_, amount_);
        return true;
    }

    function burn(uint256 _amount) external  {
        _burn(msg.sender, _amount);
    }

    function remainTime(address _address, uint256 id) public view returns(uint256) {
        uint256 timePass = block.timestamp.sub(userInfo[_address][id].lastInteractionTime);
        uint256 remain;
        if (timePass >= userInfo[msg.sender][id].VestPeriod){
            remain = 0;
        }
        else {
            remain = userInfo[msg.sender][id].VestPeriod- timePass;
        }
        return remain;
    }

    function lock(uint256 _amount) external nonReentrant {
        require(IERC20(coinToken).balanceOf(msg.sender) >= _amount, "COIN balance too low");
        uint256 amountOut = _amount;
        IERC20(coinToken).safeTransferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, amountOut);
        IERC20Burnable(coinToken).burn(_amount);
    }

    function vest(uint256 _amount) external nonReentrant {

        require(this.balanceOf(msg.sender) >= _amount, "oCOIN balance too low");

        userInfo[msg.sender].push(vestPosition({
            totalVested: _amount,
            lastInteractionTime: block.timestamp,
            VestPeriod: vestingPeriod
        }));

        userPositions[msg.sender] += 1; 
        _burn(msg.sender, _amount);
    }

    function vestBond(uint256 _amount) external nonReentrant {

        require(this.balanceOf(msg.sender) >= _amount, "oCOIN balance too low");

        userInfo[msg.sender].push(vestPosition({
            totalVested: _amount.mul(exitRatioBond).div(100),
            lastInteractionTime: block.timestamp,
            VestPeriod: bondVestingPeriod
        }));
        
        userPositions[msg.sender] += 1; 
        _burn(msg.sender, _amount);
    }

    /**
     * @dev exit instantly with a penalty
     * @param _amount amount of oCOIN to exit
     * @param maxPayAmount maximum amount of eth user is willing to pay
     */
    function instantExit(
        uint256 _amount,
        uint256 maxPayAmount
    ) external nonReentrant {
        require(optionEnabled, "oCOIN: Instant exit disabled");
        require(_amount > 0, "oCOIN: Amount must be greater than 0");
        uint256 exitAmount = ((exitRatio * _amount) / PRECISION);

        _burn(msg.sender, _amount);

        uint256 amountToPay = (_amount * (100 - exitRatio)) / 100;
        // amountToPay = (getCOINCurrentPrice() * amountToPay) / 1e18;
        amountToPay = quotePrice(amountToPay);
        require(amountToPay <= maxPayAmount, "Slippage!");

        IERC20(weth).transferFrom(
            msg.sender,
            _operator,
            amountToPay
        );
        exitAmount = _amount;

        IMasterChef(masterChef).mintRewards(msg.sender, exitAmount);
    }


    function quotePayment(
        uint256 amount
    ) public view returns (uint256 payAmount) {
        uint256 amountToPay = (amount * (100 - exitRatio)) / 100;
        // payAmount = (getCOINCurrentPrice() * amountToPay) / 1e18;
        payAmount = quotePrice(amountToPay);
    }

    function getCOINCurrentPrice() public view returns (uint256) {
        // Get reserves of token0 and token1
        (uint256 reserve0, uint256 reserve1, ) = uniswapV2Pair.getReserves();

        // Assume token0 is the ERC-20 token you are interested in
        address token0 = coinToken;

        if (token0 == uniswapV2Pair.token1()) {
            return reserve0 * (10**18) / reserve1;
        } else {
            return reserve1 * (10**18) / reserve0;
        }
    }

    function quotePrice(
        uint256 amountIn
    ) public view returns (uint256 amountOut) {
        if (usingLegacyPair) {
            amountOut = (getCOINCurrentPrice() * amountIn) / 1e18;
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = duration;
            secondsAgos[1] = 0;

            (int56[] memory tickCumulatives, , ) = IPancakeV3Pool(tokenV3PoolAddress).observe(
                secondsAgos
            );

            int56 tickCumulativesDelta = tickCumulatives[1] -
                tickCumulatives[0];

            int24 tick = int24(tickCumulativesDelta / int56(int32(duration)));
            if (
                tickCumulativesDelta < 0 &&
                (tickCumulativesDelta % int56(int32(duration)) != 0)
            ) {
                tick--;
            }

            // hardcoded zeroForOne
            uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
            if (sqrtRatioX96 <= type(uint128).max) {
                uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
                amountOut = Math.mulDiv(1 << 192, amountIn, ratioX192);
            } else {
                uint256 ratioX128 = Math.mulDiv(
                    sqrtRatioX96,
                    sqrtRatioX96,
                    1 << 64
                );
                amountOut = Math.mulDiv(1 << 128, amountIn, ratioX128);
            }
        }
    }


    function claim(uint256 id) external nonReentrant {
        require(remainTime(msg.sender, id) == 0, "vesting not end");
        vestPosition storage position = userInfo[msg.sender][id];
        uint256 claimAmount = position.totalVested;
        position.totalVested = 0;
        IMasterChef(masterChef).mintRewards(msg.sender, claimAmount);
    }

    function setRewardRate(uint256 _rewardRate) public onlyMasterChef {
        rewardRate = _rewardRate;
    }

    function setOptionEnabled(bool _optionEnabled) public onlyOwner {
        optionEnabled = _optionEnabled;
    }

    /// @notice set twap interval, 3600 for 1 hour twap
    function setSecondsAgo(uint32 _duration) public onlyOwner {
        duration = _duration;
    }

    /// @dev setPool to legacy pair when setting legacy
    function useLegacyPair(bool legacy) public onlyOwner {
        usingLegacyPair = legacy;
    }

    function setV3Pool(address newPool) external onlyOwner {
        tokenV3PoolAddress = newPool;
    }

    function setV2Pool(address newPool) external onlyOwner {
        uniswapV2Pair = IUniswapV2Pair(newPool);
    }

    function setMasterChef(address _masterChef) public onlyOwner {
        masterChef = _masterChef;
    }

    function transferOperator(address newOperator_) public onlyOwner {
        _transferOperator(newOperator_);
    }

    function setExitRatio(uint256 _exitRatio, uint256 _exitRatioBond) public onlyOwner {
        require(_exitRatio <= 95, "Cant be more than 95");
        require(_exitRatio >= 5, "Cant be less than 5");
        require(_exitRatioBond <= 500, "Cant be more than 500");
        require(_exitRatioBond >= 100, "Cant be less than 100");
        exitRatio = _exitRatio;
        exitRatioBond = _exitRatioBond;
    }

    function _transferOperator(address newOperator_) internal {
        require(newOperator_ != address(0), "operator: zero address given for new operator");
        _operator = newOperator_;
    }

    function setMinters(address _minter, bool _canMint) public onlyOperator {
        minters[_minter] = _canMint;
    }

}
