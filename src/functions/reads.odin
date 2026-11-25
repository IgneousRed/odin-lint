#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "base:runtime"
import "core:odin/tokenizer"
import "core:slice"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

Read_Cache :: struct {sets: map[u64]^Read_Order, collisions: map[^Read_Order]^Read_Order}
Read_Order_Clones :: struct {sources: map[^Read_Order]^Read_Order, sets: map[u64]^Read_Order, collisions: map[^Read_Order]^Read_Order}
Read_Event_Trie :: struct {children: map[tokenizer.Pos]^Read_Event_Trie}

// Each origin has an immutable set of execution-order paths. Shared suffixes
// stay shared through forwarding and unions; no ordering alternative is dropped.
// Nil is the empty set, and terminal includes the empty path.
// Source positions already belong to the invocation's ASTs. Histories retain
// the values directly, without a back-reference into mutable interning caches.

Read_Order :: struct {terminal: bool, branches: []Read_Branch, hash: u64}

// ---------------- File ----------------

@(private = "file")
Read_Branch :: struct {position: tokenizer.Pos, next: ^Read_Order}

@(private = "file")
Read_Pair :: struct {left, right: ^Read_Order}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------


clone_read_order :: proc(source: ^Read_Order, memo: ^Read_Order_Clones, owned := false) -> ^Read_Order {
	if source == nil {return nil}
	// A caller-owned root can be shared as a whole. Indexing all descendants
	// here makes every small substitution traverse every input history. Any
	// descendant reached separately can still be copied into the result lifetime.
	if owned {memo.sources[source] = source; return source}
	if previous, found := memo.sources[source]; found {return previous}
	// Canonicalize children first. Equal retained nodes then share the same
	// suffix pointers, avoiding repeated whole-history comparisons at each root.
	branches := make([dynamic]Read_Branch, 0, len(source.branches), runtime.heap_allocator())
	defer delete(branches)
	for branch in source.branches {append(&branches, Read_Branch{branch.position, clone_read_order(branch.next, memo)})}
	for previous := memo.sets[source.hash]; previous != nil; previous = memo.collisions[previous] {
		if previous.terminal != source.terminal || len(previous.branches) != len(branches) {continue}
		equal := true
		for branch, i in branches {
			other := previous.branches[i]
			if branch.position != other.position || !read_order_equal(branch.next, other.next) {equal = false; break}
		}
		if equal {memo.sources[source] = previous; return previous}
	}
	result := new_clone(source^)
	result.branches = slice.clone(branches[:])
	memo.sources[source] = result
	if previous := memo.sets[source.hash]; previous != nil {memo.collisions[result] = previous}
	memo.sets[source.hash] = result
	return result
}

read_order_equal :: proc(left, right: ^Read_Order, memo: ^map[Read_Pair]bool = nil) -> bool {
	if left == right {return true}
	if left == nil || right == nil || left.hash != right.hash || left.terminal != right.terminal || len(left.branches) != len(right.branches) {return false}
	storage: map[Read_Pair]bool
	memo := memo
	if memo == nil {storage = make(map[Read_Pair]bool, runtime.heap_allocator()); memo = &storage}
	defer delete(storage)
	key := Read_Pair{left, right}
	if equal, found := memo^[key]; found {return equal}
	for branch, i in left.branches {
		other := right.branches[i]
		if branch.position != other.position || !read_order_equal(branch.next, other.next, memo) {memo^[key] = false; return false}
	}
	memo^[key] = true
	return true
}


join_state_reads :: proc(left: [dynamic]State_Read, right: []State_Read) -> (result: [dynamic]State_Read, changed: bool) {
	result = left
	for read in right {
		index := -1
		for previous, i in result {if previous.origin == read.origin {index = i; break}}
		order := read.order
		if index >= 0 {
			order = join_read_orders(result[index].order, order)
			if order == result[index].order {continue}
		}
		if !changed {
			result = make([dynamic]State_Read, len(left), len(left)+len(right))
			copy(result[:], left[:])
			changed = true
		}
		if index < 0 {append(&result, State_Read{read.origin, order})} else {result[index].order = order}
	}
	return
}


prefix_read_order :: proc(cache: ^Read_Cache, source: ^Read_Order, prefix: []tokenizer.Pos, position: tokenizer.Pos) -> ^Read_Order {
	order := source
	if source == nil {order = make_read_order(true, nil, cache)} else {
		memo := make(map[^Read_Order]struct {order: ^Read_Order, removed: bool}, runtime.heap_allocator())
		defer delete(memo)
		filtered, removed := filter_read_order(source, position, &memo, cache)
		order = filtered
		if removed {
			if order == nil {order = make_read_order(true, nil, cache)} else if !order.terminal {order = make_read_order(true, order.branches, cache)}
		}
	}
	order = make_read_order(false, []Read_Branch{{position, order}}, cache)
	for i := len(prefix)-1; i >= 0; i -= 1 {order = make_read_order(false, []Read_Branch{{prefix[i], order}}, cache)}
	return order
}

// Test whether any read lies in (lower, upper], without expanding the paths.
// Prefix comparisons use the same file/offset order as stored events. Once a
// prefix is strictly inside both bounds, every nonempty suffix set qualifies.
read_order_between :: proc(source: ^Read_Order, lower, upper: []tokenizer.Pos, has_lower, has_upper: bool, depth := 0, lower_cmp := 0, upper_cmp := 0) -> bool {
	if source == nil {return false}
	if has_lower && lower_cmp < 0 || has_upper && upper_cmp > 0 {return false}
	if (!has_lower || lower_cmp > 0) && (!has_upper || upper_cmp < 0) {return true}
	if source.terminal {
		above := !has_lower || lower_cmp > 0
		below := !has_upper || upper_cmp < 0 || upper_cmp == 0 && depth <= len(upper)
		if above && below {return true}
	}
	for branch in source.branches {
		lo, hi := lower_cmp, upper_cmp
		for bound, i in ([2][]tokenizer.Pos{lower, upper}) {
			if !(has_lower if i == 0 else has_upper) {continue}
			cmp := &lo if i == 0 else &hi
			if cmp^ != 0 {continue}
			if depth >= len(bound) {cmp^ = 1; continue}
			pos, limit := branch.position, bound[depth]
			if pos.file != limit.file {cmp^ = -1 if pos.file < limit.file else 1} else if pos.offset != limit.offset {cmp^ = -1 if pos.offset < limit.offset else 1}
		}
		if read_order_between(branch.next, lower, upper, has_lower, has_upper, depth+1, lo, hi) {return true}
	}
	return false
}


// Build the prefix trie of a callee's store/invocation event orders.
build_read_event_trie :: proc(facts: Procedure_Facts) -> ^Read_Event_Trie {
	if len(facts.stores) == 0 && len(facts.invocations) == 0 {return nil}
	root := new(Read_Event_Trie)

	for stored in facts.stores {add_read_event(root, stored.order[:])}
	for invocation in facts.invocations {add_read_event(root, invocation.order[:])}
	return root
}

// Keep only branches distinguishable by the callee's event orders. Once a
// branch diverges from every event prefix, every non-empty suffix compares
// identically against every event in this callee and all transitive callers.
prune_read_order :: proc(source: ^Read_Order, events: ^Read_Event_Trie) -> ^Read_Order {
	if source == nil {return nil}
	if events == nil || len(events.children) == 0 {return make_read_order(true, nil)}
	branches := make([dynamic]Read_Branch, 0, len(source.branches), runtime.heap_allocator())
	defer delete(branches)
	changed := false
	leaf: ^Read_Order
	for branch in source.branches {
		child_events, matched := events.children[branch.position]
		next: ^Read_Order
		if matched {
			next = prune_read_order(branch.next, child_events)
		} else {
			if leaf == nil {leaf = make_read_order(true, nil)}
			next = leaf
		}
		if next != branch.next {changed = true}
		append(&branches, Read_Branch{branch.position, next})
	}
	if !changed {return source}
	return make_read_order(source.terminal, branches[:])
}

// Intern only while the allocating arena is alive. Nested operation/loop
// arenas install their own cache and restore the enclosing cache before freeing.
delete_read_cache :: proc(cache: ^Read_Cache) {
	delete(cache.sets)
	delete(cache.collisions)
}

// ---------------- File ----------------

@(private = "file")
join_read_orders :: proc(left, right: ^Read_Order, memo: ^map[Read_Pair]^Read_Order = nil) -> ^Read_Order {
	if right == nil || left == right {return left}
	if left == nil {return right}
	storage: map[Read_Pair]^Read_Order
	memo := memo
	if memo == nil {storage = make(map[Read_Pair]^Read_Order, runtime.heap_allocator()); memo = &storage}
	defer delete(storage)
	key := Read_Pair{left, right}
	if previous, found := memo^[key]; found {return previous}
	branches := make([dynamic]Read_Branch, 0, len(left.branches)+len(right.branches), runtime.heap_allocator())
	defer delete(branches)
	i, j := 0, 0
	changed := right.terminal && !left.terminal
	for i < len(left.branches) || j < len(right.branches) {
		if j >= len(right.branches) {append(&branches, left.branches[i]); i += 1; continue}
		if i >= len(left.branches) {append(&branches, right.branches[j]); j += 1; changed = true; continue}
		a, b := left.branches[i], right.branches[j]
		if a.position == b.position {
			next := join_read_orders(a.next, b.next, memo)
			append(&branches, Read_Branch{a.position, next})
			changed = changed || next != a.next
			i += 1; j += 1
		} else {
			ap, bp := a.position, b.position
			same_file := raw_data(ap.file) == raw_data(bp.file) && len(ap.file) == len(bp.file) || ap.file == bp.file
			before := false
			if same_file {
				before = ap.offset < bp.offset
				if ap.offset == bp.offset {
					before = ap.line < bp.line || ap.line == bp.line && ap.column < bp.column
				}
			} else {
				before = ap.file < bp.file
			}
			if before {append(&branches, a); i += 1} else {append(&branches, b); j += 1; changed = true}
		}
	}
	result := left
	if changed {result = make_read_order(left.terminal || right.terminal, branches[:])}
	memo^[key] = result
	return result
}

// Remove paths containing a repeated call site, exactly matching the flat
// representation's recursive-prefix rule. Memoization visits a shared suffix once.
@(private = "file")
filter_read_order :: proc(source: ^Read_Order, position: tokenizer.Pos, memo: ^map[^Read_Order]struct {order: ^Read_Order, removed: bool}, cache: ^Read_Cache) -> (order: ^Read_Order, removed: bool) {
	if source == nil {return}
	if previous, found := memo^[source]; found {return previous.order, previous.removed}
	branches := make([dynamic]Read_Branch, 0, len(source.branches), runtime.heap_allocator())
	defer delete(branches)
	for branch in source.branches {
		if branch.position == position {removed = true; continue}
		next, cut := filter_read_order(branch.next, position, memo, cache)
		removed = removed || cut
		if next != nil {append(&branches, Read_Branch{branch.position, next})}
	}
	order = source
	if removed {order = make_read_order(source.terminal, branches[:], cache)}
	memo^[source] = {order, removed}
	return
}

@(private = "file")
make_read_order :: proc(terminal: bool, branches: []Read_Branch, cache: ^Read_Cache = nil) -> ^Read_Order {
	if !terminal && len(branches) == 0 {return nil}
	hash := u64(14695981039346656037) ~ u64(terminal)
	for branch in branches {
		// Hashes reject unequal sets quickly; equality always checks collisions.
		hash = (hash ~ u64(branch.position.offset))*1099511628211
		hash = (hash ~ branch.next.hash)*1099511628211
	}
	if cache != nil {
		for previous := cache.sets[hash]; previous != nil; previous = cache.collisions[previous] {
			if previous.terminal != terminal || len(previous.branches) != len(branches) {continue}
			equal := true
			for branch, i in branches {if previous.branches[i] != branch {equal = false; break}}
			if equal {return previous}
		}
	}
	result := new_clone(Read_Order{terminal, slice.clone(branches), hash})
	if cache != nil {
		if cache.sets == nil {cache.sets = make(map[u64]^Read_Order, runtime.heap_allocator())}
		if previous := cache.sets[hash]; previous != nil {
			if cache.collisions == nil {cache.collisions = make(map[^Read_Order]^Read_Order, runtime.heap_allocator())}
			cache.collisions[result] = previous
		}
		cache.sets[hash] = result
	}
	return result
}

@(private = "file")
add_read_event :: proc(root: ^Read_Event_Trie, order: []tokenizer.Pos) {
	node := root
	for pos in order {
		if node.children == nil {node.children = make(map[tokenizer.Pos]^Read_Event_Trie)}
		child, exists := node.children[pos]
		if !exists {
			child = new(Read_Event_Trie)
			node.children[pos] = child
		}
		node = child
	}
}
