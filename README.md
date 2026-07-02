# Touch-Up
**Universal user-level driver to support touchscreens on macOS**
<hr/>

Most current touchscreens work with Microsoft Windows out-of-the-box as they implement a standardized communication via USB HID. However, nothing happens when connecting these screens to a Mac.
The goal of Touch Up was to provide a simple, general-purpose driver that enables plug-and-play support for touchscreens on macOS. 
The code in this repository provides a user-space driver that reads and processes the HID data into a set of touches and different utilities to inject mouse events into the system.

## What can you do with this App?
The Touch Up **utility app** allows you to control your Mac with any connected touch screen. Touch Up supports clicks, cursor movement, two-finger scrolling, and optional secondary clicks.
While the behavior of the driver is customizable, the default setting follows Windows-like touch gestures:

- Tap anywhere on the screen to click objects
- Move the cursor by dragging one finger over the screen
- Right-click by pressing and holding one finger
- Move windows by dragging from their title bar
- Scroll content by dragging two fingers
- Secondary clicks can be performed with an optional two-finger tap


### Installing the App
- Compile the app or [download the latest notarized build here](https://github.com/shueber/Touch-Up/releases).
- If you wish, move the app into your Applications folder and add it as a Login item.
- Launch it and allow the requested Accessibility and Input Monitoring access.
- Plug in your touchscreen and start touching.

### Privacy and Permissions
Touch Up needs Accessibility access to post mouse events to macOS.

On recent macOS versions, reading low-level USB HID touch reports also requires the system permission named Input Monitoring. Touch Up requests this permission through `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` and uses it only for USB HID devices whose descriptors look like touchscreens, digitizers, or absolute touch pointers. Touch Up does not install a keyboard event tap, does not match keyboard devices, and does not process keyboard input.


### Compatibility
Touch Up should work with any touchscreen that also works with Windows.
We used the following screens for testing:

- Iiyama TF3222MC and T2336MSC-B2
- 3M C4667PW




## The *TouchUpCore* Framework
Game developers, researchers, and others who need access to all touch data can also benefit from this project by integrating the TouchUpCore **framework** themselves. It provides simple access to all touches recognized on the touch surface, simplifying multitouch prototype development in macOS.

The Touch Up app itself is an example of integrating the TouchUpCore framework. You can have a look at the *DebugView* to see how you can visualize the different touch points. Remember that your app needs an Entitlement to access USB if running in the Sandbox.
