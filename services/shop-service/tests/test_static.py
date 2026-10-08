"""Static checks that need nothing installed.

They catch the mistakes that otherwise only show up when the container starts:
a file that does not parse, or an `from app.x import name` where `name` does
not exist in app/x.py. Run with:

    cd services/shop-service
    python -m unittest tests.test_static -v
"""

import ast
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _py_files():
    for folder, _dirs, files in os.walk(APP):
        for name in files:
            if name.endswith(".py"):
                yield os.path.join(folder, name)


def _module_path(dotted: str) -> str | None:
    base = os.path.join(ROOT, *dotted.split("."))
    if os.path.isfile(base + ".py"):
        return base + ".py"
    if os.path.isfile(os.path.join(base, "__init__.py")):
        return os.path.join(base, "__init__.py")
    return None


def _top_level_names(path: str) -> set[str]:
    tree = ast.parse(_read(path))
    names: set[str] = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                for sub in ast.walk(target):
                    if isinstance(sub, ast.Name):
                        names.add(sub.id)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                names.add((alias.asname or alias.name).split(".")[0])
    return names


class StaticChecks(unittest.TestCase):
    def test_every_file_parses(self):
        for path in _py_files():
            with self.subTest(file=os.path.relpath(path, ROOT)):
                ast.parse(_read(path))

    def test_internal_imports_resolve(self):
        for path in _py_files():
            tree = ast.parse(_read(path))
            for node in ast.walk(tree):
                if not isinstance(node, ast.ImportFrom) or not node.module:
                    continue
                if node.module != "app" and not node.module.startswith("app."):
                    continue
                where = f"{os.path.relpath(path, ROOT)}:{node.lineno}"
                target = _module_path(node.module)
                self.assertIsNotNone(target, f"{where}: module {node.module} not found")
                defined = _top_level_names(target)
                for alias in node.names:
                    if alias.name in defined:
                        continue
                    # `from app import logic` / `from app.routers import x` import a sub-module
                    self.assertIsNotNone(
                        _module_path(f"{node.module}.{alias.name}"),
                        f"{where}: {alias.name!r} is not defined in {node.module}",
                    )

    def test_route_function_names_are_unique_per_router(self):
        for path in _py_files():
            if os.sep + "routers" + os.sep not in path:
                continue
            tree = ast.parse(_read(path))
            seen: dict[str, int] = {}
            for node in tree.body:
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    self.assertNotIn(node.name, seen, f"{path}: duplicate function {node.name}")
                    seen[node.name] = node.lineno

    def test_static_routes_come_before_the_shop_id_route(self):
        path = os.path.join(APP, "routers", "shops_router.py")
        text = _read(path)
        generic = text.index('@router.get("/{shop_id}"')
        for static in ('"/owner/me"', '"/external"', '"/landmark"'):
            self.assertLess(text.index(static), generic, f"{static} must be declared before /{{shop_id}}")

    def test_old_and_new_columns_exist_in_models(self):
        text = _read(os.path.join(APP, "models.py"))
        for column in ("is_open", "status", "delivery_available", "stock_status", "is_available",
                       "alert_type", "owner_reply", "rating_avg"):
            self.assertIn(column + ":", text)

    def test_every_new_column_has_a_migration(self):
        migrations = _read(os.path.join(APP, "database.py"))
        for column in ("status VARCHAR", "status_reason", "reopen_at", "delivery_available",
                       "stock_status", "alert_type", "new_address", "starts_at", "ends_at"):
            self.assertIn(column, migrations, f"no migration for {column}")


if __name__ == "__main__":
    unittest.main()
