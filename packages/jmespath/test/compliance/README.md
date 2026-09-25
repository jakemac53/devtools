# JMESPath compliance tests

The JSON files in this directory are the official JMESPath compliance test
suite, copied verbatim from
[jmespath/jmespath.test](https://github.com/jmespath/jmespath.test)
(`tests/*.json`) at commit `53abcc37901891cf4308fcd910eab287416c4609`
(2022-05-25).

They are exercised by `../compliance_test.dart`, which generates one test per
case.

## License

The jmespath.test repository does not contain its own license file. The tests
originate from the reference implementation,
[jmespath/jmespath.py](https://github.com/jmespath/jmespath.py), which is
distributed under the MIT License:

```
MIT License

Copyright (c) 2013 Amazon.com, Inc. or its affiliates.  All Rights Reserved

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
```
