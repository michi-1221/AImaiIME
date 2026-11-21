# Third-party notices

## Conversion model

The conversion model distributed in Releases (`model-q8_0.gguf`) is a fine-tuned
version of the following models and is licensed under CC BY-SA 4.0
(https://creativecommons.org/licenses/by-sa/4.0/).

- zenz-v3.1-small by Miwa-Keita — https://huggingface.co/Miwa-Keita/zenz-v3.1-small (CC BY-SA 4.0)
- zenz-v3.1-small is based on ku-nlp/gpt2-small-japanese-char — https://huggingface.co/ku-nlp/gpt2-small-japanese-char (CC BY-SA 4.0)

Changes: additional training to convert romaji (including typos) directly to Japanese,
and conversion to GGUF (Q8_0).

## llama.cpp

AImai IME bundles a prebuilt llama.cpp framework (release b12193,
https://github.com/ggml-org/llama.cpp), licensed under the MIT License:

```
MIT License

Copyright (c) 2023-2026 The ggml authors

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
