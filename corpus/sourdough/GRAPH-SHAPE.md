# Graph shape: sparse linear sourdough sequence

- Root count: 1 (`index`).
- Page count: 10.
- Maximum depth: 9 edges, counting the root as depth 0.
- Fanout: strict chain; 9 pages have exactly one child and the final page is the only leaf, so maximum fanout is 1.
- Internal link density: 6 internal `.md` links across 10 pages, approximately 0.60 links per page.
- Cross-subtree links: none in the strict sense because the parent forest is a single chain and has no sibling subtrees. One non-forward link goes from `troubleshooting` back to its ancestor `bulk-fermentation`.
- Fragment usage: sparse; 2 of the 6 internal links use the fragment `#reading-the-dough`. No fragment targets are validated.

A beginner sourdough loaf naturally produces this shape because the work is a time-ordered pipeline rather than a branching reference taxonomy. The starter must be active before ingredients are mixed, mixing precedes bulk fermentation, fermentation determines shaping behavior, shaping precedes proofing, and proofing precedes baking and storage. Later steps cannot usefully be rearranged into a wide tree without obscuring the dependency that each stage sets the conditions for the next. The few inline links exist only where a reader needs to move to the next stage or revisit a fermentation cue; the parent chain already carries nearly all navigation, making the site a deliberately low-graphiness fixture.
