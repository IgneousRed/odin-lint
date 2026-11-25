"""Saved concrete callers for capability requirements inferred at formals."""

from test_cli import section


def borrowed_consumer(root, source, call="probe(&live)", declarations="live: state.Store", modules=("state",)):
    directory = root / "consumer"
    directory.mkdir(exist_ok=True)
    imports = f'import target "../{source.parent.relative_to(root).as_posix()}"\n'
    imports += "".join(f'import "../src/{module}"\n' for module in modules)
    path = directory / "consumer.odin"
    path.write_text("package consumer\n" + section("Imports", "Project") + imports
                    + section("Globals", "Public") + declarations + "\n"
                    + section("Procedures", "Public") + "run :: proc() {target." + call + "}\n", encoding="utf-8")
    return path
