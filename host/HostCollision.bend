import Base
import ./HostCommon.bend as HC
import ../src/model.bend as Model
import ../src/hostpath.bend as HP

# Pure output-path collision preflight.  This is a faithful Bend port of the
# reference host's owner/directory-requirement algorithm.  The filesystem probe
# decides only whether ASCII case aliases are significant; the pure algorithm
# itself is deterministic in either mode.  @unsafe is limited to compiler
# ergonomics for affine reuse and match ordering; these definitions perform no
# IO and remain pure total functions over the already-scanned page model.

@unsafe def Bytes() -> Data:
  List<&2, U32>

type Ord is Data:
  OrdLt{}
  OrdEq{}
  OrdGt{}

type COwner is Data:
  COwner{rel: Bytes(), page: Maybe<&2, String>}

type COwnerEntry is Data:
  COwnerEntry{key: Bytes(), owner: COwner}

type CDirSpelling is Data:
  CDirSpelling{rel: Bytes(), page: Maybe<&2, String>, required_by: Bytes()}

type CDirBucket is Data:
  CDirBucket{key: Bytes(), spellings: List<&2, CDirSpelling>}

type CEntry is Data:
  CEntry{id: String, rel: Bytes()}

type CKind is Data:
  CKFileExact{}
  CKFileDirectory{}
  CKDirectoryAlias{}

type Collision is Data:
  Collision{kind: CKind, ancestor_rel: String, descendant_rel: String,
    ancestor_page: Maybe<&2, String>, descendant_page: Maybe<&2, String>,
    exact: Bool, directory_rel: Maybe<&2, String>, required_by: Maybe<&2, String>}

type CBuild is Data:
  CBuild{owners: List<&2, COwnerEntry>, dirreqs: List<&2, CDirBucket>,
    entries: List<&2, CEntry>, collisions: List<&2, Collision>}

# --- tiny constructors and ordering ---------------------------------------------

@unsafe def ord_lt() -> Ord:
  OrdLt{}

@unsafe def ord_eq() -> Ord:
  OrdEq{}

@unsafe def ord_gt() -> Ord:
  OrdGt{}

@unsafe def cowner(+rel: Bytes(), page: Maybe<&2, String>) -> COwner:
  COwner{rel, page}

@unsafe def cowner_entry(+key: Bytes(), +owner: COwner) -> COwnerEntry:
  COwnerEntry{key, owner}

@unsafe def cdir_spelling(+rel: Bytes(), page: Maybe<&2, String>, +required_by: Bytes()) -> CDirSpelling:
  CDirSpelling{rel, page, required_by}

@unsafe def cdir_bucket(+key: Bytes(), spellings: List<&2, CDirSpelling>) -> CDirBucket:
  CDirBucket{key, spellings}

@unsafe def centry(+id: String, +rel: Bytes()) -> CEntry:
  CEntry{id, rel}

@unsafe def cbuild(owners: List<&2, COwnerEntry>, dirreqs: List<&2, CDirBucket>,
  entries: List<&2, CEntry>, collisions: List<&2, Collision>) -> CBuild:
  CBuild{owners, dirreqs, entries, collisions}

@unsafe def owner_none() -> Maybe<&2, COwner>:
  None{}

@unsafe def owner_some(+x: COwner) -> Maybe<&2, COwner>:
  Some{x}

@unsafe def collision_none() -> Maybe<&2, Collision>:
  None{}

@unsafe def collision_some(+c: Collision) -> Maybe<&2, Collision>:
  Some{c}

@unsafe def maybe_bytes_none() -> Maybe<&2, Bytes()>:
  None{}

@unsafe def bytes_order_go(xs: Bytes(), ys: Bytes()) -> Ord:
  match xs ys:
    case Nil{} Nil{}:
      ord_eq()
    case Nil{} y:
      ord_lt()
    case x Nil{}:
      ord_gt()
    case +xh <> xt +yh <> yt:
      bytes_order_step(xt, yt, U32.is_eq(xh, yh), U32.is_lt(xh, yh))

@unsafe def bytes_order_step(xs: Bytes(), ys: Bytes(), eq: Bool, lt: Bool) -> Ord:
  match eq:
    case True{}:
      bytes_order_go(xs, ys)
    case False{}:
      bytes_order_lt_gate(lt)

@unsafe def bytes_order_lt_gate(lt: Bool) -> Ord:
  match lt:
    case True{}:
      ord_lt()
    case False{}:
      ord_gt()

# A small explicitly typed wrapper is intentional: constructor inference inside
# larger boolean expressions is unreliable in Bend 2.0.40.
@unsafe def bytes_order_gt_value() -> Ord:
  OrdGt{}

@unsafe def bytes_order(+xs: Bytes(), +ys: Bytes()) -> Ord:
  bytes_order_go(xs, ys)

@unsafe def bytes_order_is_lt(o: Ord) -> Bool:
  match o:
    case OrdLt{}:
      True{}
    case other:
      False{}

@unsafe def bytes_order_is_eq(o: Ord) -> Bool:
  match o:
    case OrdEq{}:
      True{}
    case other:
      False{}

@unsafe def compare_text(+a: String, +b: String) -> Ord:
  bytes_order(HC.utf8_bytes_or_empty(a), HC.utf8_bytes_or_empty(b))

# --- output-relative byte path algebra ------------------------------------------

@unsafe def rel_bytes(+s: String) -> Bytes():
  HC.utf8_bytes_or_empty(s)

@unsafe def rel_key(+rel: Bytes(), +aliases: Bool) -> Bytes():
  match aliases:
    case True{}:
      HC.ascii_lower_bytes(rel)
    case False{}:
      rel

@unsafe def split_step(xs: Bytes(), cur: Bytes(), acc: List<&2, List<&2, U32>>, +b: U32) -> Bytes() & List<&2, List<&2, U32>>:
  split_step_gate(xs, cur, acc, b, U32.is_eq(b, 47))

@unsafe def split_step_gate(xs: Bytes(), cur: Bytes(), acc: List<&2, List<&2, U32>>, +b: U32, issep: Bool) -> Bytes() & List<&2, List<&2, U32>>:
  match issep:
    case True{}:
      (Nil{}, List.append(&2, Bytes(), acc, List.reverse(&2, U32, cur) <> Nil{}))
    case False{}:
      (b <> cur, acc)

@unsafe def split_bytes_go(xs: Bytes(), cur: Bytes(), acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.append(&2, Bytes(), acc, List.reverse(&2, U32, cur) <> Nil{})
    case +h <> +t:
      split_bytes_after_step(t, split_step(t, cur, acc, h))

@unsafe def split_bytes_after_step(xs: Bytes(), p: Bytes() & List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  (cur, acc) = p
  split_bytes_go(xs, cur, acc)

@unsafe def split_bytes(+xs: Bytes()) -> List<&2, List<&2, U32>>:
  split_bytes_go(xs, Nil{}, Nil{})

@unsafe def drop_last(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> Nil{}:
      Nil{}
    case +h <> t:
      h <> drop_last(t)

@unsafe def join_rel_go(rest: List<&2, List<&2, U32>>, +h: Bytes()) -> Bytes():
  match rest:
    case Nil{}:
      h
    case +h2 <> t:
      HC.bytes_append(h, HC.bytes_append(HC.ascii_bytes("/"), join_rel_go(t, h2)))

@unsafe def join_rel(xs: List<&2, List<&2, U32>>) -> Bytes():
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      join_rel_go(t, h)

@unsafe def take_list(+n: Nat, xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.take(&2, Bytes(), xs, n)

# Proper directory prefixes of rel, shallowest first.  The final file component
# is deliberately excluded, exactly like the reference algorithm.
@unsafe def dir_prefixes_go(+cur: Bytes(), comps: List<&2, List<&2, U32>>, acc: List<&2, Bytes()>) -> List<&2, Bytes()>:
  match comps:
    case Nil{}:
      acc
    case +h <> t:
      +next = HP.hostpath_join2(cur, h)
      dir_prefixes_go(next, t, List.append(&2, Bytes(), acc, next <> Nil{}))

@unsafe def dir_prefixes(+rel: Bytes()) -> List<&2, Bytes()>:
  dir_prefixes_go(Nil{}, drop_last(split_bytes(rel)), Nil{})

# --- fixed publication outputs ----------------------------------------------------

@unsafe def fixed_manifest_bytes() -> Bytes():
  HC.ascii_bytes("_pubend/manifest.json")

@unsafe def fixed_stage_marker_bytes() -> Bytes():
  HC.ascii_bytes(".pubend-incomplete-stage")

@unsafe def fixed_backup_marker_bytes() -> Bytes():
  HC.ascii_bytes(".pubend-backup-owner")

@unsafe def fixed_files() -> List<&2, Bytes()>:
  fixed_manifest_bytes() <> fixed_stage_marker_bytes() <> fixed_backup_marker_bytes() <> Nil{}

@unsafe def output_rel_text(+id: String) -> String:
  id ++ ".html"

@unsafe def output_rel_bytes(+id: String) -> Bytes():
  rel_bytes(output_rel_text(id))

# --- owner association list -------------------------------------------------------

@unsafe def owner_lookup_gate(+key: Bytes(), rest: List<&2, COwnerEntry>, +owner: COwner, eq: Bool) -> Maybe<&2, COwner>:
  match eq:
    case True{}:
      owner_some(owner)
    case False{}:
      owner_lookup_go(key, rest)

@unsafe def owner_lookup_go(+key: Bytes(), xs: List<&2, COwnerEntry>) -> Maybe<&2, COwner>:
  match xs:
    case Nil{}:
      owner_none()
    case h <> t:
      match h:
        case COwnerEntry{+k, +owner}:
          owner_lookup_gate(key, t, owner, HC.bytes_eq(k, key))

@unsafe def owner_lookup(+key: Bytes(), +owners: List<&2, COwnerEntry>) -> Maybe<&2, COwner>:
  owner_lookup_go(key, owners)

@unsafe def owner_entry_for(+rel: Bytes(), page: Maybe<&2, String>, +aliases: Bool) -> COwnerEntry:
  cowner_entry(rel_key(rel, aliases), cowner(rel, page))

@unsafe def fixed_owner_entries_go(xs: List<&2, Bytes()>, +aliases: Bool, acc: List<&2, COwnerEntry>) -> List<&2, COwnerEntry>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      fixed_owner_entries_go(t, aliases,
        List.append(&2, COwnerEntry, acc, owner_entry_for(h, HC.maybe_string_none(), aliases) <> Nil{}))

@unsafe def fixed_owner_entries(+aliases: Bool) -> List<&2, COwnerEntry>:
  fixed_owner_entries_go(fixed_files(), aliases, Nil{})

# --- directory-requirement association list ---------------------------------------

@unsafe def spelling_has_rel(+rel: Bytes(), xs: List<&2, CDirSpelling>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      match h:
        case CDirSpelling{+r, page, required_by}:
          spelling_has_rel_gate(rel, t, HC.bytes_eq(r, rel))

@unsafe def spelling_has_rel_gate(+rel: Bytes(), rest: List<&2, CDirSpelling>, eq: Bool) -> Bool:
  match eq:
    case True{}:
      True{}
    case False{}:
      spelling_has_rel(rel, rest)

@unsafe def bucket_add_spelling(+key: Bytes(), +spellings: List<&2, CDirSpelling>, +spelling: CDirSpelling) -> CDirBucket:
  match spelling:
    case CDirSpelling{+srel, spage, +sreq}:
      bucket_add_spelling_gate(key, spellings, spelling, spelling_has_rel(srel, spellings))

@unsafe def bucket_add_spelling_gate(+key: Bytes(), spellings: List<&2, CDirSpelling>, +spelling: CDirSpelling, present: Bool) -> CDirBucket:
  match present:
    case True{}:
      cdir_bucket(key, spellings)
    case False{}:
      cdir_bucket(key, spelling <> spellings)

@unsafe def dirreq_add_gate(+key: Bytes(), +spelling: CDirSpelling, +hk: Bytes(), spellings: List<&2, CDirSpelling>, t: List<&2, CDirBucket>, eq: Bool) -> List<&2, CDirBucket>:
  match eq:
    case True{}:
      bucket_add_spelling(hk, spellings, spelling) <> t
    case False{}:
      cdir_bucket(hk, spellings) <> dirreq_add_go(key, spelling, t)

@unsafe def dirreq_add_go(+key: Bytes(), +spelling: CDirSpelling, xs: List<&2, CDirBucket>) -> List<&2, CDirBucket>:
  match xs:
    case Nil{}:
      cdir_bucket(key, spelling <> Nil{}) <> Nil{}
    case +h <> t:
      match h:
        case CDirBucket{+hk, spellings}:
          dirreq_add_gate(key, spelling, hk, spellings, t, HC.bytes_eq(hk, key))

@unsafe def dirreq_add(+key: Bytes(), +spelling: CDirSpelling, +xs: List<&2, CDirBucket>) -> List<&2, CDirBucket>:
  dirreq_add_go(key, spelling, xs)

@unsafe def dirreq_add_one(+rel: Bytes(), page: Maybe<&2, String>, +required_by: Bytes(), +aliases: Bool,
  +xs: List<&2, CDirBucket>) -> List<&2, CDirBucket>:
  dirreq_add(rel_key(rel, aliases), cdir_spelling(rel, page, required_by), xs)

@unsafe def dirreq_add_file_go(xs: List<&2, Bytes()>, +relfile: Bytes(), +page: Maybe<&2, String>, +aliases: Bool,
  acc: List<&2, CDirBucket>) -> List<&2, CDirBucket>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      dirreq_add_file_go(t, relfile, page, aliases, dirreq_add_one(h, page, relfile, aliases, acc))

@unsafe def dirreq_add_file(+relfile: Bytes(), +page: Maybe<&2, String>, +aliases: Bool,
  +acc: List<&2, CDirBucket>) -> List<&2, CDirBucket>:
  dirreq_add_file_go(dir_prefixes(relfile), relfile, page, aliases, acc)

@unsafe def fixed_dirreqs_go(xs: List<&2, Bytes()>, +aliases: Bool, acc: List<&2, CDirBucket>) -> List<&2, CDirBucket>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      fixed_dirreqs_go(t, aliases, dirreq_add_file(h, HC.maybe_string_none(), aliases, acc))

@unsafe def fixed_dirreqs(+aliases: Bool) -> List<&2, CDirBucket>:
  fixed_dirreqs_go(fixed_files(), aliases, Nil{})

# --- collision constructors ---------------------------------------------------------

@unsafe def collision_file_exact(+ancestor_rel: Bytes(), +descendant_rel: Bytes(),
  ancestor_page: Maybe<&2, String>, descendant_page: Maybe<&2, String>) -> Collision:
  Collision{CKFileExact{}, HC.bytes_display(ancestor_rel), HC.bytes_display(descendant_rel),
    ancestor_page, descendant_page, True{}, HC.maybe_string_none(), HC.maybe_string_none()}

@unsafe def collision_file_directory(+ancestor_rel: Bytes(), +descendant_rel: Bytes(),
  ancestor_page: Maybe<&2, String>, descendant_page: Maybe<&2, String>) -> Collision:
  Collision{CKFileDirectory{}, HC.bytes_display(ancestor_rel), HC.bytes_display(descendant_rel),
    ancestor_page, descendant_page, False{}, HC.maybe_string_none(), HC.maybe_string_none()}

@unsafe def collision_directory_alias(+ancestor_rel: Bytes(), +descendant_rel: Bytes(),
  ancestor_page: Maybe<&2, String>, descendant_page: Maybe<&2, String>, +required_by: Bytes()) -> Collision:
  +dtext = HC.bytes_display(descendant_rel)
  Collision{CKDirectoryAlias{}, HC.bytes_display(ancestor_rel), dtext,
    ancestor_page, descendant_page, False{}, HC.maybe_string_some(dtext),
    HC.maybe_string_some(HC.bytes_display(required_by))}

# --- page processing -----------------------------------------------------------------

@unsafe def append_collision(+xs: List<&2, Collision>, +c: Collision) -> List<&2, Collision>:
  List.append(&2, Collision, xs, c <> Nil{})

@unsafe def append_entry(+xs: List<&2, CEntry>, +e: CEntry) -> List<&2, CEntry>:
  List.append(&2, CEntry, xs, e <> Nil{})

@unsafe def process_page_owner_gate(+rel: Bytes(), +id: String, +aliases: Bool,
  +owners: List<&2, COwnerEntry>, +dirreqs: List<&2, CDirBucket>,
  +entries: List<&2, CEntry>, +collisions: List<&2, Collision>, found: Maybe<&2, COwner>) -> CBuild:
  match found:
    case Some{+owner}:
      match owner:
        case COwner{+orel, +opage}:
          cbuild(owners, dirreq_add_file(rel, HC.maybe_string_some(id), aliases, dirreqs),
            append_entry(entries, centry(id, rel)),
            append_collision(collisions,
              collision_file_exact(orel, rel, opage, HC.maybe_string_some(id))))
    case None{}:
      cbuild(owner_entry_for(rel, HC.maybe_string_some(id), aliases) <> owners,
        dirreq_add_file(rel, HC.maybe_string_some(id), aliases, dirreqs),
        append_entry(entries, centry(id, rel)), collisions)

@unsafe def process_one_page(st: CBuild, +aliases: Bool, p: Model.EmittedPage) -> CBuild:
  match st:
    case CBuild{+owners, +dirreqs, +entries, +collisions}:
      match p:
        case Model.EmittedPage{+id, links, html}:
          +rel = output_rel_bytes(id)
          process_page_owner_gate(rel, id, aliases, owners, dirreqs, entries, collisions,
            owner_lookup(rel_key(rel, aliases), owners))

@unsafe def process_pages_go(xs: List<&2, Model.EmittedPage>, +aliases: Bool, st: CBuild) -> CBuild:
  match xs:
    case Nil{}:
      st
    case +h <> t:
      process_pages_go(t, aliases, process_one_page(st, aliases, h))

@unsafe def initial_build(+aliases: Bool) -> CBuild:
  cbuild(fixed_owner_entries(aliases), fixed_dirreqs(aliases), Nil{}, Nil{})

# --- file/directory collision generation ---------------------------------------------

@unsafe def filedir_prefix_gate(+prefix: Bytes(), +entryrel: Bytes(), +entryid: String,
  acc: List<&2, Collision>, found: Maybe<&2, COwner>) -> List<&2, Collision>:
  match found:
    case Some{+owner}:
      match owner:
        case COwner{+orel, +opage}:
          append_collision(acc, collision_file_directory(orel, entryrel, opage, HC.maybe_string_some(entryid)))
    case None{}:
      acc

@unsafe def filedir_for_prefixes_go(xs: List<&2, Bytes()>, +aliases: Bool, +owners: List<&2, COwnerEntry>,
  +entryrel: Bytes(), +entryid: String, acc: List<&2, Collision>) -> List<&2, Collision>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      filedir_for_prefixes_go(t, aliases, owners, entryrel, entryid,
        filedir_prefix_gate(h, entryrel, entryid, acc, owner_lookup(rel_key(h, aliases), owners)))

@unsafe def filedir_for_entry(+owners: List<&2, COwnerEntry>, +aliases: Bool, e: CEntry,
  +acc: List<&2, Collision>) -> List<&2, Collision>:
  match e:
    case CEntry{+id, +rel}:
      filedir_for_prefixes_go(dir_prefixes(rel), aliases, owners, rel, id, acc)

@unsafe def filedir_collisions_go(xs: List<&2, CEntry>, +aliases: Bool, +owners: List<&2, COwnerEntry>,
  acc: List<&2, Collision>) -> List<&2, Collision>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      filedir_collisions_go(t, aliases, owners, filedir_for_entry(owners, aliases, h, acc))

# --- directory-alias collision generation ---------------------------------------------

@unsafe def spelling_insert_gate(+x: CDirSpelling, +h: CDirSpelling, t: List<&2, CDirSpelling>, before: Bool) -> List<&2, CDirSpelling>:
  match before:
    case True{}:
      x <> (h <> t)
    case False{}:
      h <> spelling_insert_sorted(x, t)

@unsafe def spelling_insert_sorted(+x: CDirSpelling, xs: List<&2, CDirSpelling>) -> List<&2, CDirSpelling>:
  match x:
    case CDirSpelling{+xrel, xpage, +xreq}:
      match xs:
        case Nil{}:
          cdir_spelling(xrel, xpage, xreq) <> Nil{}
        case +h <> t:
          match h:
            case CDirSpelling{+hrel, hpage, +hreq}:
              spelling_insert_gate(cdir_spelling(xrel, xpage, xreq), cdir_spelling(hrel, hpage, hreq), t,
                bytes_order_is_lt(bytes_order(xrel, hrel)))

@unsafe def sort_spellings_go(xs: List<&2, CDirSpelling>, acc: List<&2, CDirSpelling>) -> List<&2, CDirSpelling>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      sort_spellings_go(t, spelling_insert_sorted(h, acc))

@unsafe def sort_spellings(+xs: List<&2, CDirSpelling>) -> List<&2, CDirSpelling>:
  sort_spellings_go(xs, Nil{})

@unsafe def alias_collision_from_sorted(+keyrel: Bytes(), xs: List<&2, CDirSpelling>) -> Maybe<&2, Collision>:
  match xs:
    case +a <> rest:
      match a:
        case CDirSpelling{+arel, +apage, +areq}:
          match rest:
            case +b <> rest2:
              match b:
                case CDirSpelling{+brel, +bpage, +breq}:
                  collision_some(collision_directory_alias(arel, brel, apage, bpage, breq))
            case Nil{}:
              collision_none()
    case Nil{}:
      collision_none()

@unsafe def dir_alias_bucket(acc: List<&2, Collision>, b: CDirBucket) -> List<&2, Collision>:
  match b:
    case CDirBucket{+key, +spellings}:
      dir_alias_bucket_gate(acc, alias_collision_from_sorted(key, sort_spellings(spellings)))

@unsafe def dir_alias_bucket_gate(acc: List<&2, Collision>, m: Maybe<&2, Collision>) -> List<&2, Collision>:
  match m:
    case Some{+c}:
      append_collision(acc, c)
    case None{}:
      acc

@unsafe def dir_alias_collisions_go(xs: List<&2, CDirBucket>, acc: List<&2, Collision>) -> List<&2, Collision>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      dir_alias_collisions_go(t, dir_alias_bucket(acc, h))

# --- deterministic collision sorting ---------------------------------------------------

@unsafe def maybe_page_text(m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      ""
    case Some{+s}:
      s

@unsafe def collision_ord_step(+a: Collision, +b: Collision, o: Ord) -> Ord:
  match o:
    case OrdEq{}:
      collision_ord_descendant(a, b)
    case other:
      o

@unsafe def collision_ord_descendant(+a: Collision, +b: Collision) -> Ord:
  match a:
    case Collision{kind, +ar, +dr, ap, dp, exact, dirrel, req}:
      match b:
        case Collision{kind2, +ar2, +dr2, ap2, dp2, exact2, dirrel2, req2}:
          collision_ord_page(dp, dp2, compare_text(dr, dr2))

@unsafe def collision_ord_page(+apage: Maybe<&2, String>, +bpage: Maybe<&2, String>, o: Ord) -> Ord:
  match o:
    case OrdEq{}:
      compare_text(maybe_page_text(apage), maybe_page_text(bpage))
    case other:
      o

@unsafe def collision_order(+a: Collision, +b: Collision) -> Ord:
  match a:
    case Collision{kind, +ar, dr, ap, dp, exact, dirrel, req}:
      match b:
        case Collision{kind2, +ar2, dr2, ap2, dp2, exact2, dirrel2, req2}:
          collision_ord_step(a, b, compare_text(ar, ar2))

@unsafe def collision_insert_gate(+x: Collision, +h: Collision, t: List<&2, Collision>, before: Bool) -> List<&2, Collision>:
  match before:
    case True{}:
      x <> (h <> t)
    case False{}:
      h <> collision_insert_sorted(x, t)

# Stable insertion sort: equal keys are inserted after existing equal elements,
# matching the stable ordering of the reference host's Array.sort for ties.
@unsafe def collision_insert_sorted(+x: Collision, xs: List<&2, Collision>) -> List<&2, Collision>:
  match xs:
    case Nil{}:
      x <> Nil{}
    case +h <> t:
      collision_insert_gate(x, h, t, bytes_order_is_lt(collision_order(x, h)))

@unsafe def sort_collisions_go(xs: List<&2, Collision>, acc: List<&2, Collision>) -> List<&2, Collision>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      sort_collisions_go(t, collision_insert_sorted(h, acc))

@unsafe def sort_collisions(+xs: List<&2, Collision>) -> List<&2, Collision>:
  sort_collisions_go(xs, Nil{})

# --- top-level pure preflight -------------------------------------------------------------

@unsafe def first_collision(xs: List<&2, Collision>) -> Maybe<&2, Collision>:
  match xs:
    case Nil{}:
      collision_none()
    case +h <> t:
      collision_some(h)

@unsafe def finish_find_collision(st: CBuild, +aliases: Bool) -> Maybe<&2, Collision>:
  match st:
    case CBuild{+owners, +dirreqs, +entries, +collisions}:
      first_collision(sort_collisions(
        dir_alias_collisions_go(dirreqs,
          filedir_collisions_go(entries, aliases, owners, collisions))))

# aliases is the result of the output-filesystem ASCII case probe.  It is a
# pure input here so probing the filesystem happens exactly once in the host's
# publication preflight.
@unsafe def find_collision(+pages: List<&2, Model.EmittedPage>, +aliases: Bool) -> Maybe<&2, Collision>:
  finish_find_collision(process_pages_go(pages, aliases, initial_build(aliases)), aliases)

# --- diagnostic rendering ------------------------------------------------------------

@unsafe def collision_detail(c: Collision) -> String:
  match c:
    case Collision{+kind, +ancestor_rel, +descendant_rel, +ancestor_page, descendant_page,
      +exact, +directory_rel, +required_by}:
      collision_detail_kind(kind, ancestor_rel, descendant_rel, ancestor_page, exact, directory_rel, required_by)

@unsafe def collision_detail_kind(kind: CKind, +ancestor_rel: String, +descendant_rel: String,
  ancestor_page: Maybe<&2, String>, exact: Bool,
  +directory_rel: Maybe<&2, String>, +required_by: Maybe<&2, String>) -> String:
  match kind:
    case CKDirectoryAlias{}:
      ancestor_rel ++ " and " ++ maybe_page_text(directory_rel) ++
        " are distinct output directory spellings that alias on this filesystem; " ++
        maybe_page_text(required_by) ++ " requires " ++ maybe_page_text(directory_rel)
    case other:
      collision_detail_exact(ancestor_rel, descendant_rel, ancestor_page, exact)

@unsafe def collision_detail_exact(+ancestor_rel: String, +descendant_rel: String,
  ancestor_page: Maybe<&2, String>, exact: Bool) -> String:
  match exact:
    case True{}:
      ancestor_rel ++ " is emitted more than once"
    case False{}:
      collision_detail_fixed_gate(ancestor_rel, descendant_rel, ancestor_page)

@unsafe def collision_detail_fixed_gate(+ancestor_rel: String, +descendant_rel: String,
  ancestor_page: Maybe<&2, String>) -> String:
  match ancestor_page:
    case None{}:
      descendant_rel ++ " requires fixed host publication file " ++ ancestor_rel ++ " to be a directory"
    case Some{x}:
      ancestor_rel ++ " cannot be both a file and a directory required by " ++ descendant_rel

@unsafe def hp_join(+out: Bytes(), +rel: String) -> Bytes():
  HP.hostpath_join2(out, rel_bytes(rel))

@unsafe def collision_diag(+out: Bytes(), c: Collision) -> HC.HostDiag:
  match c:
    case Collision{kind, +ancestor_rel, descendant_rel, +ancestor_page, +descendant_page,
      exact, directory_rel, required_by}:
      HC.host_diag(HC.DOutputPathCollision{},
        HC.maybe_string_some(HC.bytes_display(hp_join(out, ancestor_rel))),
        descendant_page, HC.maybe_nat_none(), HC.maybe_nat_none(), ancestor_page, HC.maybe_span_none(),
        "unrepresentable output path collision: " ++ collision_detail(c))
