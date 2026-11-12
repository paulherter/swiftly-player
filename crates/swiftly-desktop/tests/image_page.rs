//! The suite's screens share their demo pictures and icons, so the image page keeps room for the screens pushed later
//! (the Downloads empty state lost its symbol when the five tabs had filled the page).

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

#[test]
fn a_new_suite_leaves_room_on_the_image_page() {
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let suite = Suite::new(env, Cx::deterministic());
    let (_, y, row) = suite.cx().images.borrow().cursor();
    assert!(y + row < 1400, "the tabs used {} of 2048 rows", y + row);
    assert!(
        suite
            .cx()
            .add_image(88, 88, &vec![255u8; 88 * 88 * 4])
            .is_some(),
        "an 88 px symbol still fits"
    );
}
