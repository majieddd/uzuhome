# Third-party notices

uzu Home is an unofficial companion app for uzu. It is not affiliated with Mirai Tech Inc. (the makers of uzu) or with
Strata.

## uzu (MIT)

https://github.com/trymirai/uzu, by Mirai Tech Inc. and contributors.

The release bundles uzu's command-line program (`Resources/backend/engine/uzu`), built from a uzu release tag with the
patches in `backend/patches` (the server's `--context-length` and `--sessions` options, and structured output for
Qwen-style thinking models). `backend/share/hanashi` holds four of uzu's chat-format files (Qwen3.5 parsing, rendering,
tokens and the default ordering), which the converter uses to write a model's `encoding.json`. uzu's licence ships with
the app in `Resources/backend/share/licenses/uzu-LICENSE.txt`:

> MIT License
>
> Copyright (c) 2025 Mirai Tech Inc.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## lalamo (MIT)

https://github.com/trymirai/lalamo, Copyright (c) 2025 Mirai Tech Inc. Not bundled: the first conversion clones it at a
fixed commit and installs it in its own Python environment with uv. `backend/lib/convert.py` imports it. Its licence
is also in `backend/share/licenses/lalamo-LICENSE.txt`.

## Models

Mirai's catalog models download from Mirai's servers through uzu; converted models download from Hugging Face. Each
model keeps its own licence (Qwen3.5 is Apache-2.0; fine-tunes state theirs on their model pages). uzu Home includes
no model weights.

## StrataHome and Strata (MIT)

The window's look and layout come from [StrataHome](https://github.com/majieddd/stratahome) (MIT, Copyright (c) 2026
majieddd). StrataHome took its colour and type tokens, component styles and the Monitor's layout from the web app that
[Strata](https://github.com/Niko1221/Strata) serves:

> MIT License
>
> Copyright (c) 2026 Niko1221 and the Strata contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
> (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
> publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
> subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
> ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Outfit (SIL Open Font License 1.1)

The UI font, `assets/fonts/Outfit-*.ttf`, Copyright 2021 The Outfit Project Authors. The licence is in
`assets/fonts/OFL.txt`. The fonts are bundled in the app.
