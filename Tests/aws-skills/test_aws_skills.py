import importlib.util
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('aws_skills', PROJECT / 'scripts/aws-skills-server.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SkillLibraryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.library = module.SkillLibrary(PROJECT / '.agents/aws-agent-toolkit')

    def test_every_skill_is_discoverable_and_can_be_read_completely(self):
        names = []
        offset = 0
        while offset is not None:
            page = self.library.search(offset=offset, limit=30)
            names.extend(item['name'] for item in page['skills'])
            offset = page['next_offset']
        self.assertEqual(set(names), set(self.library.skills))
        self.assertEqual(len(names), len(set(names)))
        for name in names:
            pages, offset = [], 0
            while offset is not None:
                page = self.library.retrieve(name, offset=offset, limit=50)
                pages.extend(page['content'].split('\n'))
                offset = page['next_offset']
            expected = self.library.skills[name]['path'].read_text().splitlines()
            self.assertEqual(pages, expected, name)

    def test_search_and_nested_reference(self):
        results = self.library.search('swift')['skills']
        self.assertIn('aws-sdk-swift-usage', [item['name'] for item in results])
        result = self.library.retrieve('aws-database', 'references/select.md')
        self.assertTrue(result['content'])

    def test_path_escape_and_invalid_requests_are_rejected(self):
        for path in ['/etc/passwd', '../../../../../../../../../../etc/passwd']:
            with self.assertRaises(ValueError):
                self.library.retrieve('aws-database', path)
        with self.assertRaises(ValueError):
            self.library.retrieve('missing-skill')
        with self.assertRaises(ValueError):
            self.library.retrieve('aws-database', offset=-1)
        with self.assertRaises(ValueError):
            self.library.search(limit=1000)


if __name__ == '__main__':
    unittest.main()
