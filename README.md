
This contract normalizes/unifies the interface of a Liquidity Locker for Uniswaps AMMs v2 & v3. What sets it apart is that allows owners to continiously collect their positions' fees without compromising the security and properties of the lock.


How fee collection works:
    For the Uniswap v3 AMMs it is simply wraps locker functionality around the position nft you mint recieve from uniswap since v3 already allows you to continously collect fees from your position.


    For Uniswap v2 AMMs it is a bit more involved because although the AMM does accrue the 0.3% fee for the user, it does not allow them to easily continously collect this fee. 
    
    One way the user could collect their fee is to remove all liquidity. This will give them back the principal + the fees but would be worrisome to holders as they would have to trust the owner of liqudiity will re-add liquidity to the project.

    One solution is for the owner to remove all liquidity and then re-adds the non fee portion all within one transaction to guarantee that the liquidity wont rug. However, the way uniswap v2 handles intial liquidity provision by minting MINIMUM_LIQUIDITY amount of liquidity to the dead wallet (a useless feature in practicality), it creates reserve ratio mismatches issues when adding the liquidity again.


    Our locker solves this problem by taking into account the followiing mathematical invariants:
        1). (removed0 - fee0) * (removed1 - fee1) = snapshot.amountIn0 * snapshot.amountIn1 [constant product invariant]
        2). removed1 / removed0 = (removed1 - fee1) / (removed0 - fee0) [same price invariant]

    where
        removed0 = snapshot.liquidity * balance0 / totalLiquidity
        removed1 = snapshot.liquidity * balance1 / totalLiquidity


    Solving invariant 2 for fee1, we get:

    removed1 * (removed0 - fee0) = removed0 * (removed1 - fee1)
    removed1 * removed0 - removed1 * fee0 = removed0 * removed1 - removed0 * fee1
    -removed1 * fee0 = - removed0 * fee1
    removed1 * fee0 = removed0 * fee1
    fee1 = removed1 * fee0 / removed0

    And by expanding invariant 1 and then substituting fee1 from invariant 2 to have like terms we get:

    (removed0 - f0) * (removed1 - [removed1 * f0 / removed0]) = snapshot.amountIn0 * snapshot.amountIn1
    removed0 * removed1 - (removed0 * removed1 * f0 / removed0) - f0 * removed1 + f0 * removed1 * f0 / removed0 = snapshot.amountIn0 * snapshot.amountIn1

    removed0 * removed1 - 2 * removed1 * f0 + removed1 * f0 ** 2 / removed0 = snapshot.amountIn0 * snapshot.amountIn1

    (removed1 / removed0) * f0 ** 2 - 2 * removed1 * f0 + (removed0 * removed1 - snapshot.amountIn0 * snapshot.amountIn1) = 0

    This has the form of a quadratic equation and therefore we use the quadratic equation to solve for f0

    f0 = (-b +- sqrt(b ** 2 - 4ac)) / 2a

    where 

    a = (removed1 / removed0)
    b = - 2 * removed1
    c = (removed0 * removed1 - snapshot.amountIn0 * snapshot.amountIn1)

    substituting we get

    f0 = (2 * removed1 +- sqrt(4 * (removed1 ** 2) - 4 * (removed1 / removed0) * (removed0 * removed1 - snapshot.amountIn0 * snapshot.amountIn1))) / 2 * (removed1 / removed0)

    f0 = removed0 +- (removed0 / removed1) * sqrt(removed1 ** 2 - (removed1 / removed0) * (removed0 * removed1 - snapshot.amountIn0 * snapshot.amountIn1))

    f0 = removed0 +- (removed0 / removed1) * sqrt((removed1 / removed0) * snapshot.amountIn0 * snapshot.amountIn1)

    f0 = removed0 +- sqrt((removed0 / removed1) * snapshot.amountIn0 * snapshot.amountIn1)

    we can eliminate the root which makes f0 > removed0 since it would not make sense to take a fee greater than what was removed and we have

    f0 = removed0 - sqrt((removed0 / removed1) * snapshot.amountIn0 * snapshot.amountIn1)


    There is however another way to describe f0,

    f0 = (x / TOTAL_LIQUIDITY) * balance0

    where x the amount of liquidity that represents the share of just the fee part. This is exactly the number we want to use to continiously collect an LP owners fees without having to remove all of the positions liquidity.

    solving for x we get,

    x = (TOTAL_LIQUIDITY / balance0) * f0

    substituting f0

    x = (TOTAL_LIQUIDITY * removed0 / balance0) - (TOTAL_LIQUIDITY / balance0) * sqrt((removed0 / removed1) * snapshot.amountIn0 * snapshot.amountIn1)


    if we restructure the first term and bring balance0 into the sqrt we get the following:

    x = snapshot.liquidity - TOTAL_LIQUIDITY * sqrt(snapshot.amountIn0 * snapshot.amountIn1) / sqrt(balance0 * balance1)

    x = snapshot.liquidity - sqrt(snapshot.amountIn0 * snapshot.amountIn1)

    since snapshot.liquidity = (removed0 / balance0) * TOTAL_LIQUIDITY


    

