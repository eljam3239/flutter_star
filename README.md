Star Micronics StarXpand wrapper for Flutter. 
Looking at Star's Android/iOS sdk repos first is encouraged:
https://github.com/star-micronics/StarXpand-SDK-iOS
https://github.com/star-micronics/StarXpand-SDK-Android/tree/main

Supported:

| Device      | TSP100iv | TSP100ivsk | mPop | mC-Label2 | TSP100iii | mC_Print3 (MCP31LB) |
|-------------|--------|----------|------|-----------|---------|--------|
| iOS         |   LAN     | LAN, Bluetooth         | Bluetooth     | LAN, Bluetooth, USB | LAN | LAN, Bluetooth, usb-a-usb-c |
| Android     |  LAN      |  LAN, Bluetooth, usb-a        |  Bluetooth , usb-b   | LAN, Bluetooth, USB | LAN | LAN, Bluetooth, usb-b |

TSP100iv wired to cash drawer can open cash drawer upon completion of print jobs over LAN. Same with builtin mPop cash drawer.

Set the auto-connect to off in a bluetooth printer's bluetooth settings in the quick start app if you want to connect a tablet to that printer over usb. Otherwise wired can't be connected. 

Switch the printer off and turn back on if plugging a usb into the printer doesn't work after it was previously connected via bluetooth.

Same goes for using bluetooth after it was used for wired: unplug the wired device, power the printer off and on again, then you'll be able to connect via Bluetooth. The tsp100ivsk could print over Bluetooth and usb without a power cycle when connected to the android tablet. The mC-Label2 seems to allow connecting to Bluetooth after a wired connection without a power cycle (on iOS), provided the cable is unplugged and the device is paired in the tablet's bluetooth settings. On Android, the wired connect tap times out if you attempt to do so immediately following pairing the mc2 in app.

iOS receipt and label printing work on all models in all interfaces. No refactoring of reciept printing done for 38 mm paper on tsp100ivsk, and no label prints being done for the tsp100iiiw. mPop receipt slightly too narrow.
Android same thing.




TODO: 
1. Test usb ios implementation once I have a device that supports it.
2. Improve iOS setup requirements by putting the Star SDK in its own Cocoa pod?

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
