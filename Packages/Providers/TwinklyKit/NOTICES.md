# TwinklyKit third-party notices

## xled-docs (scrool/xled-docs)

- Source: https://github.com/scrool/xled-docs (published at https://xled-docs.readthedocs.io)
- Commit: d1093df87915bb5cac67a9982ccb8895e22f8586 (2023-12-27)
- License: MIT
- Used in: `Sources/TwinklyCodec` (endpoint paths, payload fields, application codes, discovery datagram layout), `Tests/TwinklyCodecTests/Fixtures/*.json` (response examples copied from `docs/rest_api.rst`).
- Changes: protocol re-implemented in Swift. The `\x01discover` request and the `OK` reply check follow scrool/xled `discover.py` (MIT, same copyright); no code copied.

```
MIT License

Copyright (c) 2017, Pavol Babinčák

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
