# Notes: where the research text and the code differ

1. **Over-damped `Spring(duration:bounce:)` (bounce < 0).** research-feel.md section 2 prints
   `damping = 4*pi / (duration + 4*pi*bounce)`. With the preset duration 0.5 this is zero at bounce -0.04 and negative below
   that (a spring with negative damping explodes), so it cannot be right for the stated range -1..0. The code uses
   `damping = 4*pi / (duration * (1 + bounce))` (damping ratio `1 / (1 + bounce)`), which equals the other branch at
   bounce 0 and grows to infinity at -1. Both Apple examples in the research (bounce >= 0 and stiffness/damping -> bounce 0.5)
   reproduce exactly; the bounce < 0 branch has no Apple number to test against, so it is **unverified** against Apple.
   `Spring::bounce()` is the inverse of this form (`1/zeta - 1` for over-damped springs).
2. **Computed table, `.spring()` legacy damping.** The research table prints 20.7; the formula gives 20.73. Rounding only,
   the test allows 0.05.
3. **Stop of a glide.** The glide ends when the remaining distance is under 0.5 pt (research eps); the tail is dropped at a
   speed of about 1 pt/s, so it is not a visible step. The 3.8 s and 0.60 s numbers reproduce with that rule.
4. Everything else in the research section 1/2 numbers reproduced from the formulas (999 pt, 3.8 s, 199 pt, 0.60 s, 51.7,
   97.4, 157.9/17.6, 0.63/0.5, 0.735 s).
