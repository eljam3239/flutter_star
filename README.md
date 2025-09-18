Star Micronics StarXpand wrapper for Flutter. 
Looking at Star's Android/iOS sdk repos first is encouraged:
https://github.com/star-micronics/StarXpand-SDK-iOS
https://github.com/star-micronics/StarXpand-SDK-Android/tree/main

Supported:

| Device      | TSP100 | TSP100sk | mPop |
|-------------|--------|----------|------|
| iOS         |   LAN     | LAN, Bluetooth         | Bluetooth     |
| Android     |  LAN      |  LAN, Bluetooth        |  Bluetooth    |

TSP100iv wired to cash drawer can open cash drawer upon completion of print jobs over LAN. 

TODO: 
1. iOS/Android wired connection to mPop10 via usb-B
2. Android wired connection to TSP100iv via usb-A. The TSP100iv manual says nothing of iPad to printer connection via usb-c, but I will try it anyways.

## Setup Instructions
iOS: 
1. Download StarXpand SDK for iOS from Star Micronics
2. Place StarIO10.xcframework in `packages/star_printer_ios/ios/`
3. Run `flutter pub get` in root directory
4. Run `cd ios && pod install` for iOS dependencies

Andoid:
Follow Android SDK installation instructions given here:
https://github.com/star-micronics/StarXpand-SDK-Android/tree/main#:~:text=Installation

This is a work in progress. The realistic hitch you might run into is the gradle file for the Android package, the podspec for the iOS package, and the pubspec.yaml for both. 
Copying my packages directory for the API layer, native interface and method channel code, then resolving your dependencies from scratch may be simpler. 
