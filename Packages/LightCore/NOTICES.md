# LightCore third-party notices

LightCore's `ColorMath` is a Swift re-implementation (no code copied verbatim) of formulas from the projects below. Their licences require attribution; please also copy these entries into the repo-level `THIRD_PARTY_NOTICES.md`.

## Home Assistant: `homeassistant/util/color.py`
- Source: https://github.com/home-assistant/core/blob/dev/homeassistant/util/color.py
- License: Apache License 2.0, Copyright Home Assistant contributors.
- Used: RGB <-> xy (wide-gamut D65 matrices), xy+brightness -> RGB, HSV conversions, RGBW/RGBWW split (`match_max_scale`), colour temperature <-> RGBWW, Kelvin <-> mired (floored), McCamy xy -> CCT, gamut point-in-triangle and closest-point clamping, brightness/value scaling. The unified `ColorMode` model follows HA's `homeassistant/components/light` (PLAN.md D7).
- Reference vectors in `Tests/LightCoreTests/ColorMathTests.swift` come from these formulas and from HA's `tests/util/test_color.py`.

## Philips Hue SDK application design note "RGB to xy Color conversion"
- Source: https://github.com/PhilipsHue/PhilipsHueSDK-iOS-OSX/blob/00187a3/ApplicationDesignNotes/RGB%20to%20xy%20Color%20conversion.md
- License: "Code is given as is. Use at your own risk and discretion." (as cited by HA).
- Used: gamma correction, conversion matrices, gamut A/B/C corner values.

## benknight/hue-python-rgb-converter (rgbxy)
- Source: https://github.com/benknight/hue-python-rgb-converter
- License: MIT, Copyright (c) 2014 Benjamin Knight.
- Used (via HA): cross product, closest point on line / triangle, point-in-lamp-reach test.

## Tanner Helland, "How to Convert Temperature (K) to RGB"
- Source: http://www.tannerhelland.com/4435/convert-temperature-rgb-algorithm-code/
- Used (via HA): Kelvin -> RGB approximation constants.

## Kim et al. Planckian locus cubic spline
- Kim, Kang et al., "Design of Advanced Color Temperature Control System for HDTV Applications", Journal of the Korean Physical Society 41 (2002). Published formula, no licence.
- Used: `ColorMath.kelvinToXY`.

## 0xProbabillity/house-control
- Source: https://github.com/0xProbabillity/house-control (`core/Sources/HouseCore/DeviceService.swift`, `ColorMath` enum)
- License: MIT, Copyright (c) 0xProbabillity.
- Used: API shape of `ColorMath` (hex <-> RGB helpers, Kelvin <-> mired helpers) and the provider abstraction idea (`DeviceService` -> `LightProvider`). No code copied verbatim.
