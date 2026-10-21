# Local StoreKit testing

`Swiftly.storekit` describes the three tips, the monthly subscription and the lifetime unlock exactly as App Store Connect does
(same product IDs, consumables, prices 1.99 / 4.99 / 9.99 in the German
storefront). With it, Xcode answers purchases locally: no sandbox account, no
network, and the transaction manager shows every purchase.

The file is in the project (navigator group "StoreKit") but in no target, so it
never ships in a bundle.

**It is not set in the schemes.** XcodeGen would have to generate shared
schemes for that, replacing the ones Xcode creates; that changes more than this
one setting. Set it once by hand per scheme:

1. Product → Scheme → Edit Scheme… (Swiftly-iOS, Swiftly-tvOS, Swiftly-macOS)
2. Run → Options → StoreKit Configuration → `Swiftly.storekit`
3. Run the app from Xcode.

What to try, per platform:

- Settings → Support Swiftly: the three prices appear, nothing is selected,
  "Maybe later" closes the sheet.
- Buy a tip → thank-you page → "Choose an app icon" → switch the icon, back to
  Standard.
- Cancel in the purchase dialog → friendly note, nothing changes.
- Debug → StoreKit → Manage Transactions: refund the purchase → the supporter
  heart goes away after the next launch.
- Editor → "Enable Ask To Buy" in the `.storekit` file, buy → "waiting for
  approval" note; approve in the transaction manager → thank-you page appears.
- Delete the app, run again → the supporter status comes back from the
  purchase history (`SKIncludeConsumableInAppPurchaseHistory`).
- "Restore Purchases" with and without a purchase.
