# Third-party notices (YeelightKit)

## python-yeelight

The per-model colour-temperature ranges in `Sources/YeelightCodec/YeelightModels.swift`
(`YeelightModelSpec.table`) and the light-kind detection order (support list, then property
heuristic) are taken from `_MODEL_SPECS` / `Bulb.bulb_type` in python-yeelight
(https://gitlab.com/stavros/python-yeelight, GitHub mirror skorokithakis/python-yeelight).
No code was copied; the facts were re-expressed in Swift.

```
Copyright (c) 2016, Stavros Korokithakis
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Yeelight Inter-Operation Specification

Wire format (SSDP search/response, JSON-RPC methods and parameter ranges, `props`
notifications) follows Yeelight's published "Yeelight WiFi Light Inter-Operation
Specification". No text or code was copied.

## ahmetcanaltun/YeelightKit

Evaluated (MIT, see README "Reuse evaluation"); no code copied. This package is an
independent implementation.
