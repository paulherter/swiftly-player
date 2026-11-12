use crate::Rng;
use serde_json::{Value, json};

const WORDS: &[&str] = &[
    "The",
    "A",
    "An",
    "Der",
    "Die",
    "Das",
    "Le",
    "La",
    "Star",
    "Wars",
    "Adam",
    "Project",
    "Zorro",
    "alpha",
    "Beta",
    "gamma",
    "Ärger",
    "Über",
    "Öl",
    "ñandú",
    "Ça",
    "résumé",
    "Straße",
    "Ωmega",
    "Выживший",
    "Ёлки",
    "Елка",
    "Жизнь",
    "Застава",
    "Война",
    "и",
    "мир",
    "Αθήνα",
    "Ωραία",
    "العربية",
    "שלום",
    "東京",
    "ドラえもん",
    "한국어",
    "ＡＢＣ",
    "ａｂｃ",
    "007",
    "12",
    "2+1",
    "3",
    "10",
    "9",
    "1.5",
    "Ⅳ",
    "½",
    "x",
];
const SEPARATORS: &[&str] = &[" ", " ", " ", ": ", " - ", "-", "'", ".", ", "];
const OPENERS: &[&str] = &[
    "", "", "", "«", "\"", "(", "[", "'", "...", "¡", "¿", "#", "@", "!",
];

fn title(rng: &mut Rng) -> String {
    let n = rng.range(1, 4) as usize;
    let mut out = String::from(*rng.pick(OPENERS));
    for i in 0..n {
        if i > 0 {
            out.push_str(rng.pick(SEPARATORS));
        }
        out.push_str(rng.pick(WORDS));
    }
    if rng.chance(10) {
        out.push_str(rng.pick(&["»", ")", "]", "!", "?", " (2019)", " 2", " II"]));
    }
    out
}

fn sort_name(rng: &mut Rng, name: &str) -> Value {
    match rng.below(5) {
        0 => Value::Null,
        1 => json!(name.to_lowercase()),
        2 => {
            let rest = name.strip_prefix("The ").unwrap_or(name);
            json!(rest)
        }
        3 => json!(""),
        _ => Value::Null,
    }
}

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x4E41_5455);
    let locales = [
        "en", "de", "ru", "el", "ar", "ja", "zh", "es", "sv", "tr", "uk", "nl", "ko",
    ];
    let mut cases = vec![];
    for round in 0..260 {
        let locale = locales[round % locales.len()];
        let n = rng.range(2, 40) as usize;
        let titles: Vec<Value> = (0..n)
            .map(|_| {
                let name = title(&mut rng);
                let sort = sort_name(&mut rng, &name);
                json!({ "name": name, "sort": sort })
            })
            .collect();
        cases.push(json!({ "locale": locale, "titles": titles }));
    }
    cases
}
