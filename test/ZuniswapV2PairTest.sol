// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;
import "../src/ZuniswapV2Pair.sol";
import "../src/solmate/tokens/ERC20.sol";
import "forge-std/Test.sol";

contract ERC20Mintable is ERC20 {
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol, 18) {}

    function mint(uint256 amount) public {
        _mint(msg.sender, amount);
    }
}

contract ZuniswapV2PairTest is Test {
    ZuniswapV2Pair pair;
    ERC20Mintable token0;
    ERC20Mintable token1;

    function setUp() public {
        pair = new ZuniswapV2Pair();
        token0 = new ERC20Mintable("TokenA", "TKA");
        token1 = new ERC20Mintable("TokenB", "TKB");
        pair.initialize(address(token0), address(token1));

        token0.mint(10 ether);
        token1.mint(10 ether);
    }

    function testMint() public {
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        assertEq(pair.mint(address(this)), 1 ether - 1000);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        assertEq(reserve0, 1 ether);
        assertEq(reserve1, 1 ether);

        // assertEq(pair.balanceOf(address(this)), 1 ether - 100);
    }

    function testMintWhenWheresLiquidity() public {
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        token0.transfer(address(pair), 2 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        assertEq(pair.balanceOf(address(this)), 2 ether - 1000);

        assertReserves(3 ether, 2 ether);
    }

    function assertReserves(uint112 reserves0, uint112 reserves1) internal {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        assertEq(reserve0, reserves0);
        assertEq(reserve1, reserves1);
    }

    function testBurn() public {
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));


        uint256 liquidtidy = pair.balanceOf(address(this));

        pair.transfer(address(pair), liquidtidy);
        pair.burn(address(this));

        assertEq(pair.balanceOf(address(this)), 0);

        assertReserves(1000,1000);

        assertEq(token0.balanceOf(address(this)), 10 ether - 1000);
        assertEq(token1.balanceOf(address(this)), 10 ether - 1000);
    }
}
