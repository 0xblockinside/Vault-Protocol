This contract normalizes/unifies the interface of a Liquidity Locker for Uniswap's AMMs v2 & v3. What sets it apart is that it allows owners to continuously collect their positions' fees without compromising the security and properties of the lock.

### How fee collection works:

#### For Uniswap v3 AMMs:
It simply wraps locker functionality around the position NFT you receive from Uniswap since v3 already allows you to continuously collect fees from your position.

#### For Uniswap v2 AMMs:
It is a bit more involved because although the AMM does accrue the 0.3% fee for the user, it does not allow them to easily continuously collect this fee.

One way the user could collect their fee is to remove all liquidity. This will give them back the principal + the fees but would be worrisome to holders as they would have to trust the owner of liquidity will re-add liquidity to the project.

One solution is for the owner to remove all liquidity and then re-adds the non-fee portion all within one transaction to guarantee that the liquidity won't rug. However, the way Uniswap v2 handles initial liquidity provision by minting MINIMUM_LIQUIDITY amount of liquidity to the dead wallet (a useless feature in practicality), it creates reserve ratio mismatches issues when adding the liquidity again.

Our locker solves this problem by taking into account the following mathematical invariants:

1. \( (removed0 - fee0) \times (removed1 - fee1) = snapshot.amountIn0 \times snapshot.amountIn1 \) [constant product invariant]
2. \( \frac{removed1}{removed0} = \frac{(removed1 - fee1)}{(removed0 - fee0)} \) [same price invariant]

Where:
- \( removed0 = \frac{snapshot.liquidity \times balance0}{totalLiquidity} \)
- \( removed1 = \frac{snapshot.liquidity \times balance1}{totalLiquidity} \)

Solving invariant 2 for \( fee1 \), we get:

\[
\begin{align*}
removed1 \times (removed0 - fee0) &= removed0 \times (removed1 - fee1) \\
removed1 \times removed0 - removed1 \times fee0 &= removed0 \times removed1 - removed0 \times fee1 \\
-removed1 \times fee0 &= -removed0 \times fee1 \\
removed1 \times fee0 &= removed0 \times fee1 \\
fee1 &= \frac{removed1 \times fee0}{removed0}
\end{align*}
\]

And by expanding invariant 1 and then substituting \( fee1 \) from invariant 2 to have like terms we get:

\[
\begin{align*}
(removed0 - f0) \times (removed1 - \left[\frac{removed1 \times f0}{removed0}\right]) &= snapshot.amountIn0 \times snapshot.amountIn1 \\
removed0 \times removed1 - \left(\frac{removed0 \times removed1 \times f0}{removed0}\right) - f0 \times removed1 + \frac{f0 \times removed1 \times f0}{removed0} &= snapshot.amountIn0 \times snapshot.amountIn1 \\
removed0 \times removed1 - 2 \times removed1 \times f0 + \frac{removed1 \times f0^2}{removed0} &= snapshot.amountIn0 \times snapshot.amountIn1 \\
\frac{removed1}{removed0} \times f0^2 - 2 \times removed1 \times f0 + (removed0 \times removed1 - snapshot.amountIn0 \times snapshot.amountIn1) &= 0
\end{align*}
\]

This has the form of a quadratic equation and therefore we use the quadratic equation to solve for \( f0 \):

\[
f0 = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
\]

where:
- \( a = \frac{removed1}{removed0} \)
- \( b = -2 \times removed1 \)
- \( c = (removed0 \times removed1 - snapshot.amountIn0 \times snapshot.amountIn1) \)

Substituting we get:

\[
f0 = removed0 \pm \sqrt{\frac{removed0}{removed1} \times snapshot.amountIn0 \times snapshot.amountIn1}
\]

We can eliminate the root which makes \( f0 > removed0 \) since it would not make sense to take a fee greater than what was removed and we have:

\[
f0 = removed0 - \sqrt{\frac{removed0}{removed1} \times snapshot.amountIn0 \times snapshot.amountIn1}
\]

There is, however, another way to describe \( f0 \):

\[
f0 = \left(\frac{x}{TOTAL\_LIQUIDITY}\right) \times balance0
\]

where \( x \) is the amount of liquidity that represents the share of just the fee part. This is exactly the number we want to use to continuously collect an LP owner's fees without having to remove all of the position's liquidity.

Solving for \( x \) we get:

\[
x = \left(\frac{TOTAL\_LIQUIDITY}{balance0}\right) \times f0
\]

Substituting \( f0 \):

\[
x = \left(\frac{TOTAL\_LIQUIDITY \times removed0}{balance0}\right) - \left(\frac{TOTAL\_LIQUIDITY}{balance0}\right) \times \sqrt{\left(\frac{removed0}{removed1}\right) \times snapshot.amountIn0 \times snapshot.amountIn1}
\]

If we restructure the first term and bring \( balance0 \) into the square root, we get the following:

\[
x = snapshot.liquidity - \frac{TOTAL\_LIQUIDITY \times \sqrt{snapshot.amountIn0 \times snapshot.amountIn1}}{\sqrt{balance0 \times balance1}}
\]

\[
x = snapshot.liquidity - \sqrt{snapshot.amountIn0 \times snapshot.amountIn1}
\]

Since \( snapshot.liquidity = \left(\frac{removed0}{balance0}\right) \times TOTAL\_LIQUIDITY \).

This mathematical formulation ensures that the fee collection mechanism is robust and adheres to the liquidity and price invariants, allowing for a secure and continuous fee collection without the need to fully liquidate the position.