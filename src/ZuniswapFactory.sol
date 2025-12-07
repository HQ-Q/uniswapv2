// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

// 交易对合约
import "./ZuniswapV2Pair.sol";
// 交易对接口
import "./interfaces/IZuniswapV2Pair.sol";

/// @title ZuniswapV2Factory
/// @notice Uniswap V2 工厂合约
/// @dev 负责创建交易对，管理所有交易对的地址映射
contract ZuniswapV2Factory {
    /// @notice 两个代币地址相同
    error IdenticalAddresses();
    /// @notice 交易对已存在
    error PairExists();
    /// @notice 代币地址为零地址
    error ZeroAddress();

    /// @notice 交易对创建事件
    /// @param token0 第一个代币地址（较小地址）
    /// @param token1 第二个代币地址（较大地址）
    /// @param pair 新创建的交易对地址
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    /// @notice 交易对地址映射表
    /// @dev 支持双向查询：pairs[token0][token1] = pairs[token1][token0]
    mapping(address => mapping(address => address)) public pairs;
    
    /// @notice 所有交易对地址数组
    /// @dev 按创建顺序存储，便于历史查询
    address[] public allPairs;

    /// @notice 创建交易对
    /// @dev 使用CREATE2确定性部署，支持预测交易对地址
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @return pair 新创建的交易对地址
    function createPair(address tokenA, address tokenB)
        public
        returns (address pair)
    {
        // 检查：两个代币地址不能相同
        if (tokenA == tokenB) revert IdenticalAddresses();

        // 排序代币地址，确保token0 < token1
        // 目的：规范化存储，同一交易对只有一个记录
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        // 检查：token0不能为零地址
        if (token0 == address(0)) revert ZeroAddress();

        // 检查：交易对是否已存在
        if (pairs[token0][token1] != address(0)) revert PairExists();

        // 获取ZuniswapV2Pair合约的创建字节码
        bytes memory bytecode = type(ZuniswapV2Pair).creationCode;
        
        // 计算Salt值：对两个代币地址进行Keccak256哈希
        // Salt的作用：使合约部署地址确定性（可预测）
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        
        // 使用CREATE2操作码部署合约（确定性部署）
        // - 0：发送给新合约的以太币数量
        // - add(bytecode, 32)：字节码起始位置（跳过长度前缀）
        // - mload(bytecode)：字节码长度
        // - salt：确定性部署的盐值
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // 初始化新部署的交易对合约
        IZuniswapV2Pair(pair).initialize(token0, token1);

        // 存储交易对地址到映射表（双向存储）
        pairs[token0][token1] = pair;
        pairs[token1][token0] = pair;
        
        // 添加到交易对列表
        allPairs.push(pair);

        // 发出事件，通知链下应用有新交易对创建
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}