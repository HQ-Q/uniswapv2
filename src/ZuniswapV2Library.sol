// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

// 工厂合约接口
import "./interfaces/IZuniswapV2Factory.sol";
// 交易对合约接口
import "./interfaces/IZuniswapV2Pair.sol";
// 交易对合约（用于获取字节码）
import {ZuniswapV2Pair} from "./ZuniswapV2Pair.sol";

/// @title ZuniswapV2Library
/// @notice Uniswap V2 库合约
/// @dev 提供交易对地址计算、价格计算、金额转换等工具函数
library ZuniswapV2Library {
    /// @notice 输入金额为零
    error InsufficientAmount();
    /// @notice 储备量为零
    error InsufficientLiquidity();
    /// @notice 交换路径无效
    error InvalidPath();

    /// @notice 获取交易对的储备量
    /// @dev 根据两个代币获取对应的交易对，然后获取其储备
    /// @param factoryAddress 工厂合约地址
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @return reserveA tokenA对应的储备
    /// @return reserveB tokenB对应的储备
    function getReserves(
        address factoryAddress,
        address tokenA,
        address tokenB
    ) public returns (uint256 reserveA, uint256 reserveB) {
        // 排序代币地址，得到token0和token1
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        
        // 获取交易对的两个储备
        (uint256 reserve0, uint256 reserve1, ) = IZuniswapV2Pair(
            pairFor(factoryAddress, token0, token1)
        ).getReserves();
        
        // 根据输入的代币顺序返回储备
        // 如果tokenA == token0，则reserveA = reserve0
        // 否则reserveA = reserve1
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    /// @notice 根据输入金额计算输出金额（基础定价公式）
    /// @dev 不考虑手续费的基础公式：amountOut = amountIn * reserveOut / reserveIn
    /// @param amountIn 输入金额
    /// @param reserveIn 输入代币的储备
    /// @param reserveOut 输出代币的储备
    /// @return amountOut 输出金额
    function quote(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        // 验证输入金额 > 0
        if (amountIn == 0) revert InsufficientAmount();
        // 验证两个储备都 > 0
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // 基础定价公式（恒定乘积：x*y=k）
        // 假设交换前后K值不变
        return (amountIn * reserveOut) / reserveIn;
    }

    /// @notice 排序两个代币地址
    /// @dev 按地址大小排序，确保token0 < token1
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @return token0 较小地址
    /// @return token1 较大地址
    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        // 根据地址大小返回排序后的结果
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice 计算交易对地址（不需要调用工厂合约）
    /// @dev 使用CREATE2公式链下计算地址，用于验证和预测
    /// @param factoryAddress 工厂合约地址*-
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @return pairAddress 交易对合约地址
    function pairFor(
        address factoryAddress,
        address tokenA, 
        address tokenB
    ) internal pure returns (address pairAddress) {
        // 排序代币地址
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        
        // 使用CREATE2地址计算公式：
        // address = keccak256(0xff + factoryAddress + salt + bytecodeHash) 的最后20字节
        // 其中：
        // - 0xff：CREATE2的标志字节
        // - factoryAddress：创建合约的工厂地址
        // - salt = keccak256(token0, token1)
        // - bytecodeHash = keccak256(ZuniswapV2Pair的创建字节码)
        pairAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",                                           // CREATE2标志
                            factoryAddress,                                   // 工厂地址
                            keccak256(abi.encodePacked(token0, token1)),     // Salt
                            keccak256(type(ZuniswapV2Pair).creationCode)     // 字节码哈希
                        )
                    )
                )
            )
        );
    }

    /// @notice 根据输入金额计算输出金额（考虑手续费）
    /// @dev 使用带手续费的恒定乘积公式：(x + Δx*0.997) * (y - Δy) = x*y
    /// @param amountIn 输入金额
    /// @param reserveIn 输入代币的储备
    /// @param reserveOut 输出代币的储备
    /// @return 输出金额
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256) {
        // 验证输入金额 > 0
        if (amountIn == 0) revert InsufficientAmount();
        // 验证两个储备都 > 0
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // 计算带手续费的输入金额
        // 手续费为0.3%，所以实际使用的金额 = 输入 * (1 - 0.003) = 输入 * 0.997
        uint256 amountInWithFee = amountIn * 997;
        
        // 分子：(输入 * 0.997) * 输出储备
        uint256 numerator = amountInWithFee * reserveOut;
        
        // 分母：(输入储备 * 1000) + (输入 * 0.997)
        // 乘以1000是为了与分子保持精度一致
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        // 输出 = numerator / denominator
        return numerator / denominator;
    }

    /// @notice 根据路径和输入金额计算每一步的输出金额
    /// @dev 遍历交换路径，逐步计算输出金额
    /// @param factory 工厂合约地址
    /// @param amountIn 初始输入金额
    /// @param path 交换路径数组，例如 [tokenA, tokenB, tokenC] 表示 A->B->C
    /// @return 返回数组，amounts[i]表示第i步的金额
    function getAmountsOut(
        address factory,
        uint256 amountIn,
        address[] memory path
    ) public returns (uint256[] memory) {
        // 验证路径有效性（至少需要2个代币）
        if (path.length < 2) revert InvalidPath();
        
        // 创建输出数组，长度等于路径长度
        uint256[] memory amounts = new uint256[](path.length);
        // 第一个元素是输入金额
        amounts[0] = amountIn;

        // 循环遍历路径中的每一步交换
        for (uint256 i; i < path.length - 1; i++) {
            // 获取当前交换对（path[i] -> path[i+1]）的储备
            (uint256 reserve0, uint256 reserve1) = getReserves(
                factory,
                path[i],
                path[i + 1]
            );
            // 计算这一步的输出金额
            amounts[i + 1] = getAmountOut(amounts[i], reserve0, reserve1);
        }

        // 返回完整的金额数组
        return amounts;
    }

    /// @notice 根据输出金额计算输入金额（反向计算）
    /// @dev 反向使用恒定乘积公式，用于获得目标输出需要多少输入
    /// @param amountOut 目标输出金额
    /// @param reserveIn 输入代币的储备
    /// @param reserveOut 输出代币的储备
    /// @return 需要的输入金额
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256) {
        // 验证输出金额 > 0
        if (amountOut == 0) revert InsufficientAmount();
        // 验证两个储备都 > 0
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // 反向计算公式：根据 (x + Δx*0.997) * (y - Δy) = x*y
        // 推导出：Δx = (x * Δy * 1000) / ((y - Δy) * 997)
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;

        // +1 是为了避免舍入误差（向上取整）
        return (numerator / denominator) + 1;
    }

    /// @notice 根据路径和目标输出金额计算所需的输入金额
    /// @dev 从路径末端向前反向计算，逐步推算所需输入
    /// @param factory 工厂合约地址
    /// @param amountOut 目标输出金额（最终产出）
    /// @param path 交换路径数组，例如 [tokenA, tokenB, tokenC] 表示 A->B->C
    /// @return 返回数组，amounts[i]表示第i步所需的输入金额
    function getAmountsIn(
        address factory,
        uint256 amountOut,
        address[] memory path
    ) public returns (uint256[] memory) {
        // 验证路径有效性（至少需要2个代币）
        if (path.length < 2) revert InvalidPath();
        
        // 创建输出数组，长度等于路径长度
        uint256[] memory amounts = new uint256[](path.length);
        // 最后一个元素是目标输出金额
        amounts[amounts.length - 1] = amountOut;

        // 从路径末端向前循环遍历，反向计算每一步的输入金额
        for (uint256 i = path.length - 1; i > 0; i--) {
            // 获取当前交换对（path[i-1] -> path[i]）的储备
            (uint256 reserve0, uint256 reserve1) = getReserves(
                factory,
                path[i - 1],
                path[i]
            );
            // 根据这一步的输出金额，反向计算所需的输入金额
            amounts[i - 1] = getAmountIn(amounts[i], reserve0, reserve1);
        }

        // 返回完整的输入金额数组
        return amounts;
    }
}