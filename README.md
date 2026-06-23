# CarIOS Controller App
This is a SwiftUI implementation of the CarIOS controller app from my van-life project. The app queries the status of the solar/power supply and internet connection in my camper van, and controls the lighting and other features.

# Technical
The app keeps the existing CarIOS protocols:

- BLE service `0000FEED-0000-1000-8000-00805F9B34FB`
- Command characteristic `0000BEEF-0000-1000-8000-00805F9B34FB`
- Server output characteristic `0000DEAD-0000-1000-8000-00805F9B34FB`
- Server input characteristic `0000C0DE-0000-1000-8000-00805F9B34FB`
- HTTP `POST /carios` payloads with `v`, `o` query, `x` action, and `a` action body.


