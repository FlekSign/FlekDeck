# Third-Party Notices

FlekDeck includes software developed by third parties. Each component
remains subject to its respective copyright and license terms.

## LiveContainer

Project: https://github.com/LiveContainer/LiveContainer  
License: [GNU Affero General Public License v3.0](./LICENSE)

FlekDeck is a modified version of LiveContainer.

Existing copyright, authorship, and license notices from the original
LiveContainer source code have been retained.

## Dragula

Project: https://github.com/mufasaYC/Dragula  
Author: Mustafa Yusuf  
License: MIT License

### MIT License

Copyright (c) 2025 Mustafa Yusuf

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the “Software”),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

## StikJIT

Project: https://github.com/StikDebug/StikJIT  
License: [Mozilla Public License 2.0](https://github.com/StikDebug/StikJIT/blob/main/LICENSE)

FlekDeck includes StikJIT as a compiled framework, unmodified, to enable
JIT for the apps it runs. Its source code is available at the project
address above. StikJIT is brought in through the LiveContainer project,
together with the code that runs it.

The JIT scripts inside the framework, `universal.js` and `legacy.js`,
come from [StikDebug](https://github.com/StikDebug/StikDebug) and are
licensed under the
[GNU Affero General Public License v3.0](https://github.com/StikDebug/StikDebug/blob/main/LICENSE).

## idevice

Project: https://github.com/jkcoxson/idevice  
Author: Jackson Coxson  
License: MIT License

idevice is compiled into StikJIT, and its pairing functions into
`IdevicePairing.dylib`, with which FlekDeck creates a pairing file on the
device. `IdevicePairing/build.sh` builds that library from the copy of
idevice in the StikJIT repository.

### MIT License

Copyright 2026 Jackson Coxson

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the “Software”),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

## LocalDevVPN

Project: https://github.com/jkcoxson/LocalDevVPN (formerly
[StosVPN](https://github.com/SideStore/StosVPN))  
Authors: SideStore Team

The VPN FlekDeck provides for built-in JIT is based on the approach of
LocalDevVPN: a packet tunnel that hands every packet straight back with
its source and destination addresses exchanged. FlekDeck's tunnel was
written for FlekDeck and includes no LocalDevVPN code; it keeps
LocalDevVPN's addresses so that either VPN works with the same tools.
