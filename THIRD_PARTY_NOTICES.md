# Third-Party Notices

## CodexBar

This project adapts the persistent refresh interaction pattern from
[CodexBar](https://github.com/steipete/CodexBar), audited at commit
[`c61e01e774c449b06324a1cc260af7c77cf17d47`](https://github.com/steipete/CodexBar/commit/c61e01e774c449b06324a1cc260af7c77cf17d47).

MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## ChatGPT / OpenAI provider mark

`assets/openai-knot-menu.png` is the flat menu icon from OpenAI's installed
ChatGPT application (`chatgptTemplate@2x.png`). The app renders its alpha mask
in white as the Codex provider identifier. ChatGPT and OpenAI marks belong
to OpenAI.

## Antigravity / Google product mark

The Antigravity mark in `assets/antigravity-menu.png` is used solely to
identify the Antigravity quota provider. It was derived from the installed
Antigravity IDE's dark-background mark with the background removed.
Antigravity and its product marks belong to Google LLC. This project is
independent and is not affiliated with or endorsed by Google.

## ZCode credential format compatibility

The local read-only ZCode credential reader implements compatibility with
ZCode's published `enc:v1` credential format in Swift. The format details were
adapted from the official [ZCode credential cipher provider](https://github.com/zai-org/ZCode/blob/main/packages/services/src/credential/providers/credentialCipherProvider.ts)
and [ZCode CLI credential cipher](https://github.com/zai-org/ZCode/blob/main/apps/zcode-cli/packages/adapters/src/auth/credential-cipher.ts).
The upstream project is Copyright 2026 Z.AI Co., Ltd. and licensed under the
Apache License, Version 2.0. The complete upstream license text is included in
[`licenses/ZCode-Apache-2.0.txt`](licenses/ZCode-Apache-2.0.txt). The local
reader changes the implementation for bounded, owner-private file access and
in-memory read-only decoding; it does not include the ZCode application or
perform ZCode credential refresh, account mutation, or reset redemption.
