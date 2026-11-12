# swiftly-layout notes

Test names carry the rule they check: `apple_*` is stated in Apple's documentation, `objc_*` is the reverse-engineered
behaviour described in the objc.io SwiftUI layout material (community, not Apple), unprefixed tests are ours.

## Estimated or reverse-engineered, to be checked against the real SwiftUI app

- **HStack/VStack sharing.** Ask each child for its size at proposal 0 and infinity on the axis, sort by layout priority
  (high first) then by flexibility (max - min, small first), offer each `remaining / children left`. Apple does not
  publish this; it is the community model. Priorities: a high-priority child is offered `remaining` minus the minimum
  of the lower-priority children (our reading of "claims space first").
- **Default spacing 8 pt, default `Spacer` minimum 8 pt, no gap next to a `Spacer`.** Apple says "system-preferred spacing";
  the real value depends on the neighbouring view types. Pass `Some(spacing)` wherever the design file gives a value.
- **`Flexible` leaf (`Color`, `Rectangle`) ideal size 10 x 10.** Community value.
- **Flexible frame.** With a maximum the frame takes the clamped proposal even if the child is smaller (so
  `frame(maxWidth: .infinity)` fills); without a maximum it is the child's size clamped to the minimum. Community model.
- **`aspect_ratio`** reports the fitted rectangle as its size (Fill reports the covering rectangle, which may overflow).
- **Lazy stacks** need known item sizes (uniform or a list); they take the whole cross-axis proposal. SwiftUI estimates
  unseen items instead.
- **ScrollView** proposes `nil` on the scrolled axis and the viewport across, and takes the space it is offered.
- **ViewThatFits** compares each child's ideal size (`nil` proposal on the tested axes) with the proposal, +0.001 pt slack.

## Not built

- Alignment guides beyond the 3 x 3 grid (`firstTextBaseline`, custom guides), `offset`, `position`, `GeometryReader`,
  `Grid`/`GridRow`, `Layout` protocol, right-to-left mirroring (leading/trailing are left/right).
- Fixed-size grid columns other than the adaptive one.
- A grid of items of different heights.
