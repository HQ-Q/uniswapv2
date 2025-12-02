// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;
contract Simple {
   
   uint public x;

   function setX(uint _x) public {
       x = _x;
   }

   function getX() public view returns (uint) {
       return x;
   }

}
