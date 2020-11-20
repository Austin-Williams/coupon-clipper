# coupon-clipper
Better living through bot bribery

Warning: This is unaudited code. Use it at your own risk. Please exercise some prudence.

# where
`CouponClipperV2` can be found on mainnet at: [0xb4027EEEa4b2D91616c63Dc3E37075E69f36b457](https://etherscan.io/address/0xb4027eeea4b2d91616c63dc3e37075e69f36b457#code)

A friendly UI has been built by Lewi at [https://esd.coupons/](https://esd.coupons/).

# what
`CouponClipperV2` is a contract that that helps ESD coupon holders and bot writers come together and help each other.

Coupon holders approve the `CouponClipperV2` contract address (via the [`ESDS.approveCoupons` function](https://github.com/emptysetsquad/dollar/blob/master/protocol/contracts/dao/Market.sol#L98)).

Bot writers listen for the [`CouponApproval` events](https://github.com/emptysetsquad/dollar/blob/master/protocol/contracts/dao/Market.sol#L103) to learn which coupon holders have approved the `CouponClipper` contract.

When coupons can be redeemed, bots can call the [`CouponClipperV2.redeem` function](https://github.com/Austin-Williams/coupon-clipper/blob/main/contracts/CouponClipper.sol#L113) to claim any of those user's coupons on their behalf -- taking a fee for their service. The developer gets a 1% "house take" for creating this service, and the rest goes to bot that performs the coupon redemption.

The default (and minimum) fee is set to 2% of the ESD coming from the redeemed coupons. But users are free to change the fee to any value greater than or equal to 2% by calling the [`setOffer` function](https://github.com/Austin-Williams/coupon-clipper/blob/main/contracts/CouponClipper.sol#L72) and passing in the number of basis points they want to offer for having their coupons redeemed for them.

The ESD foes directly into the user's acccounts. No action is required on behalf of the coupon holders other than approving the `CouponClipper` contract via the [`ESDS.approveCoupons` function](https://github.com/emptysetsquad/dollar/blob/master/protocol/contracts/dao/Market.sol#L98).

# why
Only so many coupons can be redeemed per epoch, so there is often a race to determine who gets to redeem first. Naturally, bots win these races and get to redeem all their own coupons first.

When the bots have claimed all their own coupons, then the "mannual users" have a chance.

`CouponClipper` is a way for "manual users" to get the bots to work for them in a trustless fashion.

# contribute
Please see the issues section for ways you can help.
