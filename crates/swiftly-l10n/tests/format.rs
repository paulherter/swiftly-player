use swiftly_l10n::Arg;
use swiftly_l10n::format::{ArgClass, placeholders, render, signature};

#[test]
fn basic_placeholders() {
    assert_eq!(render("%@ von %@", &["A".into(), "B".into()]), "A von B");
    assert_eq!(render("%lld Folgen", &[Arg::Int(3)]), "3 Folgen");
    assert_eq!(
        render("%d/%ld/%lu", &[1.into(), Arg::Int(-2), Arg::Uint(3)]),
        "1/-2/3"
    );
    assert_eq!(render("100 %% sicher", &[]), "100 % sicher");
    assert_eq!(render("%@", &[Arg::Int(7)]), "7");
}

#[test]
fn positional_placeholders_reorder() {
    assert_eq!(
        render("%2$@ vor %1$@", &["a".into(), "b".into()]),
        "b vor a"
    );
    assert_eq!(
        render("%1$lld Std. %2$lld Min.", &[2.into(), 5.into()]),
        "2 Std. 5 Min."
    );
    assert_eq!(render("%1$@%1$@", &["x".into()]), "xx");
}

#[test]
fn numbers_with_flags() {
    assert_eq!(render("%.1f", &[Arg::Float(2.25)]), "2.2");
    assert_eq!(render("%.2f", &[Arg::Float(3.14999)]), "3.15");
    assert_eq!(render("%f", &[Arg::Float(1.5)]), "1.500000");
    assert_eq!(render("%05d", &[Arg::Int(42)]), "00042");
    assert_eq!(render("%05d", &[Arg::Int(-42)]), "-0042");
    assert_eq!(render("[%-4d]", &[Arg::Int(7)]), "[7   ]");
    assert_eq!(render("[%4d]", &[Arg::Int(7)]), "[   7]");
    assert_eq!(render("%+d", &[Arg::Int(7)]), "+7");
    assert_eq!(
        render("%02lld:%02lld", &[Arg::Int(5), Arg::Int(9)]),
        "05:09"
    );
    assert_eq!(render("%x", &[Arg::Int(255)]), "ff");
    assert_eq!(render("%.3@", &["abcdef".into()]), "abc");
}

#[test]
fn missing_arguments_stay_visible() {
    assert_eq!(render("%@ und %@", &["a".into()]), "a und %@");
    assert_eq!(render("%1$@ %3$@", &["a".into()]), "a %3$@");
}

#[test]
fn stray_percent_is_literal() {
    assert_eq!(render("50%", &[]), "50%");
    assert_eq!(render("100%!", &[]), "100%!");
    assert_eq!(render("%", &[]), "%");
}

#[test]
fn signatures_compare_by_position_and_class() {
    assert_eq!(signature("%@ von %@"), signature("%1$@ of %2$@"));
    assert_eq!(signature("%2$@ %1$@"), signature("%1$@ %2$@"));
    assert_ne!(signature("%lld Folgen"), signature("%@ Folgen"));
    assert_eq!(signature("%lld"), signature("%d"));
    assert_eq!(signature("%lld"), vec![(1, ArgClass::Integer)]);
    assert_eq!(placeholders("%@ %%").len(), 1);
}
