// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20TwoPhase } from "../extensions/ERC20TwoPhase.sol";

/// @title TwoPhaseToken — concrete mintable ERC-20 with the two-phase extension.
/// @dev Test/demo mock only. Public `mint` is intentionally unrestricted.
contract TwoPhaseToken is ERC20TwoPhase {
    constructor() ERC20("TwoPhase", "2P") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
