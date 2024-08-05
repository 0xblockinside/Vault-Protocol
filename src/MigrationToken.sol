// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {IPermitERC20} from "shared/interfaces/IERC20Extended.sol";
import {Permit} from "shared/structs/Permit.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

contract Token is ERC20 {
    address immutable OLD_TOKEN;
    string NAME;
    string SYMBOL;

    function name() public view override returns (string memory) { return NAME; }
    function symbol() public view override returns (string memory) { return SYMBOL; }

    constructor(address token) {
        OLD_TOKEN = token;
        IPermitERC20 t = IPermitERC20(token);
        NAME = t.name();
        SYMBOL = t.symbol();

        _mint(msg.sender, t.totalSupply());
    }

   /**
     * @notice Upgrades users token by burning old token and sending them equivalent amount
     * @dev Never transfer ERC20 tokens directly to this contract only native ETH.
     * @param permit A struct containing the permit details for old token
     * @param amount The amount to burn from msg.sender 
     */
    function migrate(Permit calldata permit, uint256 amount) external {
        IPermitERC20 oldToken = IPermitERC20(OLD_TOKEN);
        uint256 curAmount = oldToken.balanceOf(address(this));
        if (amount > 0) {
            if (permit.enable) oldToken.permit(msg.sender, address(this), amount, permit.deadline, permit.v, permit.r, permit.s);
            SafeTransferLib.safeTransferFrom(address(oldToken), msg.sender, address(0), amount);
        }
        _transfer(address(this), msg.sender, curAmount + amount);

        SafeTransferLib.safeTransfer(address(oldToken), address(0), curAmount);
    }
}
