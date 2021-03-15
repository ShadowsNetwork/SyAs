// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;

import "./AddressResolver.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract AddressResolverUpgradeable is Initializable, ContextUpgradeable {
    AddressResolver public resolver;

    function __AddressResolver_init(address _resolver) internal initializer {
        __Context_init_unchained();
        __AddressResolver_init_unchained(_resolver);
    }

    function __AddressResolver_init_unchained(address _resolver)
        internal
        initializer
    {
        resolver = AddressResolver(_resolver);
    }

    function setResolver(AddressResolver _resolver) public onlyOwner {
        resolver = _resolver;
    }
}