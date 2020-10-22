pragma solidity ^0.7.4;
// SPDX-License-Identifier: MIT

interface IESDS {
    function redeemCoupons(uint256 epoch, uint256 couponAmount) external;
    function transferCoupons(address sender, address recipient, uint256 epoch, uint256 amount) external;
}

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

// @notice Lets anybody trustlessly redeem coupons on anyone else's behalf for a 1% fee.
//    Requires that the coupon holder has previously approved this contract via the ESDS `approveCoupons` function.
//    This will likely be dominated by bots. That is the point: to let bots trustlessly redeem coupons for non-bot users
//    in exchange for a 1% fee.
//    The user holds on to their coupons until the moment they are redeemed.
//    The user can redeem their own coupons, just like normal (without any fees), even if they've approved this contract.
//    When the user's coupons are redeemed, the ESD is sent directly to the user's account.
//    NOTE: There is no garuantee that all coupons will be redeemed. If the 1% fee is not enough to cover gas costs or 
//    otherwise incentivize someone to call `redeem`, then the coupons will not be redeemed this way.
//    WARNING: DO NOT SEND YOUR COUPONS TO THIS CONTRACT! THEY WILL BE LOST FOREVER!
//    You only need to APPROVE this contract to move your coupons.
// @dev Bots should scan for the `CouponApproval` event emitted by the ESDS `approveCoupons` function to find out which 
//    users have approved this contract to redeem their coupons.
contract CouponClipper {

    IERC20 constant private ESD = IERC20(0x36F3FD68E7325a35EB768F1AedaAe9EA0689d723);
    IESDS constant private ESDS = IESDS(0x443D2f2755DB5942601fa062Cc248aAA153313D3);

    // @notice Allows anyone to redeem coupons for ESD on the coupon-holder's bahalf
    // @param _user Address of the user holding the coupons (and who has approved this contract)
    // @param _epoch The epoch in which the _user purchased the coupons
    // @param _couponAmount The number of coupons to redeem (18 decimals)
    function redeem(address _user, uint256 _epoch, uint256 _couponAmount) external {
        
        // pull user's coupons into this contract (requires that the user has approved this contract)
        ESDS.transferCoupons(_user, address(this), _epoch, _couponAmount);
        
        // redeem the coupons for ESD
        ESDS.redeemCoupons(_epoch, _couponAmount);
        
        // pay the caller 1% of the amount redeemed
        uint256 botFee = _couponAmount / 100;
        ESD.transfer(msg.sender, botFee); // @audit-ok : reverts on failure
        
        // send the ESD to the user
        ESD.transfer(_user, _couponAmount - botFee); // @audit-ok : no underflow and reverts on failure
    }
}
