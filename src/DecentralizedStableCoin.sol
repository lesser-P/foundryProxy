// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

/**
 * @title Decentralized Stable Coin
 * @author yeninghui
 * @notice 质押物（ETH&BTC）
 * 这是由 DscEngine 管辖的合同。该合约只是我们稳定币系统的 ERC20 实现。
 * This is the contract meant to be governed by DscEngine. This contract is just the ERC20 implementation of our stablecoin system.
 */

import {ERC20Burnable, ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin_MustBeMoreThanZero();
    error DecentralizedStableCoin_BurnAmountExceedsBalance();
    error DecentralizedStableCoin_NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable() {
        // TODO
    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin_MustBeMoreThanZero();
        }

        if (_amount > balance) {
            revert DecentralizedStableCoin_BurnAmountExceedsBalance();
        }

        super.burn(_amount);
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin_NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin_MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
