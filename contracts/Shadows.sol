// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "./interfaces/ISynthesizer.sol";

contract Shadows is
    Initializable,
    OwnableUpgradeable,
    ERC20PausableUpgradeable
{
    // Maximum Total Supply 100 M
    uint256 constant maxTotalSupply = 1e8 ether;

    ISynthesizer public synthesizer;

    function initialize() external initializer {
        __Ownable_init();
        __ERC20_init("Shadows", "DOWS");
        __ERC20Pausable_init();
        _mint(_msgSender(), 37000000 ether);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        if (address(synthesizer) != address(0)) {
            require(
                amount <= synthesizer.transferableShadows(sender),
                "Cannot transfer staked DOWS"
            );
        }
        return super._transfer(sender, recipient, amount);
    }

    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    function _mint(address account, uint256 amount) internal override {
        uint256 totalSupply = super.totalSupply();
        require(
            maxTotalSupply >= totalSupply.add(amount),
            "Max total supply over"
        );

        super._mint(account, amount);
    }
}
