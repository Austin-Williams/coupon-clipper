pragma solidity 0.7.6;
// SPDX-License-Identifier: MIT

// On mainnet at: 0xaBe194DE48045DC40fbc767F66ccBceB6D022030

/**
Copyright (c) 2020 Austin Williams
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
**/

interface IESDS {
    function redeemCoupons(uint256 _epoch, uint256 _couponAmount) external;
    function transferCoupons(address _sender, address _recipient, uint256 _epoch, uint256 _amount) external;
    function balanceOfCouponUnderlying(address _account, uint256 _epoch) external view returns (uint256);
    function epoch() external view returns (uint256);
    function advance() external;
}

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// @notice Lets anybody trustlessly redeem coupons on anyone else's behalf for a fee.
//    Requires that the coupon holder has previously approved this contract via the ESDS `approveCoupons` function.
// @dev Bots should scan for the `SetOffer` event emitted by the this contract to find out which 
//    users have made offers. They should be sure to verify that the users have "approved" this contract.
// @dev This contract's API should be backwards compatible with CouponClipper V1 and V2.
contract CouponClipperV3 {
    using SafeMath for uint256;

    IERC20 constant private ESD = IERC20(0x36F3FD68E7325a35EB768F1AedaAe9EA0689d723);
    IESDS constant private ESDS = IESDS(0x443D2f2755DB5942601fa062Cc248aAA153313D3);
    
    uint256 constant public MAX_HOUSE_RATE_BPS = 1500; // 15% Max house take from bot proceeds
    
    address public house; // collector of house fee
    uint256 public houseRate; // Defaults to 1000 bps (10%) of proceeds. Can be changed via the `changeHouseRate` function.
    
    event SetOffer(address indexed user, uint256 offer);
    event SetHouseRate(uint256 fee);
    
    // The basis points offered by coupon holders to have their coupons redeemed -- default is 0 bps (0%).
    // E.g., offers[_user] = 500 indicates that _user will pay 500 basis points (5%) to have their coupons redeemed for them.
    mapping(address => uint256) private offers;
    
    constructor() {
        house = 0x7Fb471734271b732FbEEd4B6073F401983a406e1;
        houseRate = 1000; // Defaults to 1000 bps (10%) of proceeds.
    }

    // @notice Gets the number of basis points the _user is offering the bots.
    // @param _user The account whose offer we're looking up.
    // @return The number of basis points the account is offering to have their coupons redeemed.
    function getOffer(address _user) public view returns (uint256) {
        return offers[_user];
    }

    // @notice Allows msg.sender to change the number of basis points they are offering.
    // @dev A user's offer cannot be *decreased* during the 15 minutes before the epoch advance (frontrun protection)
    // @param _newOffer The number of basis points msg.sender wants to offer to have their coupons redeemed.
    function setOffer(uint256 _newOffer) external {
        require(_newOffer <= 10_000, "Offer exceeds 100%.");
        uint256 oldOffer = offers[msg.sender];
        if (_newOffer < oldOffer) {
            uint256 nextEpoch = ESDS.epoch() + 1;
            uint256 nextEpochStartTime = getEpochStartTime(nextEpoch);
            uint256 timeUntilNextEpoch = nextEpochStartTime.sub(block.timestamp);
            require(timeUntilNextEpoch > 15 minutes, "You cannot reduce your offer within 15 minutes of the next epoch");
        }
        
        offers[msg.sender] = _newOffer;
        
        emit SetOffer(msg.sender, _newOffer);
    }

    // @notice Internal logic used to redeem coupons on the coupon holder's bahalf
    // @param _user Address of the user holding the coupons (and who has approved this contract)
    // @param _epoch The epoch in which the _user purchased the coupons
    // @param _amount The number of coupons to redeem (18 decimals), typically balanceOfCouponUnderlying
    function _redeem(address _user, uint256 _epoch, uint256 _amount) internal {
        
        // pull user's coupons into this contract (requires that the user has approved this contract)
        ESDS.transferCoupons(_user, address(this), _epoch, _amount); // @audit-info : reverts on failure
        
        // redeem the coupons for ESD
        uint256 balanceOfCouponUnderlying = ESDS.balanceOfCouponUnderlying(address(this), _epoch); // @audit-info handles unexpected underlying balance
        ESDS.redeemCoupons(_epoch, balanceOfCouponUnderlying); // @audit-info : reverts on failure
        
        // pay the fees
        uint256 esdRevenue = ESD.balanceOf(address(this));
        uint256 totalFeeRate = getOffer(_user);
        uint256 totalFee = esdRevenue.mul(totalFeeRate).div(10_000);
        uint256 houseFee = totalFee.mul(houseRate).div(10_000);
        uint256 botFee = totalFee.sub(houseFee);
        ESD.transfer(house, houseFee); // @audit-info : reverts on failure
        ESD.transfer(msg.sender, botFee); // @audit-info : reverts on failure
        
        // send the ESD to the user
        ESD.transfer(_user, esdRevenue.sub(totalFee)); // @audit-info : reverts on failure
    }
    
    // @notice Allows anyone to redeem coupons for ESD on the coupon-holder's bahalf
    // @dev Backwards compatible with CouponClipper V1 and V2.
    function redeem(address _user, uint256 _epoch, uint256 _amount) external {
        _redeem(_user, _epoch, _amount);
    }
    
    // @notice Returns the timestamp at which the _targetEpoch starts
    function getEpochStartTime(uint256 _targetEpoch) public pure returns (uint256) {
        return _targetEpoch.sub(106).mul(28800).add(1602201600);
    }
    
    // @notice Allows house address to change the house address
    function changeHouseAddress(address _newAddress) external {
        require(msg.sender == house);
        house = _newAddress;
    }
    
    // @notice Allows house address to change the house rate
    // @dev House rate can never be larger than MAX_HOUSE_RATE_BPS
    // @dev House rate cannot *increase* fewer than 15 minutes before the next epoch (frontrun protection)
    function changeHouseRate(uint256 _newHouseRate) external {
        require(msg.sender == house, "only house can update fee");
        require(_newHouseRate <= MAX_HOUSE_RATE_BPS, "fee too high");
        if (_newHouseRate > houseRate) {
            uint256 nextEpoch = ESDS.epoch() + 1;
            uint256 nextEpochStartTime = getEpochStartTime(nextEpoch);
            uint256 timeUntilNextEpoch = nextEpochStartTime.sub(block.timestamp);
            require(timeUntilNextEpoch > 15 minutes, "Cannot increase house rate within 15 minutes of the next epoch");
        }
        houseRate = _newHouseRate;
        emit SetHouseRate(_newHouseRate);
    }
}



library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts with custom message when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}