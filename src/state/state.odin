package state

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:odin/tokenizer"

// -------------------------------- Types --------------------------------

// ---------------- Public ----------------

// Analysis-only sources supply sibling uses, project consumers, and imported types.
Source :: struct {
	path, text: string,
	selected: bool,
}

Diagnostic :: struct {
	pos:     tokenizer.Pos,
	rule:    string,
	message: string,
}
