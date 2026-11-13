// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title CovToken
 * @notice $COV utility token for the Covenant Protocol.
 * @dev The entire supply is minted once in the constructor and there is no mint
 * function afterwards, so the initial supply is a hard cap. Supply only goes
 * down, through `burn` / `burnFrom` (ERC20Burnable).
 */
contract CovToken is ERC20, ERC20Burnable {
    constructor(address initialHolder, uint256 initialSupply) ERC20("Covenant", "COV") {
        require(initialHolder != address(0), "Zero holder");
        require(initialSupply > 0, "Zero supply");
        _mint(initialHolder, initialSupply);
    }
}
