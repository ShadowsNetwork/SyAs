// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "./library/AddressResolverUpgradeable.sol";
import "./interfaces/IFeePool.sol";
import "./interfaces/IShadows.sol";
import "./interfaces/IExchanger.sol";

contract Synth is Initializable, OwnableUpgradeable, ERC20Upgradeable, AddressResolverUpgradeable {

    bytes32 public currencyKey;

    uint8 public constant DECIMALS = 18;

    function initialize(
        string calldata _tokenName,
        string calldata _tokenSymbol,
        bytes32 _currencyKey,
        address _resolver
    ) external initializer {
        __Ownable_init();
        __ERC20_init(_tokenName, _tokenSymbol);
        __AddressResolver_init(_resolver);
        currencyKey = _currencyKey;
    }

    function transferableSynths(address account) public view returns (uint) {
        return balanceOf(account);
    }

    function issue(address account, uint amount) external onlyInternalContracts {
        _mint(account, amount);
        emit Issued(account, amount);
    }

    function burn(address account, uint amount) external onlyInternalContracts {
        _burn(account, amount);
        emit Burned(account, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        if (recipient == feePool().FEE_ADDRESS()) {
            return _transferToFeeAddress(sender, amount);
        }

        if (recipient == address(0)) {
            return _burn(_msgSender(), amount);
        }
        return super._transfer(sender,recipient,amount);
    }

    /**
     * non-xUSD synths are exchanged into xUSD via synthInitiatedExchange
     * notify feePool to record amount as fee paid to feePool 
    */
    function _transferToFeeAddress(address recipient, uint amount) internal{
        uint amountInUSD;

        if (currencyKey == "xUSD") {
            amountInUSD = amount;
            super._transfer(_msgSender(), recipient, amount);
        } else {
            amountInUSD = exchanger().exchange(_msgSender(), currencyKey, amount, "xUSD", feePool().FEE_ADDRESS());
        }

        feePool().recordFeePaid(amountInUSD);

        return;
    }

    function shadows() internal view returns (IShadows) {
        return IShadows(resolver.requireAndGetAddress("Shadows", "Missing Shadows address"));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(resolver.requireAndGetAddress("FeePool", "Missing FeePool address"));
    }

    function exchanger() internal view returns (IExchanger) {
        return IExchanger(resolver.requireAndGetAddress("Exchanger", "Missing Exchanger address"));
    }

    modifier onlyInternalContracts() {
        bool isShadows = msg.sender == address(shadows());
        bool isFeePool = msg.sender == address(feePool());
        bool isExchanger = msg.sender == address(exchanger());

        require(
            isShadows || isFeePool || isExchanger,
            "Only Shadows, FeePool, Exchanger or Issuer contracts allowed"
        );
        _;
    }

    event Issued(address indexed account, uint value);

    event Burned(address indexed account, uint value);
}