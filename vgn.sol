// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @custom:security-contact security@valiants.io
contract VGN is ERC20 {
  constructor() ERC20("Vortrius Game Network", "VGN") {
    _mint(msg.sender, 20_000_000e18);
  }
}
