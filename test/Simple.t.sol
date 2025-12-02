// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "../src/Simple.sol";

contract SimpleTest is Test {
    Simple simple;

    function setUp() public {
        simple = new Simple();
    }

    function testSetAndGetX() public {
        uint testValue = 42;
        simple.setX(testValue);
        uint retrievedValue = simple.getX();
        assertEq(retrievedValue, testValue, "The retrieved value should match the set value");
    }

}