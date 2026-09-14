# Third-party software

HotPl8 invokes separately installed provider tools. It does not redistribute their binaries or account data.

| Component | Purpose | License/source |
|---|---|---|
| claude-swap | Claude account inventory and native switching/run commands | MIT; [upstream](https://github.com/realiti4/claude-swap) |
| Codex CLI | Native account authentication, quota RPC, and launches | [upstream license](https://github.com/openai/codex/blob/main/LICENSE) |
| Claude Code | Native Claude authentication and inference | [provider terms](https://code.claude.com/docs/en/legal-and-compliance) |
| PowerShell | Runtime | [upstream](https://github.com/PowerShell/PowerShell) |

Provider terms apply independently of HotPl8's MIT license. Development tools are not shipped in the runtime archive. Any future copied/vendor source must include its original license and required notices. Review provenance before the first public release.

## Terminal Nyan Cat

The compact animation in data/nyan-frames.json is adapted from [klange/nyancat](https://github.com/klange/nyancat), src/animation.c, retrieved 2026-09-13. Source SHA-256: `643ec750c8ce4b97a0eae55becca0cd43bed45427912a8be1ff63bb6fd01c510`. The original character is credited by upstream to Christopher Torres (prguitarman). No music is included. Cropping, sampling and the HotPl8 renderer are local adaptations.

Upstream NCSA license notice (retained verbatim):

```text
Copyright (c) 2011-2018 K. Lange.  All rights reserved.

Developed by:            K. Lange
                         http://github.com/klange/nyancat
                         http://nyancat.dakko.us

40-column support by:    Peter Hazenberg
                         http://github.com/Peetz0r/nyancat
                         http://peter.haas-en-berg.nl

Build tools unified by:  Aaron Peschel
                         https://github.com/apeschel

For a complete listing of contributors, please see the git commit history.

This is a simple telnet server / standalone application which renders the
classic Nyan Cat (or "poptart cat") to your terminal.

It makes use of various ANSI escape sequences to render color, or in the case
of a VT220, simply dumps text to the screen.

For more information, please see:

    http://nyancat.dakko.us

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal with the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
  1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimers.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimers in the
     documentation and/or other materials provided with the distribution.
  3. Neither the names of the Association for Computing Machinery, K.
     Lange, nor the names of its contributors may be used to endorse
     or promote products derived from this Software without specific prior
     written permission.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
WITH THE SOFTWARE.
```
