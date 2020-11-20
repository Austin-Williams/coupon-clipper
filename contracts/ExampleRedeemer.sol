pragma solidity 0.7.1;
// SPDX-License-Identifier: MIT

contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(isOwner(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Returns true if the caller is the current owner.
     */
    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * > Note: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     */
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

interface IESDS {
    function deposit(uint256) external;
    function balanceOfStaged(address) external view returns (uint256);
    function bond(uint256) external;
    function balanceOfBonded(address) external view returns (uint256);
    function unbondUnderlying(uint256) external;
    function withdraw(uint256) external; // "unstage"
    function advance() external;
    function epoch() external view returns (uint256);
    function epochTime() external view returns (uint256);
    function totalRedeemable() external view returns (uint256);
}

interface ICHI {
    function freeFromUpTo(address _addr, uint256 _amount) external returns (uint256);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICouponClipper {
    function getOffer(address _user) external view returns (uint256);
    function redeem(address _user, uint256 _epoch, uint256 _couponAmount) external;
}


// @notice Example code for use by bot runners
// @dev The `advanceAndRedeemMany` function allows you to attempt to redeem several sets of coupons
//    in a single tx.
//    It will call "advance" first, if needed.
//    It will do partial fills if/when totalRedeemable is less than the number of coupons you're trying to redeem.
//    It will continue execution if one attempt fails (using try/catch).
//    It will free gas tokens (assuming you have some in your account and have approved this contract to spend them).
// @dev You should test this code with low-value transactions first to make sure it behaves the way you think it does.
//    This is unaudited code, so please exercise prudence.
contract ExampleRedeemer is Ownable {
    
    using SafeMath for uint256;
    
    // external contracts and addresses
    address constant private esd = 0x36F3FD68E7325a35EB768F1AedaAe9EA0689d723;
    IESDS constant private esds = IESDS(0x443D2f2755DB5942601fa062Cc248aAA153313D3);
    ICHI  constant private chi = ICHI(0x0000000000004946c0e9F43F4Dee607b0eF1fA1c);
    ICouponClipper constant private couponClipper = ICouponClipper(0xb4027EEEa4b2D91616c63Dc3E37075E69f36b457);
    
    // frees CHI to reduce gas costs
    // requires that msg.sender has approved this contract to spend its CHI
    modifier useCHI {
        uint256 gasStart = gasleft();
        _;
        uint256 gasSpent = 21000 + gasStart - gasleft() + (16 * msg.data.length);
        chi.freeFromUpTo(msg.sender, (gasSpent + 14154) / 41947);
    }
    
    fallback() external payable {}
    receive() external payable {}
    
    constructor() {
        // approve ESDS contract to move ESD (needed to stage and bond)
        // (Not needed to redeem coupons but is nice to have if you want to use this contract as an ESD wallet)
        IERC20(esd).approve(address(esds), uint256(uint128(-1)));
    }
    
    // @notice Call this function with the bot. Use a high gas price.
    // @param _targetEpoch the future epoch we are trying to advance to.
    // @param _users Array of users whose copouns you're trying to redeem
    // @param _epochs Array of epochs at which the users' coupons were purchased
    // @param _couponAmounts The amounts of the users' coupons you're trying to redeem.
    // @dev Consider using a gas limit of `700_000 + (N * 300_000)`  where `N` is the length of the `_users` array.
    //    This may be overkill, but out-of-gas errors can really hurt, so best to avoid them.
    function advanceAndRedeemMany(uint16 _targetEpoch, address[] calldata _users, uint256[] calldata  _epochs, uint256[] calldata _couponAmounts) external useCHI onlyOwner {
        
        // Abort if this tx is mined too early (extreamly cheap)
        uint256 epochStartTime = getEpochStartTime(_targetEpoch);
        if (block.timestamp < epochStartTime) {
            // We ended up in the wrong block. The new epoch hasn't started yet.
            return;
        }
        
        // If ESDS.advance() has NOT already been called and advanced to the target epoch then we'll advance
        if (esds.epoch() != _targetEpoch) {
            // Then we can advance the epoch 
            // Try to call the ESDS.advance() function, but use try/catch so we can use gas tokens
            // in the case that the call fails (for example, if we passed in an incorrect `_targetEpoch` value
            try esds.advance() {
                // Success! We advanced the epoch.
            } catch {
                // Failure! Someone else advanced the epoch before us.
            }
        }
        
        // Now we know the epoch has been advanced (whether or not we advanced it), so we attempt to redeem coupons
        _redeemManyOpportunities(_users, _epochs, _couponAmounts);
        
        return;
    }
    
    function _redeemManyOpportunities(address[] calldata _users, uint256[] calldata  _epochs, uint256[] calldata _couponAmounts) internal {
        uint256 amountRedeemable = esds.totalRedeemable();
        bool success;
        uint256 amountToRedeem;
        
        for (uint256 i; i < _users.length; i++) {

            // redemption validity check
            if (amountRedeemable == 0) { break; }
            
            // redeem coupons
            amountToRedeem = _couponAmounts[i] < amountRedeemable ? _couponAmounts[i] : amountRedeemable;
            success = _redeemOpportunity(_users[i], _epochs[i], amountToRedeem);
            
            // update amountRedeemable
            amountRedeemable = success ? amountRedeemable - amountToRedeem : amountRedeemable;
        }
    }
    

    function _redeemOpportunity(address _user, uint256 _epoch, uint256 _couponAmount) internal returns (bool) {
        try couponClipper.redeem(_user, _epoch, _couponAmount) {
            // Success!
            return true;
        } catch {
            // Failure!
            return false;
        }
    }
    
    // @notice Returns the timestamp at which the _targetEpoch starts
    function getEpochStartTime(uint256 _targetEpoch) public pure returns (uint256) {
        return _targetEpoch.sub(106).mul(28800).add(1602201600);
    }
    
    // BASIC WALLET FUNCTIONS
    
    function withdrawETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    function withdrawERC20(address _token) external onlyOwner {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(owner(), balance);
    }
    
    // Used for approving the Uniswap V2 router to move this contract's ESD tokens
    // e.g. _token = ESD, _spender = UniswapV2Router02, _amount = uint128(-1)
    function ERC20Approve(address _token, address _spender, uint256 _amount) external onlyOwner {
        IERC20(_token).approve(_spender, _amount);
    }
    
    // ESD/ESDS WALLET FUNCTIONS 
    
    // stage (aka "deposit") ESD 
    function deposit(uint256 _amountOfESD) external onlyOwner {
        esds.deposit(_amountOfESD);
    }
    
    // bond ESD (to get ESDS)
    // @param _amountOfESD The amount of ESD you want to bond.
    function bond(uint256 _amountOfESD) external onlyOwner {
        esds.bond(_amountOfESD);
    }
    
    // stage (aka "deposit") and then bond in a single tx to save gas
    function depositAndBond(uint256 _amountOfESD) external onlyOwner {
        esds.deposit(_amountOfESD);
        esds.bond(_amountOfESD);
    }
    
    // unbond ESDS (to get ESD)
    // @param _amountOfESD The amount of ESD you want to get out! (NOT the amount of ESDS you want to unbond)
    function unbond(uint256 _amountOfESD) external onlyOwner {
        esds.unbondUnderlying(_amountOfESD);
    }
    
    // "unstage" (aka "withdraw") ESD (so it can be sold, transferred out, etc)
    function unstage(uint256 _amountOfESD) external onlyOwner {
        esds.withdraw(_amountOfESD);
    }
    
    // view ESD balance (amount that can be sold, transferred, etc rn)
    function getBalanceOf() external view returns (uint256) {
        return IERC20(esd).balanceOf(address(this));
    }
    
    // view balanceOfStaged (amount that is staged)
    function getBalanceOfStaged() external view returns (uint256) {
        return esds.balanceOfStaged(address(this));   
    }
    
    // get balanceOfBonded (amount of bonded ESD)
    // @returns uint256 The amount of ESD bonded (NOT ESDS!!!)
    function getBalanceOfBonded() external view returns (uint256) {
        return esds.balanceOfBonded(address(this));
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





