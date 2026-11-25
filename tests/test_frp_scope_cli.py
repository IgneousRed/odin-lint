"""FRP state boundaries stay enforced without generic memory-lifetime policy."""

import unittest

import test_ownership_052_cli as fixture
from test_cli import section


class FRPScopeTests(unittest.TestCase):
    setUp = fixture.Ownership052Tests.setUp
    write = fixture.Ownership052Tests.write
    check = fixture.Ownership052Tests.check
    lint = fixture.Ownership052Tests.lint

    def source(self, body, imports="", declarations=""):
        prefix = section("Imports", "Odin") + imports if imports else ""
        content = section("Globals", "Public") + declarations if declarations else ""
        return self.write("effects", content + section("Procedures", "Public") + body, prefix)

    def test_ordinary_buffer_cleanup_and_alias_liveness_are_outside_scope(self):
        source = self.source("run :: proc() {\n"
                             "\tvalues := make([]int, 1)\n\talias := values\n\tdelete(values)\n\t_ = alias[0]\n}\n"
                             "returned :: proc() -> []int {values := make([]int, 1); defer delete(values); return values}\n")
        self.check(source.parent)
        self.assertEqual(self.lint(source), "")

    def test_temporary_return_reset_and_storage_are_outside_scope(self):
        source = self.source('run :: proc() {saved = fmt.tprintf("%d", 1); free_all(context.temp_allocator); _ = saved}\n'
                             'returned :: proc() -> string {value := fmt.tprintf("%d", 1); defer free_all(context.temp_allocator); return value}\n',
                             'import "core:fmt"\n', "saved: string\n")
        self.check(source.parent)
        self.assertEqual(self.lint(source), "")

    def test_thread_arguments_are_not_implicitly_consumed(self):
        source = self.source("run :: proc() {\n"
                             "\tvalue := new(int)\n\tworker_id: posix.pthread_t\n"
                             "\t_ = posix.pthread_create(&worker_id, nil, worker, value)\n"
                             "\tvalue^ = 1\n\t_ = posix.pthread_join(worker_id, nil)\n\tfree(value)\n}\n"
                             'worker :: proc "c" (data: rawptr) -> rawptr {_ = data; return nil}\n',
                             'import "core:sys/posix"\n')
        self.check(source.parent)
        self.assertEqual(self.lint(source), "")

    def test_later_tuple_results_keep_protected_state_write_evidence(self):
        self.write("engine", "Owner :: struct {rows: map[int]int}\n"
                   '@(private="file")\nlive: Owner\n'
                   "view :: proc() -> (int, ^Owner) {return 1, &live}\n")
        source = self.write("procedures", "run :: proc() {_, value := engine.view(); value.rows[1] = 2}\n",
                            'import "../engine"\n')
        self.check(source.parent)
        self.assertIn("OWN001:", self.lint(source))

    def test_private_catalog_construction_and_cleanup_do_not_imply_publication(self):
        self.write("catalog", "Catalog :: struct {rows: map[int]int}\n")
        source = self.source("run :: proc() {value := new(catalog.Catalog); value.rows = make(map[int]int); "
                             "value.rows[1] = 1; cleanup(value); free(value)}\n"
                             "cleanup :: proc(value: ^catalog.Catalog) {delete(value.rows); value^ = {}}\n",
                             declarations="")
        # Project imports have their own group, rather than an Odin-library group.
        source.write_text(source.read_text().replace("package effects\n", "package effects\n"
                          + section("Imports", "Project") + 'import "../catalog"\n'))
        self.check(source.parent)
        self.assertEqual(self.lint(source), "")

    def test_explicit_read_only_catalog_remains_protected_through_helpers(self):
        self.write("catalog", "Catalog :: struct {rows: map[int]int}\n"
                   "@(rodata)\nshared: Catalog\nview :: proc() -> ^Catalog {return &shared}\n")
        helper = self.write("functions", "change :: proc(value: ^catalog.Catalog) {value.rows[1] = 2}\n",
                            'import "../catalog"\n')
        source = self.write("effects", "run :: proc() {functions.change(catalog.view())}\n",
                            'import "../catalog"\nimport "../functions"\n')
        self.check(source.parent)
        self.assertIn("OWN001:", self.lint(source, helper))
