# Graph shape manifest — `spices`

- **Assigned shape:** #2, wide flat root with moderate links.
- **Topic:** a practical cook's spice atlas with short monographs for twenty pantry spices.
- **Root count:** 1 (`index`).
- **Page count:** 21 pages total.
- **Maximum depth:** 1; every monograph is a direct child of `index`, and no monograph has children.
- **Fanout:** `index` has exactly 20 direct children; all other pages have fanout 0.
- **Measured link density:** 54 internal `.md` links across 21 pages, approximately 2.57 internal links per page. The root contains 20 entry-index links plus one fragment self-link; monograph pages contain 33 links in total.
- **Cross-links:** there are no separate subtrees in the strict forest sense because the site has one flat root. The analogous lateral links are 32 sibling-to-sibling references between spice monographs, plus one monograph-to-root storage reference. They occur where ingredients genuinely substitute, pair, or share a technique, such as coriander pointing to cumin's blooming method and cinnamon pointing to clove infusion practice.
- **Fragment usage:** 5 internal links include fragments: links to `index.md#buying-and-storage`, `cumin.md#toasting-and-blooming`, `cloves.md#controlled-infusions`, and `vanilla.md#using-the-seeds`.

A spice reference naturally produces this shape because spices do not form a clean pedagogical or taxonomic hierarchy for cooking: black pepper, cumin, saffron, and vanilla are peers on the shelf even though botany, cuisine, and flavor chemistry connect them in many incompatible ways. A flat atlas is therefore more honest than a deep tree. The root acts as the shelf index, while the monographs need only occasional lateral references for real culinary relationships—shared blooming techniques, overlapping warm-spice flavor, or classic pairings—rather than a dense web of every possible association.
