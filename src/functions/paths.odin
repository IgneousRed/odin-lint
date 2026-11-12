#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:strings"

// -------------------------------- Constants --------------------------------

// ---------------- Package ----------------

ROLE_NAMES :: [Role]string{
	.Catalog = "catalog", .Effects = "effects", .Engine = "engine",
	.Functions = "functions", .Procedures = "procedures", .State = "state", .Views = "views",
	.UI = "ui", .Application = "application",
	.Migrations = "migrations",
}

ROLE_DEPENDENCIES :: [Role]bit_set[Role]{
	.Catalog = {},
	.Effects = {.Procedures, .Engine, .Functions, .Views, .State, .Catalog},
	.Engine = {.Functions, .Views, .State, .Catalog},
	.Functions = {.Views, .State, .Catalog, .Migrations},
	.Procedures = {.Engine, .Functions, .Views, .State, .Catalog},
	.Migrations = {.State, .Catalog},
	.State = {.Catalog},
	.Views = {.State, .Catalog},
	.UI = {.Procedures, .Engine, .Functions, .Views, .State, .Catalog},
	.Application = {.UI, .Effects, .Procedures, .Engine, .Functions, .Views, .State, .Catalog, .Migrations},
}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

source_role :: proc(path, source_root: string) -> (Role, bool) {
	rel, err := filepath.rel(source_root, path)
	if err != .None {
		return {}, false
	}
	rel, _ = strings.replace_all(rel, "\\", "/")
	parts := strings.split_n(rel, "/", 2)
	role_names := ROLE_NAMES
	for name, role in role_names {
		if parts[0] == name {
			return role, true
		}
	}
	return {}, false
}

parse_error :: proc(pos: tokenizer.Pos, message: string, args: ..any) {
	failure := cast(^string)context.user_ptr
	if failure^ == "" {
		failure^ = fmt.aprintf("%s: cannot parse source at %d:%d: %s; policy analysis failed on compiler-checked input", pos.file, pos.line, pos.column, fmt.aprintf(message, ..args))
	}
}
