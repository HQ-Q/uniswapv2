/// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

/// ERC20 代币标准
import "./solmate/tokens/ERC20.sol";
/// 数学库（sqrt、min等函数）
import "./libraries/Math.sol";
/// 定点数库（用于精确计算价格累积值）
import "./libraries/UQ112x112.sol";
/// Flash交换回调接口
import "./interfaces/IZuniswapV2Callee.sol";

///  @title ERC20接口
///  定义基础的ERC20函数接口
interface IERC20 {
    function balanceOf(address) external returns (uint256);

    function transfer(address to, uint256 amount) external;
}

///  交易对已被初始化过
error AlreadyInitialized();
///  代币余额超过uint112最大值
error BalanceOverflow();
///  输入的代币数量不足
error InsufficientInputAmount();
///  交易对的储备量不足
error InsufficientLiquidity();
///  销毁流动性返还的代币为0
error InsufficientLiquidityBurned();
///  铸造的流动性代币数量不足
error InsufficientLiquidityMinted();
///  输出的代币数量不足
error InsufficientOutputAmount();
///  恒定乘积公式被破坏
error InvalidK();
///  代币转账失败
error TransferFailed();

///  @title ZuniswapV2Pair
///  Uniswap V2 交易对合约
///  @dev 实现恒定乘积做市商(CPMM)模型：x*y=k
///  继承ERC20以支持LP代币，继承Math获得数学函数
contract ZuniswapV2Pair is ERC20, Math {
    ///  使用UQ112x112定点数库处理uint224类型
    using UQ112x112 for uint224;

    /// 最小流动性，防止初始化时除以零（被烧掉）
    uint256 constant MINIMUM_LIQUIDITY = 1000;

    ///  第一个代币地址（地址较小的那个）
    address public token0;
    ///  第二个代币地址（地址较大的那个）
    address public token1;
    ///  token0的储备量
    uint112 private reserve0;
    ///  token1的储备量
    uint112 private reserve1;
    ///  最后一次储备更新的区块时间戳
    uint32 private blockTimestampLast;

    ///  token0相对token1的时间加权平均价格（TWAP）累积值
    ///  @dev 用于Uniswap预言机，可计算任意时间段的平均价格
    uint256 public price0CumulativeLast;
    ///  token1相对token0的时间加权平均价格（TWAP）累积值
    uint256 public price1CumulativeLast;

    ///  重入保护标志（防止在swap过程中再次进入）
    bool private isEntered;

    ///  移除流动性事件
    ///  @param sender 发起销毁的地址
    ///  @param amount0 返还的token0数量
    ///  @param amount1 返还的token1数量
    ///  @param to 接收代币的地址
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address to
    );

    ///  添加流动性事件
    ///  @param sender 发起添加的地址
    ///  @param amount0 添加的token0数量
    ///  @param amount1 添加的token1数量
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);

    ///  储备量同步事件
    ///  @param reserve0 当前token0储备
    ///  @param reserve1 当前token1储备
    event Sync(uint256 reserve0, uint256 reserve1);

    ///  交换事件
    ///  @param sender 发起交换的地址
    ///  @param amount0Out 输出的token0数量
    ///  @param amount1Out 输出的token1数量
    ///  @param to 接收输出代币的地址
    event Swap(
        address indexed sender,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    ///  防止重入攻击修饰符
    ///  @dev 检查isEntered标志，在函数执行前设为true，执行后恢复为false
    modifier nonReentrant() {
        /// 检查：还没进入函数
        require(!isEntered);
        /// 设置标志为已进入
        isEntered = true;
        /// 执行被修饰的函数
        _;
        /// 恢复标志为未进入
        isEntered = false;
    }

    ///  构造函数
    ///  @dev 初始化LP代币，名称为"ZuniswapV2 Pair",符号为"ZUNIV2",精度为18位
    constructor() ERC20("ZuniswapV2 Pair", "ZUNIV2", 18) {}

    ///  初始化交易对（只能调用一次）
    ///  @dev 工厂合约创建后立即调用此函数，设置两个代币地址
    ///  @param token0_ 第一个代币地址（较小地址）
    ///  @param token1_ 第二个代币地址（较大地址）
    function initialize(address token0_, address token1_) public {
        /// 防止重复初始化
        if (token0 != address(0) || token1 != address(0))
            revert AlreadyInitialized();

        /// 设置两个代币地址
        token0 = token0_;
        token1 = token1_;
    }

    ///  添加流动性，铸造LP代币
    ///  @dev 用户需要先将代币转入此合约，再调用此函数
    ///  使用恒定乘积公式计算LP代币数量
    ///  @param to 接收LP代币的地址
    ///  @return liquidity 铸造的LP代币数量
    function mint(address to) public returns (uint256 liquidity) {
        /// 获取当前储备（旧值）
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        /// 获取合约中的实际代币余额（包括新转入的）
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        /// 计算用户转入的代币数量（当前余额 - 旧储备）
        uint256 amount0 = balance0 - reserve0_;
        uint256 amount1 = balance1 - reserve1_;

        /// 分两种情况计算流动性代币
        if (totalSupply == 0) {
            /// 第一次添加流动性：LP数 = sqrt(amount0 * amount1) - 最小流动性
            /// 最小流动性被永久锁定，防止价格操纵和除以零
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            /// 烧掉最小流动性到零地址
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            /// 后续添加流动性：按比例铸造
            /// LP数 = min((amount0 / reserve0) * totalSupply, (amount1 / reserve1) * totalSupply)
            /// 取较小值防止用户损失
            liquidity = Math.min(
                (amount0 * totalSupply) / reserve0_,
                (amount1 * totalSupply) / reserve1_
            );
        }

        /// 校验：铸造的流动性必须 > 0
        if (liquidity <= 0) revert InsufficientLiquidityMinted();

        /// 铸造LP代币给接收者
        _mint(to, liquidity);

        /// 更新储备和价格累积值
        _update(balance0, balance1, reserve0_, reserve1_);

        /// 发出事件
        emit Mint(to, amount0, amount1);
    }

    ///  移除流动性，销毁LP代币
    ///  @dev 用户需要先将LP代币转入此合约，再调用此函数
    ///  @param to 接收返回代币的地址
    ///  @return amount0 返还的token0数量
    ///  @return amount1 返还的token1数量
    function burn(
        address to
    ) public returns (uint256 amount0, uint256 amount1) {
        /// 获取合约中两种代币的当前余额
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        /// 获取待销毁的LP代币数量（用户转入到此合约的）
        uint256 liquidity = balanceOf[address(this)];

        /// 计算应该返还给用户的代币数量
        /// amount = (要销毁的LP / 总LP) * 对应代币的余额
        amount0 = (liquidity * balance0) / totalSupply;
        amount1 = (liquidity * balance1) / totalSupply;

        /// 校验：返还的代币数量都必须 > 0
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        /// 销毁LP代币
        _burn(address(this), liquidity);

        /// 转账返还代币给接收者
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        /// 重新获取销毁后的余额
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        /// 更新储备和价格累积值
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        _update(balance0, balance1, reserve0_, reserve1_);

        /// 发出事件
        emit Burn(msg.sender, amount0, amount1, to);
    }

    ///  执行代币交换
    ///  @dev 先转出token，再通过回调接收token。支持Flash Swap
    ///  使用恒定乘积公式验证交换的有效性
    ///  @param amount0Out 输出的token0数量
    ///  @param amount1Out 输出的token1数量
    ///  @param to 接收输出token的地址
    ///  @param data 交换时的回调数据（Flash Swap用）
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) public nonReentrant {
        /// 校验：至少要输出一种代币
        if (amount0Out == 0 && amount1Out == 0)
            revert InsufficientOutputAmount();

        /// 获取当前储备
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();

        /// 校验：交易对有足够的代币输出
        if (amount0Out > reserve0_ || amount1Out > reserve1_)
            revert InsufficientLiquidity();

        /// 先转出代币给交换者（Flash Swap的关键：先转后收）
        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);
        if (data.length > 0)
            IZuniswapV2Callee(to).zuniswapV2Call(
                msg.sender,
                amount0Out,
                amount1Out,
                data
            );

        /// 获取转出后的余额（应该增加了用户转入的代币）
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        /// 计算用户实际转入的代币数量
        uint256 amount0In = balance0 > reserve0 - amount0Out
            ? balance0 - (reserve0 - amount0Out)
            : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out
            ? balance1 - (reserve1 - amount1Out)
            : 0;

        /// 校验：至少转入一种代币
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        /// 应用交换手续费（0.3%）
        /// balance0Adjusted = balance0 * 1000 - amount0In * 3
        uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
        uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);

        /// 验证恒定乘积公式：k = x * y
        if (
            balance0Adjusted * balance1Adjusted <
            uint256(reserve0_) * uint256(reserve1_) * (1000 ** 2)
        ) revert InvalidK();

        /// 更新储备和价格累积值
        _update(balance0, balance1, reserve0_, reserve1_);

        /// 发出事件
        emit Swap(msg.sender, amount0Out, amount1Out, to);
    }

    ///  同步储备量
    ///  @dev 当合约余额与储备不匹配时调用此函数来修正
    function sync() public {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0_,
            reserve1_
        );
    }

    ///  获取当前储备和最后更新时间
    ///  @return reserve0 token0的储备量
    ///  @return reserve1 token1的储备量
    ///  @return blockTimestampLast 最后更新的时间戳
    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    ///
    ///  PRIVATE FUNCTIONS
    ///

    ///  更新储备和价格累积值
    ///  @dev 在mint、burn、swap后调用，维护储备和TWAP预言机数据
    ///  @param balance0 token0的新余额
    ///  @param balance1 token1的新余额
    ///  @param reserve0_ token0的旧储备
    ///  @param reserve1_ token1的旧储备
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 reserve0_,
        uint112 reserve1_
    ) private {
        /// 校验：余额不能超过uint112最大值
        if (balance0 > type(uint112).max || balance1 > type(uint112).max)
            revert BalanceOverflow();

        unchecked {
            /// 计算距离上次更新的时间差（单位：秒）
            uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast;

            /// 更新价格累积值（TWAP预言机）
            if (timeElapsed > 0 && reserve0_ > 0 && reserve1_ > 0) {
                /// 价格0累积值 += (reserve1 / reserve0) * 时间差
                price0CumulativeLast +=
                    uint256(UQ112x112.encode(reserve1_).uqdiv(reserve0_)) *
                    timeElapsed;
                /// 价格1累积值 += (reserve0 / reserve1) * 时间差
                price1CumulativeLast +=
                    uint256(UQ112x112.encode(reserve0_).uqdiv(reserve1_)) *
                    timeElapsed;
            }
        }

        /// 更新储备
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        /// 更新时间戳
        blockTimestampLast = uint32(block.timestamp);

        /// 发出同步事件
        emit Sync(reserve0, reserve1);
    }

    ///  安全的代币转账（处理不规范的ERC20）
    ///  @dev 使用低级call避免某些代币不返回值或返回false的问题
    ///  @param token 代币合约地址
    ///  @param to 接收者地址
    ///  @param value 转账金额
    function _safeTransfer(address token, address to, uint256 value) private {
        /// 使用低级call调用transfer函数
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, value)
        );
        /// 验证转账成功
        if (!success || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }
}
