# swiftly-layout

SwiftUI's propose/answer layout model in pure Rust (no dependencies, `f32` points). A parent proposes a `Proposal`
(each axis `nil`, zero, infinity or a value), the child answers with a `Size`, the parent places it. taffy (flexbox) was
rejected because flexbox is not this model.

| Node | SwiftUI |
|---|---|
| `Node::hstack` / `vstack` / `zstack`, `spacer`, `spacer_min` | `HStack`, `VStack`, `ZStack`, `Spacer` |
| `.frame`, `.flex_frame`, `.padding`, `.overlay`, `.background`, `.aspect_ratio`, `.fixed_size`, `.layout_priority` | the modifiers of the same name |
| `Node::measured(closure)` | text leaf: the closure answers a `Proposal` (build it from `swiftly-text`) |
| `Node::view_that_fits(axes, children)` | `ViewThatFits` |
| `Node::lazy_stack(LazyStack)`, `Node::grid(AdaptiveGrid)` | `LazyHStack`/`LazyVStack`, `LazyVGrid(.adaptive)`; `LazyPlan::visible(from, to)` windows 100k items in O(1) / O(log n) |
| `Node::scroll(axis, content)` | `ScrollView`; `Placed::content` is the content size |

```rust
use swiftly_layout::{Align, Node, Size, layout};
let row = Node::hstack(Align::Center, Some(0.0),
    vec![Node::fixed(50.0, 20.0), Node::spacer_min(0.0), Node::fixed(50.0, 20.0)]);
let placed = layout(&row, Size::new(300.0, 100.0));       // frames are relative to the parent
assert_eq!(placed.children[2].frame.x, 250.0);
```

Answers are memoised during one pass (a stack asks each child three times), so deep trees stay linear.
Rules and where each comes from (Apple docs, objc.io community, estimated): `NOTES.md`.

```sh
cargo test -p swiftly-layout
cargo clippy -p swiftly-layout --all-targets -- -D warnings
```
