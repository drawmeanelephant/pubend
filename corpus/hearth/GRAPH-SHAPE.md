# Graph Shape Manifest — hearth

- **Assigned shape:** #3, multi-root forest
- **Topic:** *Hearth & Hand*, a practical household craft compendium covering textiles, woodshop work, food preservation, and functional ceramics
- **Roots:** 4 — `ceramics`, `pantry`, `textiles`, and `woodshop`
- **Page count:** 28
- **Maximum depth:** 3, reached along `textiles` → `textiles/dyeing` → `textiles/dyeing/mordants` → `textiles/dyeing/mordants/alum` or `iron`
- **Fanout:** maximum fanout 4; mean nonzero fanout 2.67. Root fanouts are `ceramics` 4, `pantry` 3, `textiles` 4, and `woodshop` 4. Interior branch fanout is otherwise small: dyeing 2, mordants 2, fermentation 2, joinery 2, and glazes 1; 19 of 28 pages are leaves.
- **Link density:** 86 internal `.md` links across 28 pages, approximately 3.07 links per page. 79 links stay within their subtree.
- **Cross-subtree links:** 7. They connect ceramic functional forms with pantry fermentation crocks, ceramic ash glaze with textile dyeing, textile mending with woodshop finishes, and woodshop joinery with pantry drying.
- **Fragment usage:** 3 internal links carry `#fragment` suffixes. They are used for process-specific sections such as refreshing an indigo vat, shelf-processing sauerkraut, and reading kiln behavior; per v0 the fragment existence is intentionally outside validation.

This topic naturally produces a multi-root forest because the four craft collections are independent bodies of practice rather than chapters of one sequential manual. A reader can begin in textiles, woodworking, preservation, or ceramics without needing the others, and each collection has its own progression from orientation through equipment, process, and specialized techniques. The parent forest therefore follows disciplinary boundaries and skill prerequisites. At the same time, a working household does not keep those disciplines perfectly separate: wooden racks support food drying, finishes affect textile tools, ceramic vessels enable fermentation, and wood ash connects glaze chemistry to older dye practices. Those material dependencies create a small number of meaningful cross-subtree links without collapsing the four collections into one hierarchy.
