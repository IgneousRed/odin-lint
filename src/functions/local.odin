#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"
import "core:path/filepath"

// ---------------- Project ----------------

import "../state"

// -------------------------------- Constants --------------------------------

// ---------------- Package ----------------

SECTION_KINDS :: []string{"Imports", "Constants", "Globals", "Types", "Procedures"}

SECTION_VISIBILITIES :: []string{"Public", "Package", "File"}

SECTION_IMPORTS :: []string{"Vendor", "Odin", "Project"}

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

Local_Check :: struct {
	diagnostics: ^[dynamic]state.Diagnostic,
	callbacks: map[^ast.Proc_Lit]bool,
	proc_depth: int,
	test_procedure, catalog_procedure: ^ast.Proc_Lit,
	default_visibility: int,
	role: Role,
	has_role: bool,
}

Section :: struct {
	pos: tokenizer.Pos,
	name: string,
	level, parent, items: int,
}

Section_Collector :: struct {items: [dynamic]Section_Item, visibility: int}

// ---------------- File ----------------

@(private="file")
Interface_Kind :: enum {Helper, Canonical, Fragment}

@(private="file")
Section_Item :: struct {statement: ^ast.Stmt, visibility: int}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// Target-specific fragments retain imports and declarations in their original
// compiler conditions. Source compilation supplies validity for every target;
// policy analysis never silently picks one branch of the interface family.
interface_kind :: proc(file: Parsed_Source, folder: string) -> Interface_Kind {
	name := filepath.base(file.file.fullpath)
	if name == "main.odin" || name == strings.concatenate({folder, ".odin"}) {return .Canonical}
	if !strings.has_suffix(name, ".odin") {return .Helper}
	stem := name[:len(name)-len(".odin")]
	main_prefix, directory_prefix := "main_", strings.concatenate({folder, "_"})
	if !(strings.has_prefix(stem, main_prefix) && len(stem) > len(main_prefix)) && !(strings.has_prefix(stem, directory_prefix) && len(stem) > len(directory_prefix)) {return .Helper}
	tags := parser.parse_file_tags(file.file)
	if len(tags.build) > 0 || len(tags.build_project_name) > 0 {return .Fragment}
	return .Helper
}

visit_section_items :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {return visitor}
	c := cast(^Section_Collector)visitor.data
	visibility := c.visibility
	defer {c.visibility = visibility}
	#partial switch n in node.derived {
	case ^ast.Value_Decl:
		effective, _ := declaration_visibility(n, c.visibility)
		append(&c.items, Section_Item{&n.node, effective})
		return nil
	case ^ast.Import_Decl:
		append(&c.items, Section_Item{&n.node, c.visibility})
		return nil
	case ^ast.Foreign_Import_Decl:
		append(&c.items, Section_Item{&n.node, c.visibility})
		return nil
	case ^ast.Foreign_Block_Decl:
		attributes := ast.Value_Decl{attributes = n.attributes}
		c.visibility, _ = declaration_visibility(&attributes, c.visibility)
		ast.walk(visitor, n.body)
		return nil
	case ^ast.When_Stmt:
		ast.walk(visitor, n.body)
		ast.walk(visitor, n.else_stmt)
		return nil
	}
	return visitor
}

visit_local :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return visitor
	}
	check := cast(^Local_Check)visitor.data
	#partial switch n in node.derived {
	case ^ast.Call_Expr:
		for argument in n.args {
			value := unwrap_parens(argument)
			if field, ok := value.derived.(^ast.Field_Value); ok {
				value = unwrap_parens(field.value)
			}
			if literal, ok := value.derived.(^ast.Proc_Lit); ok {
				check.callbacks[literal] = true
			}
		}
	case ^ast.Proc_Lit:
		if check.has_role && (check.role == .Catalog || check.role == .State || check.role == .Views) &&
		   check.proc_depth == 0 && n.body != nil && n != check.test_procedure && !(check.role == .Catalog && n == check.catalog_procedure) {
			append(check.diagnostics, state.Diagnostic{n.pos, "ARCH004", "catalog/state/views contain definitions; move procedure bodies to functions or effects"})
		}
		if check.proc_depth > 0 && !check.callbacks[n] {
			append(check.diagnostics, state.Diagnostic{n.pos, "PROC001", "move nested procedure to file scope, or pass the literal directly as a callback"})
		}
		check.proc_depth += 1
		ast.walk(visitor, n.type)
		ast.walk(visitor, n.body)
		for clause in n.where_clauses {
			ast.walk(visitor, clause)
		}
		check.proc_depth -= 1
		return nil
	case ^ast.Value_Decl:
		if check.proc_depth != 0 {
			return visitor
		}
		visibility, explicit := declaration_visibility(n, check.default_visibility)
		if explicit && visibility == check.default_visibility {
			append(check.diagnostics, state.Diagnostic{n.pos, "VIS001", "remove private attribute that repeats the file's default visibility"})
		}
		if !check.has_role {
			return visitor
		}
		if check.role in PURE_ROLES && n.is_mutable && !has_attribute(n, "rodata") {
			append(check.diagnostics, state.Diagnostic{n.pos, "ARCH003", "keep mutable package state out of pure source roles; pass working data explicitly"})
		}
		// The compiler permits one test procedure per attributed declaration.
		// Remember its identity so nested type/literal wrappers cannot hide other
		// data-role procedure bodies from the Proc_Lit rule above.
		check.test_procedure, check.catalog_procedure = nil, nil
		if check.role == .Catalog && !n.is_mutable {
			for value in n.values {if procedure, ok := unwrap_parens(value).derived.(^ast.Proc_Lit); ok {check.catalog_procedure = procedure}}
		}
		if has_attribute(n, "test") {
			for value in n.values {
				if procedure, ok := unwrap_parens(value).derived.(^ast.Proc_Lit); ok {check.test_procedure = procedure}
			}
		}
		if check.role in PURE_ROLES && (has_attribute(n, "init") || has_attribute(n, "fini")) {
			append(check.diagnostics, state.Diagnostic{n.pos, "ARCH005", "replace implicit init/fini execution in pure roles with explicit initialization at the entry point"})
		}
	}
	return visitor
}

unwrap_parens :: proc(value: ^ast.Expr) -> ^ast.Expr {
	value := value
	for value != nil {
		paren, ok := value.derived.(^ast.Paren_Expr)
		if !ok {
			break
		}
		value = paren.expr
	}
	return value
}

declaration_visibility :: proc(decl: ^ast.Value_Decl, default_visibility: int) -> (visibility: int, explicit: bool) {
	visibility = default_visibility
	for attribute in decl.attributes {
		for element in attribute.elems {
			value := element
			field, assigned := value.derived.(^ast.Field_Value)
			if assigned {
				value = field.field
			}
			ident, ok := value.derived.(^ast.Ident)
			if !ok || ident.name != "private" {
				continue
			}
			explicit, visibility = true, 1
			if assigned {
				if literal, literal_ok := field.value.derived.(^ast.Basic_Lit); literal_ok {
					text, _ := metadata_string(literal.tok.text)
					if text == "file" {
						visibility = 2
					}
				}
			}
		}
	}
	return
}

import_rank :: proc(path: string) -> int {
	if strings.has_prefix(path, "vendor:") {
		return 0
	}
	if strings.has_prefix(path, "core:") || strings.has_prefix(path, "base:") {
		return 1
	}
	return 2
}

has_attribute :: proc(decl: ^ast.Value_Decl, name: string) -> bool {
	if decl == nil {return false}
	for attribute in decl.attributes {
		for element in attribute.elems {
			value := element
			if field, ok := value.derived.(^ast.Field_Value); ok {
				value = field.field
			}
			if ident, ok := value.derived.(^ast.Ident); ok && ident.name == name {
				return true
			}
		}
	}
	return false
}
