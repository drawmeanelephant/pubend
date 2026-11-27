# GRAPH-SHAPE: conifers

- Shape assignment: 1, deep strict hierarchy, sparse links.
- Root count: 1 (`index`).
- Page count: 26.
- Max depth: 4, with `index` at depth 0 and variety pages at depth 4.
- Depth distribution: 1 page at depth 0, 3 at depth 1, 8 at depth 2, 11 at depth 3, and 3 at depth 4.
- Fanout: 25 parent-child edges; mean fanout is 0.96 across all pages and 1.79 across the 14 branch pages; maximum fanout is 4 at `pinaceae`; most internal nodes have only 1-2 children.
- Link density: 28 internal `.md` links, approximately 1.08 links per page. Twenty-five links point from a parent page to a direct child, and 3 variety pages link back to their direct parent species, so the explicit link web coincides with the parent forest rather than forming an independent web.
- Cross-subtree links: none. There are also no sibling-to-sibling links; all internal page links connect direct parent-child pairs.
- Fragment usage: 3 links carry the fragment `#field-marks`, all pointing to child variety accounts. Fragments are incidental section references and are not needed for the topology.

A taxonomic field guide naturally produces this shape because biological nomenclature is itself a nested containment system: family contains genus, genus contains species, and species may contain regional varieties. A reader using the guide is expected to narrow identification one level at a time rather than jump laterally between unrelated taxa, so downward explanatory links are useful while a dense cross-link web would misrepresent the structure of the subject. Low fanout follows from treating a selective set of Pacific Northwest conifers rather than attempting exhaustive coverage of every genus and species.
