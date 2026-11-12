#+private file
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

// ---------------- Project ----------------

import "../state"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------
@(private)
Import_Collector :: struct {imports: map[^ast.Import_Decl]string, paths: [dynamic]string}

// ---------------- File ----------------

Source_Positions :: struct {
	insertions, lines: [dynamic]int,
	seen: map[^ast.Node]bool,
}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

@(private)
visit_imports :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {return visitor}
	collector := cast(^Import_Collector)visitor.data
	#partial switch declaration in node.derived {
	case ^ast.Import_Decl:
		append(&collector.paths, collector.imports[declaration])
		return nil
	case ^ast.When_Stmt:
		condition, known := literal_condition(declaration.cond)
		if known {ast.walk(visitor, declaration.body if condition else declaration.else_stmt)} else {ast.walk(visitor, declaration.body); ast.walk(visitor, declaration.else_stmt)}
		return nil
	case ^ast.Proc_Lit: return nil
	}
	return visitor
}

@(private)
parse_source :: proc(source: state.Source) -> (parsed: Parsed_Source, failure: string) {
	parsed.selected = source.selected
	parsed.file = ast.File{src = source.text, fullpath = source.path}
	parsed_ok := false
	parse_input: {
		file := &parsed.file
		failure := &failure
		context.user_ptr = failure
		p := parser.default_parser()
		p.err, p.warn = parse_error, nil
		if parser.parse_file(&p, file) && failure^ == "" {parsed_ok = true; break parse_input}
		original := file.src
		positions := Source_Positions{seen = make(map[^ast.Node]bool)}
		append(&positions.lines, 0)
		for ch, offset in original {if ch == '\n' {append(&positions.lines, offset+1)}}
		lex := tokenizer.Tokenizer{flags = {.Insert_Semicolon}}
		tokenizer.init(&lex, original, file.fullpath, nil)
		last, parens := 0, 0
		attributes := make([dynamic]int)
		after_at, after_attribute := false, false
		for {
			token := tokenizer.scan(&lex)
			if tokenizer.is_newline(token) {
				// An attribute's implicit newline belongs to its declaration;
				// replacing it with an explicit semicolon changes that grammar.
				if !after_attribute {append(&positions.insertions, last)}
			} else if token.kind != .Comment {
				if token.text == "else" && len(positions.insertions) > 0 && positions.insertions[len(positions.insertions)-1] == last {
					// Odin attaches a newline-separated else to its preceding body;
					// an explicit semicolon would detach it.
					pop(&positions.insertions)
				}
				after_attribute = false
				#partial switch token.kind {
				case .At: after_at = true
				case .Open_Paren:
					parens += 1
					if after_at {append(&attributes, parens)}
					after_at = false
				case .Close_Paren:
					if len(attributes) > 0 && attributes[len(attributes)-1] == parens {pop(&attributes); after_attribute = true}
					parens -= 1
				case .Ident: after_attribute, after_at = after_at, false
				case: after_at = false
				}
				last = token.pos.offset + len(token.text)
			}
			if token.kind == .EOF {break}
		}
		if lex.error_count > 0 || len(positions.insertions) == 0 {break parse_input}
		normalized := make([dynamic]byte, 0, len(original)+len(positions.insertions))
		start := 0
		for offset in positions.insertions {
			append(&normalized, original[start:offset])
			append(&normalized, ';')
			start = offset
		}
		append(&normalized, original[start:])
		file^ = ast.File{src = string(normalized[:]), fullpath = file.fullpath}
		failure^ = ""
		p = parser.default_parser()
		p.err, p.warn = parse_error, nil
		ok := parser.parse_file(&p, file) && failure^ == ""
		if !ok {break parse_input}
		visitor := ast.Visitor{visit = restore_source_positions, data = &positions}
		for statement in file.decls {ast.walk(&visitor, statement)}
		for comment in file.comments {ast.walk(&visitor, &comment.node)}
		file.pkg_token.pos = original_position(&positions, file.pkg_token.pos)
		for &tag in file.tags {tag.pos = original_position(&positions, tag.pos)}
		for imported in file.imports {imported.relpath.pos = original_position(&positions, imported.relpath.pos)}
		file.src = original
		parsed_ok = ok
	}
	if !parsed_ok {
		if failure == "" {failure = fmt.aprintf("%s: policy analysis could not parse compiler-checked source", source.path)}
		return parsed, failure
	}
	parsed.imports = make(map[^ast.Import_Decl]string)
	for decl in parsed.file.imports {
		path_value, ok := metadata_string(decl.relpath.text)
		if !ok {
			return parsed, fmt.aprintf("%s: cannot decode import path; run Odin check before linting", source.path)
		}
		parsed.imports[decl] = path_value
	}
	return
}

// ---------------- File ----------------

restore_source_positions :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {return visitor}
	positions := cast(^Source_Positions)visitor.data
	if positions.seen[node] {return nil}
	positions.seen[node] = true
	node.pos, node.end = original_position(positions, node.pos), original_position(positions, node.end)
	if comments, ok := node.derived.(^ast.Comment_Group); ok {for &token in comments.list {token.pos = original_position(positions, token.pos)}}
	return visitor
}

original_position :: proc(positions: ^Source_Positions, position: tokenizer.Pos) -> tokenizer.Pos {
	result := position
	// Inserted semicolons shift byte offsets but do not change original lines.
	low, high := 0, len(positions.insertions)
	for low < high {
		middle := (low+high)/2
		if positions.insertions[middle]+middle < position.offset {low = middle+1} else {high = middle}
	}
	result.offset -= low
	low, high = 0, len(positions.lines)
	for low < high {
		middle := (low+high)/2
		if positions.lines[middle] <= result.offset {low = middle+1} else {high = middle}
	}
	if low > 0 {result.line, result.column = low, result.offset-positions.lines[low-1]+1}
	return result
}
