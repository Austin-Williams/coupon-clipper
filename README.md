# coupon-clipper
Better living through bot bribery

# where
`CouponClipper` can be found on mainnet at: [0xF176D56b9B5fB458AE9A223aCc5C3e35402deD12](https://etherscan.io/address/0xF176D56b9B5fB458AE9A223aCc5C3e35402deD12#code)

# what
`CouponClipper` is a contract that that helps ESD coupon holders and bot writers come together and help each other.

Coupon holders approve the `CouponClipper` contract address (via the [`ESDS.approveCoupons` function](https://github.com/emptysetsquad/dollar/blob/master/protocol/contracts/dao/Market.sol#L98)).

Bot writers listen for the [`CouponApproval` events](https://github.com/emptysetsquad/dollar/blob/master/protocol/contracts/dao/Market.sol#L103) to learn which coupon holders have approved the `CouponClipper` contract.

When coupons can be redeemed, bots can call the [`CouponClipper.redeem` function](https://github.com/Austin-Williams/coupon-clipper/blob/main/contracts/CouponClipper.sol#L49) to claim any of those user's coupons on their behalf -- taking a fee for their service.

The default fee is set to 1% of the ESD coming from the redeemed coupons. But users are free to change the fee to whatever they want by calling the [`setOffer` function](https://github.com/Austin-Williams/coupon-clipper/blob/main/contracts/CouponClipper.sol#L40) and passing in the number of basis points they want to give the bots.

The ESD is depoisted directly into the user's acccounts. No action is required on behalf of the coupon holders other than approving the `CouponClipper` contract via the [`ESDS.approveCoupons` function](https://github.com/emptysetsquad/dollar/blob/master/protocol/contracts/dao/Market.sol#L98).

# why
Only so many coupons can be redeemed per epoch, so there is often a race to determine who gets to redeem first. Naturally, bots win these races and get to redeem all their own coupons first.

When the bots have claimed all their own coupons, then the "mannual users" have a chance.

`CouponClipper` is a way for "manual users" to get the bots to work for them in a trustless fashion.

# contribute
Please see the issues section for ways you can help.