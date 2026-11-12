//! Sort, dedup and paging benchmark on 10k items: `cargo bench -p swiftly-library --bench lists`.

#![allow(clippy::expect_used)]

use std::hint::black_box;
use std::time::Instant;

use swiftly_library::list_rules::ListRules;
use swiftly_model::Item;
use swiftly_rules::natural_order::{NaturalCollator, NaturalOrder};

fn items(n: usize) -> Vec<Item> {
    (0..n)
        .map(|i| {
            // A mix of Latin, numbered, accented and Cyrillic titles, as a real library has.
            let name = match i % 5 {
                0 => format!("The Film {} Part {}", (i * 7919) % 997, i % 13),
                1 => format!("{} Days Later {}", (i * 31) % 500, i),
                2 => format!("Zoë Élan {}", (i * 17) % 3001),
                3 => format!("Старый фильм {}", (i * 13) % 700),
                _ => format!("alpha beta {} gamma", (i * 101) % 4000),
            };
            Item {
                sort_name: Some(name.to_lowercase()),
                production_year: Some(1950 + (i % 74) as i64),
                date_created: Some(format!(
                    "2023-0{}-0{}T12:00:00.0000000Z",
                    1 + i % 9,
                    1 + i % 8
                )),
                ..Item::new(
                    format!("{i:032x}"),
                    name,
                    Some(["Movie", "Series", "Episode"][i % 3]),
                )
            }
        })
        .collect()
}

fn time<R>(label: &str, runs: usize, mut f: impl FnMut() -> R) {
    let mut samples: Vec<f64> = (0..runs)
        .map(|_| {
            let t = Instant::now();
            black_box(f());
            t.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    samples.sort_by(f64::total_cmp);
    println!(
        "{label:<44} median {:>9.3} ms   min {:>9.3} ms",
        samples[samples.len() / 2],
        samples[0]
    );
}

fn main() {
    let list = items(10_000);
    let collator = NaturalCollator::new("de").expect("collator data is compiled in");
    time("natural sort 10k", 9, || {
        NaturalOrder::sorted(list.clone(), &collator, |i| {
            (i.name.as_str(), i.sort_name.as_deref())
        })
    });
    time("clone 10k Items (baseline of the above)", 15, || {
        list.clone()
    });
    time("ListRules::without_double 10k", 15, || {
        ListRules::without_double(&list)
    });
    time("ListRules::je_title_in_times 10k", 15, || {
        ListRules::je_title_in_times(&list, 10_000)
    });
    time("ListRules::append 200 onto 10k", 15, || {
        ListRules::append(&list[9_900..], &list[..9_900])
    });
}
