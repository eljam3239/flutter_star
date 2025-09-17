Star Micronics StarXpand wrapper for Flutter. 

Supported:

| Device      | TSP100 | TSP100sk | mPop |
|-------------|--------|----------|------|
| iOS         |   LAN     | LAN, Bluetooth         | Bluetooth     |
| Android     |  LAN      |  LAN, Bluetooth        |  Bluetooth    |

iOS and Android implementations currently support the opening of a cash drawer connected to the TSP100 when a print job done over LAN.

TODO: 
1. mPop cash drawer opening for iOS/Android
2. Android 

## Setup Instructions
1. Download StarXpand SDK for iOS from Star Micronics
2. Place StarIO10.xcframework in `packages/star_printer_ios/ios/`
3. Run `flutter pub get` in root directory
4. Run `cd ios && pod install` for iOS dependencies

Flutter-based printing to TSP100 support on Android in progress.
