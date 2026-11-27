---
title: Edge paths — index
status: draft
---

Lexical path algebra, all landing inside the root:

- [rel](./a.md)
- [frag](a.md#frag)
- [emptyfrag](a.md#)
- [segpop](sub/../a.md)
- [dups](dir//b.md)
- [nonexistdir](x/../dir/b.md)
- [dots](a/././../dir/./b.md)
- [dotname](weird.name.md)
- [titled](dir/b.md "a title")
- [angle](<dir/b.md>)

Passthrough classes — never resolved, so their targets may be absent:

- [ext](https://example.com/p.md)
- [mail](mailto:a@b.c)
- [anchor](#top)
- [abs](/abs/p.md)
- [png](ghost.png)
- [txt](data.txt?x=1)
- [upper](a.MD)

Reference-style links:

- shortcut [r]
- full [text][r2]
- collapsed [r3][]

[r]: dir/b.md
[r2]: a.md#sec
[r3]: weird.name.md

A footnote is not a link, but a link inside footnote text is one.[^n]

[^n]: see [deep](dir/b.md).

Bracket text that is NOT a link — inside inline code `[x](inline-fake.md)`,
inside a fenced block:

```md
[x](fenced-fake.md)
[y](fenced-fake2.md)
```

inside an indented block:

    [x](indented-fake.md)

and inside comments <!-- [x](comment-fake.md) --> including
multi-line ones:

<!--
[x](comment-fake2.md)
-->
