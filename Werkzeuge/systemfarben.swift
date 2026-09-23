import UIKit

let dunkel = UITraitCollection(userInterfaceStyle: .dark)

func hex(_ f: UIColor) -> String {
    let c = f.resolvedColor(with: dunkel)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getRed(&r, green: &g, blue: &b, alpha: &a)
    return String(format: "#%02X%02X%02X  a=%.3f   Color(red: %.3f, green: %.3f, blue: %.3f)",
                  Int((r*255).rounded()), Int((g*255).rounded()), Int((b*255).rounded()), a, r, g, b)
}

let liste: [(String, UIColor)] = [
    ("systemBackground",            .systemBackground),
    ("secondarySystemBackground",   .secondarySystemBackground),
    ("tertiarySystemBackground",    .tertiarySystemBackground),
    ("systemGroupedBackground",     .systemGroupedBackground),
    ("secondarySystemGroupedBackground", .secondarySystemGroupedBackground),
    ("systemFill",                  .systemFill),
    ("secondarySystemFill",         .secondarySystemFill),
    ("tertiarySystemFill",          .tertiarySystemFill),
    ("quaternarySystemFill",        .quaternarySystemFill),
    ("label",                       .label),
    ("secondaryLabel",              .secondaryLabel),
    ("tertiaryLabel",               .tertiaryLabel),
    ("quaternaryLabel",             .quaternaryLabel),
    ("separator",                   .separator),
    ("opaqueSeparator",             .opaqueSeparator),
    ("systemGray",                  .systemGray),
    ("systemGray2",                 .systemGray2),
    ("systemGray3",                 .systemGray3),
    ("systemGray4",                 .systemGray4),
    ("systemGray5",                 .systemGray5),
    ("systemGray6",                 .systemGray6),
    ("systemBlue",                  .systemBlue),
    ("systemTeal",                  .systemTeal),
    ("systemOrange",                .systemOrange),
    ("systemRed",                   .systemRed),
    ("systemGreen",                 .systemGreen),
]
for (name, farbe) in liste {
    print(String(format: "%-36s %@", (name as NSString).utf8String!, hex(farbe)))
}
