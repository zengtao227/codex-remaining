"""Isolated Git/CLI regression tests for the lean-review pilot."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HOOK = Path(os.environ.get('LEAN_HOOK', Path(__file__).with_name('lean_review.py')))


class LeanReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='lean-regression-')
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.hook = self.repo / '.claude/hooks/lean_review.py'
        self.hook.parent.mkdir(parents=True)
        shutil.copyfile(HOOK, self.hook)
        self.write('.gitignore', '.agent/lean-review/\n__pycache__/\n')
        self.write('sample.py', 'value = 0\n')
        self.write('README.md', 'baseline\n')
        self.git('init', '-q')
        self.git('config', 'user.name', 'Lean Test')
        self.git('config', 'user.email', 'lean-test@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('add', '.')
        self.git('commit', '-qm', 'baseline')
        spec = importlib.util.spec_from_file_location('hook_under_test', self.hook)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.run_hook('session-start')

    def write(self, path, contents):
        p = self.repo / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(contents)

    def git(self, *args, input=None):
        result = subprocess.run(['git', '-C', str(self.repo), *args], input=input,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def run_hook(self, command, *args, expected=0):
        result = subprocess.run([sys.executable, str(self.hook), command, *args],
                                input=json.dumps({'session_id': 'test-session'}),
                                capture_output=True, text=True, cwd=self.repo)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def token(self):
        return self.run_hook('review-start').stdout.strip()

    def receipt(self, token=None):
        token = self.token() if token is None else token
        self.write('.agent/lean-review/review.md', 'Reviewed current sample change. No extra simplification.\n')
        return self.run_hook('receipt', '--token', token, '--review-file',
                             '.agent/lean-review/review.md', '--outcome', 'none',
                             '--validation', 'isolated fixture inspection')

    def stop(self, expected):
        result = self.run_hook('stop')
        rows = (self.repo / '.agent/lean-review/log.jsonl').read_text().splitlines()
        entries = [json.loads(row) for row in rows]
        self.assertEqual(entries[-1]['decision'], expected, entries[-1])
        return result, entries[-1]

    def state(self):
        return json.loads((self.repo / '.agent/lean-review/state.json').read_text())

    def test_read_only_skip(self):
        self.stop('skip')

    def test_valid_receipt_repeated_pass_and_logs_do_not_invalidate(self):
        self.write('sample.py', 'value = 1\n')
        self.receipt()
        token = self.token()
        self.stop('pass')
        self.stop('pass')
        self.assertEqual(token, self.token())

    def test_staged_index_changes_with_unchanged_worktree_invalidate(self):
        self.write('sample.py', 'value = 1\n')
        self.git('add', 'sample.py')
        self.write('sample.py', 'value = 2\n')
        token = self.token()
        self.receipt(token)
        oid = self.git('hash-object', '-w', '--stdin', input='value = 3\n').strip()
        self.git('update-index', '--cacheinfo', '100644', oid, 'sample.py')
        self.assertEqual((self.repo / 'sample.py').read_text(), 'value = 2\n')
        self.assertNotEqual(token, self.token())
        self.run_hook('receipt', '--token', token, '--review-file', '.agent/lean-review/review.md',
                      '--outcome', 'none', '--validation', 'fixture', expected=1)
        self.stop('block')

    def test_rename_z_with_spaces_and_newline(self):
        dest = 'renamed name\nwith newline.py'
        self.git('mv', 'sample.py', dest)
        self.assertIn('R  ', self.git('status', '--porcelain=v1', '-z'))
        self.assertEqual([p for p, _ in self.mod.worktree_entries()], [dest])
        self.stop('block')

    def test_copy_z_consumes_source_field(self):
        real_git = self.mod.git
        def output(*args):
            if args[0] == 'status':
                return 'C  copied name.py\0sample.py\0?? extra.py\0'
            if args[0] == 'ls-files':
                return '100644 ' + '1' * 40 + ' 0\tcopied name.py\0'
            return real_git(*args)
        self.write('copied name.py', 'value = 0\n')
        self.write('extra.py', 'value = 9\n')
        with patch.object(self.mod, 'git', side_effect=output):
            self.assertEqual([p for p, _ in self.mod.worktree_entries()], ['copied name.py', 'extra.py'])

    def test_real_git_copy_and_rename_z(self):
        self.git('config', 'status.renames', 'copies')
        self.git('mv', 'sample.py', 'renamed.py')
        shutil.copyfile(self.repo / 'renamed.py', self.repo / 'copied.py')
        self.git('add', 'copied.py')
        raw = self.git('status', '--porcelain=v1', '-z')
        self.assertIn('C  ', raw)
        self.assertIn('R  ', raw)
        self.assertEqual([p for p, _ in self.mod.worktree_entries()], ['copied.py', 'renamed.py'])
        self.stop('block')

    def test_complete_revert_clears_pending_and_pause(self):
        self.write('sample.py', 'value = 1\n')
        self.git('add', 'sample.py')
        self.stop('block')
        self.run_hook('pause', 'need approval')
        self.git('restore', '--source=HEAD', '--staged', '--worktree', 'sample.py')
        self.stop('skip')
        state = self.state()
        self.assertFalse(state['pending'])
        self.assertFalse(state['paused'])
        self.assertEqual(state['block_count'], 0)

    def test_dirty_baseline_is_not_new_work(self):
        self.write('sample.py', 'value = 1\n')
        self.git('add', 'sample.py')
        self.write('sample.py', 'value = 2\n')
        (self.repo / '.agent/lean-review/state.json').unlink()
        self.run_hook('session-start')
        self.stop('skip')
        self.write('sample.py', 'value = 3\n')
        self.stop('block')

    def test_resume_does_not_reset_baseline(self):
        before = self.state()
        self.write('sample.py', 'value = 1\n')
        self.run_hook('session-start')
        self.assertEqual(before, self.state())
        self.stop('block')

    def test_noncode_unstaged_staged_and_agent_files_keep_receipt(self):
        self.write('sample.py', 'value = 1\n')
        self.receipt()
        token = self.token()
        self.write('README.md', 'updated\n')
        self.write('.agent/handoff.md', 'updated\n')
        self.stop('pass')
        self.git('add', 'README.md', '.agent/handoff.md')
        self.assertEqual(token, self.token())
        self.stop('pass')

    def test_noncode_commit_keeps_receipt(self):
        self.write('sample.py', 'value = 1\n')
        self.receipt()
        token = self.token()
        self.write('README.md', 'updated\n')
        self.git('add', 'README.md')
        self.git('commit', '-qm', 'docs only')
        self.assertEqual(token, self.token())
        self.stop('pass')

    def test_code_rename_to_markdown_is_code_removal(self):
        self.git('mv', 'sample.py', 'retired.md')
        self.stop('block')

    def test_committed_code_rename_to_markdown_is_code_removal(self):
        self.git('mv', 'sample.py', 'retired.md')
        self.git('commit', '-qm', 'retire code')
        self.stop('block')

    def test_code_rename_to_excluded_state_directory_is_code_removal(self):
        self.git('mv', 'sample.py', '.agent/lean-review/retired.py')
        self.stop('block')

    def test_committed_newline_markdown_is_not_code(self):
        self.write('README.md', 'review baseline\n')
        self.write('sample.py', 'value = 1\n')
        self.receipt()
        self.write('new\nnotes.md', 'notes\n')
        self.git('add', 'new\nnotes.md')
        self.git('commit', '-qm', 'docs only')
        _, row = self.stop('pass')
        self.assertEqual(row['changed_scope_count'], 1)

    def test_staged_rename_reverted_clears_pending(self):
        self.git('mv', 'sample.py', 'retired.md')
        self.stop('block')
        self.git('restore', '--source=HEAD', '--staged', '--worktree', '.')
        self.stop('skip')
        self.assertFalse(self.state()['pending'])

    def test_code_commit_without_review_still_blocks(self):
        self.write('sample.py', 'value = 1\n')
        self.git('add', 'sample.py')
        self.git('commit', '-qm', 'code change')
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.stop('block')

    def test_code_commit_after_receipt_invalidates(self):
        self.write('sample.py', 'value = 1\n')
        self.receipt()
        self.write('sample.py', 'value = 2\n')
        self.git('add', 'sample.py')
        self.git('commit', '-qm', 'code change')
        self.stop('block')

    def test_new_file_after_review_and_old_token_refused(self):
        self.write('sample.py', 'value = 1\n')
        token = self.token()
        self.receipt(token)
        self.write('extra.py', 'value = 2\n')
        self.run_hook('receipt', '--token', token, '--review-file', '.agent/lean-review/review.md',
                      '--outcome', 'none', '--validation', 'fixture', expected=1)
        self.stop('block')

    def test_missing_review_file_refused(self):
        self.write('sample.py', 'value = 1\n')
        self.run_hook('receipt', '--token', self.token(), '--review-file', 'missing.md',
                      '--outcome', 'none', '--validation', 'fixture', expected=1)
        self.stop('block')

    def test_pause_once_and_bounded_incomplete(self):
        self.write('sample.py', 'value = 1\n')
        self.run_hook('pause', 'user approval')
        self.stop('skip')
        self.assertTrue(self.state()['pending'])
        self.assertIn('decision', self.stop('block')[0].stdout)
        self.assertIn('decision', self.stop('block')[0].stdout)
        final, _ = self.stop('block')
        self.assertEqual(final.stdout, '')
        self.assertIn('未完成', final.stderr)
        self.assertTrue(self.state()['pending'])

    def test_internal_git_error_logs_one_json_per_line(self):
        self.git('update-ref', '-d', 'HEAD')
        # Force session-start through its failing baseline read.
        (self.repo / '.agent/lean-review/state.json').unlink()
        result = self.run_hook('session-start')
        self.assertIn('hook error', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        result = self.run_hook('review-start', expected=1)
        rows = (self.repo / '.agent/lean-review/log.jsonl').read_text().splitlines()
        self.assertEqual(len(rows), 2)
        for row in rows:
            self.assertEqual(json.loads(row)['decision'], 'error')

    def test_stop_exception_is_logged(self):
        state = self.state()
        state['baseline_entries'] = None
        self.write('.agent/lean-review/state.json', json.dumps(state))
        result, row = self.stop('error')
        self.assertIn('hook error', result.stderr)
        self.assertIn('hook 异常', row['reason'])

    def test_newline_reason_stays_single_jsonl_line(self):
        self.write('sample.py', 'value = 1\n')
        self.run_hook('pause', 'line one\nline two')
        _, row = self.stop('skip')
        self.assertIn('line one\nline two', row['reason'])
        self.assertEqual(len((self.repo / '.agent/lean-review/log.jsonl').read_text().splitlines()), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
