import importlib.util
import pathlib
import unittest


root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("identity", root / "scripts/configure_helper_identity.py")
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class HelperIdentityTests(unittest.TestCase):
    def test_implicit_universal_requirement_keeps_both_architectures(self):
        requirement = 'cdhash H"' + "a" * 40 + '" or cdhash H"' + "b" * 40 + '"'
        self.assertEqual(identity.designated_requirement("Executable=/fixture/helper\n# designated => " + requirement), requirement)

    def test_explicit_requirement(self):
        requirement = 'identifier "com.wondercraft.WonderBox.FanHelper" and anchor apple generic'
        self.assertEqual(identity.designated_requirement("designated => " + requirement), requirement)

    def test_missing_empty_or_duplicate_requirement_fails_closed(self):
        for value in ["Executable=/fixture/helper", "designated => ", "# designated => \n", "designated => one\ndesignated => two"]:
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                identity.designated_requirement(value)


if __name__ == "__main__":
    unittest.main()
