"""Protected-state writes and private copies across recursive graphs."""

import unittest

import test_semantics_cli as semantic


class RecursiveStateTests(unittest.TestCase):
    setUp = semantic.SemanticTests.setUp
    write = semantic.SemanticTests.write
    inspect = semantic.SemanticTests.inspect
    inspect_borrowed = semantic.SemanticTests.inspect_borrowed
    engine = semantic.SemanticTests.engine


    def test_recursive_resource_widening_retains_borrowed_write_checks(self):
        self.write("state", "Node :: struct {next: ^Node, values: []int}\n")
        source = self.write("functions", "mutate :: proc(head: ^state.Node) {\n"
                            "cursor := head\nfor cursor != nil {\n"
                            "cursor.values[0] = 2\ncursor = cursor.next\n}\n}\n", 'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call="mutate(&live)", declarations="live: state.Node"))

    def test_recursive_tree_clone_summary_has_a_finite_metadata_domain(self):
        source = self.write("functions", "Node :: struct {children: map[int]Node}\n"
                            "clone :: proc(source: Node) -> Node {\nresult := source\n"
                            "result.children = make(map[int]Node)\n"
                            "for key, child in source.children {result.children[key] = clone(child)}\n"
                            "return result\n}\n")
        self.assertNotIn("OWN001", self.inspect(source))

    def test_recursive_tree_clone_preserves_borrowed_leaf_capabilities(self):
        self.write("state", "Node :: struct {children: map[int]Node, values: []int}\n")
        source = self.write("functions", "clone :: proc(source: state.Node) -> state.Node {\n"
                            "result := source\nresult.children = make(map[int]state.Node)\n"
                            "for key, child in source.children {result.children[key] = clone(child)}\n"
                            "return result\n}\n"
                            "mutate :: proc(source: state.Node) {copy := clone(source); copy.values[0] = 1}\n",
                            'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call="mutate(live)", declarations="live: state.Node"))


if __name__ == "__main__":
    unittest.main()
