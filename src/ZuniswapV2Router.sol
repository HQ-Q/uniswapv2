/// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "./interfaces/IZuniswapV2Factory.sol";
import "./interfaces/IZuniswapV2Pair.sol";
import "./ZuniswapV2Library.sol";

///  @title ZuniswapV2Router
///  @notice 路由器合约，提供便捷的流动性管理和代币交换接口
///  @dev 用户通过此合约与交易对交互，而非直接与交易对交互
contract ZuniswapV2Router {
    ///  @dev 输入代币过多
    error ExcessiveInputAmount();
    ///  @dev TokenA数量不足
    error InsufficientAAmount();
    ///  @dev TokenB数量不足
    error InsufficientBAmount();
    ///  @dev 输出代币数量不足
    error InsufficientOutputAmount();
    ///  @dev 安全转账失败
    error SafeTransferFailed();

    ///  @notice Uniswap V2 工厂合约实例
    IZuniswapV2Factory factory;

    ///  @notice 初始化路由器
    ///  @param factoryAddress 工厂合约地址
    constructor(address factoryAddress) {
        factory = IZuniswapV2Factory(factoryAddress);
    }

    ///  @notice 添加流动性
    ///  @param tokenA 第一个代币地址
    ///  @param tokenB 第二个代币地址
    ///  @param amountADesired 期望的tokenA数量
    ///  @param amountBDesired 期望的tokenB数量 
    ///  @param amountAMin tokenA最低接受数量（滑点保护）
    ///  @param amountBMin tokenB最低接受数量（滑点保护）
    ///  @param to 接收LP代币的地址
    ///  @return amountA 实际添加的tokenA数量
    ///  @return amountB 实际添加的tokenB数量
    ///  @return liquidity 获得的LP代币数量
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    )
        public
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        /// 如果交易对不存在，先创建交易对
        if (factory.pairs(tokenA, tokenB) == address(0)) {
            factory.createPair(tokenA, tokenB);
        }

        /// 计算最优的流动性数量（避免代币比例不匹配）
        (amountA, amountB) = _calculateLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        
        /// 获取交易对地址
        address pairAddress = ZuniswapV2Library.pairFor(
            address(factory),
            tokenA,
            tokenB
        );
        
        /// 将代币转入交易对
        _safeTransferFrom(tokenA, msg.sender, pairAddress, amountA);
        _safeTransferFrom(tokenB, msg.sender, pairAddress, amountB);
        
        /// 调用交易对的mint函数，获得LP代币
        liquidity = IZuniswapV2Pair(pairAddress).mint(to);
    }

    ///  @notice 移除流动性
    ///  @param tokenA 第一个代币地址
    ///  @param tokenB 第二个代币地址
    ///  @param liquidity 要销毁的LP代币数量
    ///  @param amountAMin tokenA最低接受数量（滑点保护）
    ///  @param amountBMin tokenB最低接受数量（滑点保护）
    ///  @param to 接收代币的地址
    ///  @return amountA 返回的tokenA数量
    ///  @return amountB 返回的tokenB数量
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) public returns (uint256 amountA, uint256 amountB) {
        /// 获取交易对地址
        address pair = ZuniswapV2Library.pairFor(
            address(factory),
            tokenA,
            tokenB
        );
        
        /// 将LP代币转入交易对（为burn做准备）
        IZuniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        
        /// 调用burn销毁LP代币，返回两种代币
        (amountA, amountB) = IZuniswapV2Pair(pair).burn(to);
        
        /// 验证返回的代币数量满足最低要求（防止滑点过大）
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountA < amountBMin) revert InsufficientBAmount();
    }

    ///  @notice 精确输入代币数量进行交换
    ///  @dev 用户指定要输入多少代币，输出数量由市场价格决定
    ///  @param amountIn 输入代币的精确数量
    ///  @param amountOutMin 输出代币的最低接受数量（滑点保护）
    ///  @param path 交换路径，例如 [tokenA, tokenB, tokenC] 表示 A->B->C
    ///  @param to 接收输出代币的地址
    ///  @return amounts 各阶段的输入/输出数量数组
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) public returns (uint256[] memory amounts) {
        /// 根据路径计算每一步的输出数量
        amounts = ZuniswapV2Library.getAmountsOut(
            address(factory),
            amountIn,
            path
        );
        
        /// 验证最终输出不低于期望的最小值
        if (amounts[amounts.length - 1] < amountOutMin)
            revert InsufficientOutputAmount();
        
        /// 将初始代币转入第一个交易对
        _safeTransferFrom(
            path[0],
            msg.sender,
            ZuniswapV2Library.pairFor(address(factory), path[0], path[1]),
            amounts[0]
        );
        
        /// 执行交换
        _swap(amounts, path, to);
    }

    ///  @notice 精确输出代币数量进行交换
    ///  @dev 用户指定要接收多少代币，输入数量由市场价格决定
    ///  @param amountOut 输出代币的精确数量
    ///  @param amountInMax 输入代币的最大接受数量（滑点保护）
    ///  @param path 交换路径，例如 [tokenA, tokenB, tokenC] 表示 A->B->C
    ///  @param to 接收输出代币的地址
    ///  @return amounts 各阶段的输入/输出数量数组
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) public returns (uint256[] memory amounts) {
        /// 根据路径和输出金额反向计算所需的输入数量
        amounts = ZuniswapV2Library.getAmountsIn(
            address(factory),
            amountOut,
            path
        );
        
        /// 验证所需输入不超过用户指定的最大值
        if (amounts[amounts.length - 1] > amountInMax)
            revert ExcessiveInputAmount();
        
        /// 将初始代币转入第一个交易对
        _safeTransferFrom(
            path[0],
            msg.sender,
            ZuniswapV2Library.pairFor(address(factory), path[0], path[1]),
            amounts[0]
        );
        
        /// 执行交换
        _swap(amounts, path, to);
    }

    ///
    ///
    ///
    ///  PRIVATE FUNCTIONS
    ///
    ///
    ///

    ///  @notice 执行交换操作
    ///  @dev 内部函数，循环通过路径中的所有交易对进行交换
    ///  @param amounts 各阶段的数量数组
    ///  @param path 交换路径数组
    ///  @param to_ 最终接收代币的地址
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address to_
    ) internal {
        /// 循环遍历路径中的每一步
        for (uint256 i; i < path.length - 1; i++) {
            /// 当前交换的输入和输出代币
            (address input, address output) = (path[i], path[i + 1]);
            
            /// 排序两个代币地址，获得token0
            (address token0, ) = ZuniswapV2Library.sortTokens(input, output);
            
            /// 当前步骤的输出数量
            uint256 amountOut = amounts[i + 1];
            
            /// 根据input是否为token0，决定amount0Out和amount1Out
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            
            /// 确定输出代币的接收地址：
            /// - 如果不是最后一步，输出到下一个交易对
            /// - 如果是最后一步，输出到最终接收者
            address to = i < path.length - 2
                ? ZuniswapV2Library.pairFor(
                    address(factory),
                    output,
                    path[i + 2]
                )
                : to_;
            
            /// 调用交易对的swap函数
            IZuniswapV2Pair(
                ZuniswapV2Library.pairFor(address(factory), input, output)
            ).swap(amount0Out, amount1Out, to, "");
        }
    }

    ///  @notice 计算最优流动性金额
    ///  @dev 根据已有的储备比例调整用户的输入，确保代币不过量浪费
    ///  @param tokenA 第一个代币
    ///  @param tokenB 第二个代币
    ///  @param amountADesired 期望的tokenA数量
    ///  @param amountBDesired 期望的tokenB数量
    ///  @param amountAMin tokenA最低接受数量
    ///  @param amountBMin tokenB最低接受数量
    ///  @return amountA 实际使用的tokenA数量
    ///  @return amountB 实际使用的tokenB数量
    function _calculateLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        /// 获取交易对的当前储备
        (uint256 reserveA, uint256 reserveB) = ZuniswapV2Library.getReserves(
            address(factory),
            tokenA,
            tokenB
        );

        /// 如果这是第一次添加流动性（没有储备），接受用户的全部输入
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            /// 根据当前的A:B比例，计算最优的B数量
            uint256 amountBOptimal = ZuniswapV2Library.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            
            /// 如果最优B数量 <= 用户期望的B数量
            if (amountBOptimal <= amountBDesired) {
                /// 检查最优值是否满足最低要求
                if (amountBOptimal <= amountBMin) revert InsufficientBAmount();
                /// 使用全部amountADesired和最优的amountBOptimal
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                /// 反向计算：根据amountBDesired，计算需要多少A
                uint256 amountAOptimal = ZuniswapV2Library.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);

                /// 检查最优A值是否满足最低要求
                if (amountAOptimal <= amountAMin) revert InsufficientAAmount();
                /// 使用最优的amountAOptimal和全部amountBDesired
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    ///  @notice 安全的代币转账
    ///  @dev 使用低级call执行transferFrom，处理不规范的ERC20代币
    ///  @param token 代币合约地址
    ///  @param from 从哪个地址转出
    ///  @param to 转入到哪个地址
    ///  @param value 转账金额
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) private {
        /// 使用低级call调用transferFrom
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                from,
                to,
                value
            )
        );
        /// 检查：调用成功且返回值为true，否则抛出错误
        if (!success || (data.length != 0 && !abi.decode(data, (bool))))
            revert SafeTransferFailed();
    }
}