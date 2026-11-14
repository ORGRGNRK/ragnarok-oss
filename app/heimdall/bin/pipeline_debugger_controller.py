#!/usr/bin/env python3
"""Outside controller. No model commands or validator code run in the user's checkout.

Acceptance JSON: {"image": "locally-installed-image", "checks": [
 {"id": "test", "argv": ["python", "/validator/check.py"],
  "inputs": {"check.py": "/absolute/outside/check.py"}}]}
Checks are frozen before baseline. Model output is file replacements, never host commands.
"""
import difflib
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

EXCLUDED = {'.git', '.env', '.ssh', '.aws', '.codex', '.gemini', '.npmrc', '.pypirc', '.netrc', '.docker', '.kube', '.ragnarok', 'local.conf', 'id_rsa', 'id_ed25519', 'node_modules',
            '.venv', 'venv', '__pycache__', 'build', 'dist', '.DS_Store', 'xcuserdata'}


def allowed(path):
    return not any(part in EXCLUDED or part.startswith('.env.') or
                   any(word in part.lower() for word in ('credential', 'secret', 'private_key')) or
                   part.lower().endswith(('.pem', '.key', '.p12', '.pfx')) for part in path.parts)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def manifest(folder):
    result = {}
    folder = Path(folder).resolve(strict=True)
    total = 0
    for directory, dirs, files in os.walk(folder, followlinks=False):
        base = Path(directory)
        dirs[:] = sorted(name for name in dirs if allowed((base / name).relative_to(folder)))
        for name in dirs:
            if (base / name).is_symlink():
                raise ValueError('Symlink directory rejected')
        for name in sorted(files):
            path = base / name
            rel = path.relative_to(folder)
            if not allowed(rel):
                continue
            if path.is_symlink() or not path.is_file():
                raise ValueError(f'Nonregular source input rejected: {rel}')
            size = path.stat().st_size
            total += size
            if size > 4 * 1024 * 1024 or total > 32 * 1024 * 1024 or len(result) >= 2000:
                raise ValueError('Scoped source exceeds file/size budget; select a smaller target')
            result[str(rel)] = digest(path.read_bytes())
    return result


def source_hash(files):
    return digest(json.dumps(files, sort_keys=True).encode())


def decide_checks(required, results, retained=(), baseline=False):
    """Pure acceptance policy. No model text, logs, or claimed verdict is an input."""
    ids = [r.get('id') for r in results]
    complete = len(ids) == len(required) and set(ids) == set(required)
    known = {'succeeded', 'failed', 'timed_out', 'cancelled', 'blocked', 'output_limit'}
    for result in results:
        state, code = result.get('status'), result.get('exit')
        if state not in known:
            complete = False
        if state in ('succeeded', 'failed'):
            if type(code) is not int or (state == 'succeeded') != (code == 0):
                complete = False
            if state == 'succeeded' and result.get('signal') is not None:
                complete = False
    passed = sorted(r['id'] for r in results if r.get('status') == 'succeeded') if complete else []
    regressed = sorted(set(retained) - set(passed))
    states = {r.get('status') for r in results}
    gates = {'proposal': None if baseline else True, 'acceptance': complete and set(passed) == set(required),
             'non_regression': complete and not regressed}
    if not complete:
        outcome, code = 'blocked', 'invalid_evidence'
    elif 'cancelled' in states:
        outcome, code = 'cancelled', 'cancelled'
    elif states.intersection({'blocked', 'output_limit'}):
        outcome, code = 'blocked', 'validation_unavailable'
    elif baseline:
        outcome, code = 'baseline', 'baseline_recorded'
    elif regressed:
        outcome, code = 'reject', 'regression'
    elif gates['acceptance'] and set(passed) > set(retained):
        outcome, code = 'accept', 'required_checks_passed'
    elif set(passed) > set(retained):
        outcome, code = 'retain', 'partial_improvement'
    else:
        outcome, code = 'reject', 'no_check_progress'
    return {'outcome': outcome, 'code': code, 'gates': gates, 'passed': passed,
            'regressed': regressed, 'remaining': sorted(set(required) - set(passed))}


def snapshot(source, dest):
    source = Path(source).resolve(strict=True)
    files = manifest(source)
    Path(dest).mkdir(parents=True, exist_ok=False)
    for name in files:
        target = Path(dest) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        original = Path(source) / name
        if original.is_symlink() or any(parent.is_symlink() for parent in original.parents):
            raise ValueError('Source symlink changed during snapshot')
        shutil.copy2(original, target)
    if manifest(dest) != files:
        raise RuntimeError('Source changed while copying; snapshot rejected')
    return files


class CommandRunner:
    """Bounded output on disk, owned process groups; cancellation cannot become success."""
    def __init__(self, clean=lambda value: value, output_limit=128 * 1024):
        self.clean, self.output_limit = clean, output_limit
        self.cancelled = False
        self.environment = None
        self.active = None

    def cancel(self):
        self.cancelled = True
        if self.active is not None:
            try:
                os.killpg(self.active.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def run(self, argv, cwd, timeout=120):
        started = time.monotonic()
        status, code = 'cancelled', None
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            if not self.cancelled:
                try:
                    p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                        stdout=out, stderr=err, start_new_session=True,
                        env=self.environment or {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': '/tmp',
                             'LANG': 'en_US.UTF-8', 'DOCKER_HOST': os.environ.get('DOCKER_HOST', '')})
                    self.active = p
                    status = 'running'
                    while p.poll() is None:
                        if self.cancelled or time.monotonic() - started > timeout or out.tell() + err.tell() > self.output_limit:
                            status = 'cancelled' if self.cancelled else ('timed_out' if time.monotonic() - started > timeout else 'output_limit')
                            os.killpg(p.pid, signal.SIGKILL)
                            break
                        time.sleep(.03)
                    code = p.wait()
                    if os.fstat(out.fileno()).st_size + os.fstat(err.fileno()).st_size > self.output_limit:
                        status = 'output_limit'
                    if status == 'running':
                        status = 'succeeded' if code == 0 else 'failed'
                except OSError as error:
                    err.write(str(error).encode())
                    status = 'blocked'
                finally:
                    if self.active is not None:
                        try:
                            os.killpg(self.active.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    self.active = None
            out.seek(0); err.seek(0)
            stdout = out.read(self.output_limit)
            stderr = err.read(max(0, self.output_limit - len(stdout)))
            return {'argv': argv, 'cwd': str(cwd), 'status': 'cancelled' if self.cancelled else status,
                    'exit': code, 'signal': -code if code is not None and code < 0 else None,
                    'duration': time.monotonic() - started,
                    'stdout': self.clean(stdout.decode(errors='replace')),
                    'stderr': self.clean(stderr.decode(errors='replace'))}


class DockerExecutor:
    def __init__(self, runner, image, run_id):
        self.runner, self.image, self.run_id = runner, image, run_id
        self.names = set()

    def prepare(self):
        result = self.runner.run(['docker', 'image', 'inspect', '--format', '{{.Id}}', self.image], Path.cwd(), 10)
        if result['status'] != 'succeeded':
            raise RuntimeError('Docker or the explicitly selected local image is unavailable: ' + result['stderr'])
        self.image = result['stdout'].strip()
        if not self.image.startswith('sha256:'):
            raise RuntimeError('Docker did not return an immutable image identity')

    def run(self, source, validator, argv, timeout):
        name = self.run_id + '-' + uuid.uuid4().hex[:8]
        self.names.add(name)
        # Neither the Docker socket nor controller/host home/git metadata is mounted.
        command = ['docker', 'run', '--rm', '--name', name, '--label', 'pipeline-debugger.run=' + self.run_id,
            '--network', 'none', '--cpus', '2', '--memory', '1g', '--pids-limit', '128',
            '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--read-only',
            '--user', '65534:65534', '--tmpfs', '/tmp:rw,exec,nosuid,size=512m',
            '--mount', f'type=bind,source={source},target=/source,readonly',
            '--mount', f'type=bind,source={validator},target=/validator,readonly',
            '--workdir', '/tmp', '--entrypoint', 'sh', self.image, '-c',
            'cp -R /source /tmp/workspace && cd /tmp/workspace && exec "$@"', 'check', *argv]
        try:
            result = self.runner.run(command, source, timeout)
            if result['exit'] == 125:
                result['status'] = 'blocked'
            return result
        finally:
            # docker CLI termination alone does not stop its daemon-owned container.
            subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=15)
            self.names.discard(name)

    def cancel(self):
        self.runner.cancel()
        for name in list(self.names):
            subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=15)


class RepairRun:
    def __init__(self, project, acceptance, evidence, goal, clean=lambda value: value, executor=None):
        self.project = Path(project).resolve(strict=True)
        if self.project in (Path.home(), Path('/')):
            raise ValueError('Choose a scoped project folder, not home or the filesystem root')
        self.root = Path(evidence).resolve()
        if self.root == self.project or self.project in self.root.parents:
            raise ValueError('Evidence must be outside the target source')
        self.root.mkdir(parents=True, exist_ok=False, mode=0o700)
        controller = self.root / 'controller'
        controller.mkdir()
        shutil.copy2(Path(__file__), controller / 'pipeline_debugger_controller.py')
        (controller / 'manifest.json').write_text(json.dumps(manifest(controller), indent=2))
        self.clean, self.goal = clean, clean(goal)
        self.runner = CommandRunner(clean)
        self.id = 'pipeline-' + uuid.uuid4().hex[:12]
        self.history, self.best = [], None
        self.stage, self.round = 'baseline', 0
        self.feedback = ''
        self.last_proposal = None
        self.last_decision = None
        self.attempts_used = 0
        self.round_limit = 0
        self.deadline = time.monotonic() + 900
        self.validator = self.root / 'validator'
        self.validator.mkdir()
        spec = json.loads(Path(acceptance).read_text())
        if not spec.get('checks') or not spec.get('image'):
            raise ValueError('Acceptance requires an explicit local Docker image and nonempty checks')
        seen = set()
        for check in spec['checks']:
            if not check.get('id') or check['id'] in seen or not isinstance(check.get('argv'), list) or not check['argv'] or not all(isinstance(x, str) for x in check['argv']):
                raise ValueError('Each check needs a unique id and nonempty argv list')
            seen.add(check['id'])
            if executor is None and (not check.get('inputs') or not any(arg.startswith('/validator/') for arg in check['argv'])):
                raise ValueError('Each check must invoke frozen outside implementation under /validator/')
            for name, original in check.get('inputs', {}).items():
                rel = Path(name)
                if rel.is_absolute() or '..' in rel.parts or not allowed(rel):
                    raise ValueError('Unsafe validator input path')
                path = Path(original).resolve(strict=True)
                if self.project == path or self.project in path.parents:
                    raise ValueError('Validator implementation must be outside the repair project')
                dest = self.validator / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                if dest.exists() and dest.read_bytes() != path.read_bytes():
                    raise ValueError('Conflicting validator inputs')
                shutil.copy2(path, dest)
            check['inputs'] = {name: str(self.validator / name) for name in check.get('inputs', {})}
        self.spec = spec
        self.checks_hash = digest(json.dumps(spec['checks'], sort_keys=True).encode())
        self.write('acceptance.json', spec)
        self.validator_hash = manifest(self.validator)
        self.write('validator-manifest.json', self.validator_hash)
        self.executor = executor or DockerExecutor(self.runner, spec['image'], self.id)
        self.backend = 'docker' if executor is None else 'simulation'
        self.workspace = self.root / 'workspace'
        files = snapshot(self.project, self.workspace)
        self.write('source-manifest.json', files)
        self.write('run.json', {'version': 1, 'id': self.id, 'goal': self.goal, 'project': str(self.project),
                                'status': 'starting', 'backend': 'docker' if executor is None else 'simulation'})

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.clean(json.dumps(value, indent=2)))

    def event(self, kind, **data):
        event = {'version': 1, 'type': kind, 'stage': self.stage, 'round': self.round, **data}
        text = self.clean(json.dumps(event))
        with (self.root / 'events.jsonl').open('a') as stream:
            stream.write(text + '\n')
        print('PIPELINE_EVENT ' + text, flush=True)

    def checkpoint(self):
        name = f'{self.stage}-{self.round}'
        candidate = self.root / 'checkpoints' / name
        candidate.parent.mkdir(exist_ok=True)
        files = snapshot(self.workspace, candidate)
        hashed = source_hash(files)
        results = []
        for check in self.spec['checks']:
            self.guard_validation(candidate, files)
            result = self.executor.run(candidate, self.validator, check['argv'], min(120, max(1, self.deadline - time.monotonic())))
            result.update(id=check['id'], source_hash=hashed, stage=self.stage, round=self.round)
            results.append(result)
            self.event('check_result', result=result)
            # Also guard AFTER the last check; a pre-check guard alone misses late changes.
            self.guard_validation(candidate, files)
        decision = decide_checks([c['id'] for c in self.spec['checks']], results,
                                 self.best['passed'] if self.best else (), baseline=not self.history)
        self.last_decision = decision
        record = {'name': name, 'hash': hashed, 'files': files, 'results': results,
                  'passed': decision['passed'], 'decision': decision}
        self.write(f'checkpoints/{name}.json', record)
        self.history.append(record)
        if decision['outcome'] in ('baseline', 'retain', 'accept'):
            self.best = record
        self.write('history.json', self.history)
        self.write('best.json', self.best)
        self.event('decision', checkpoint=name, source_hash=hashed, decision=decision)
        self.event('checkpoint', checkpoint=name, source_hash=hashed, passed=record['passed'],
                   best=self.best['name'] if self.best else '', best_hash=self.best['hash'] if self.best else '',
                   best_passed=self.best['passed'] if self.best else [])
        if decision['outcome'] == 'cancelled':
            raise InterruptedError('Validation cancelled')
        if decision['outcome'] == 'blocked':
            raise RuntimeError('Validation rejected: ' + decision['code'])
        return record

    def guard_validation(self, candidate, files):
        if self.runner.cancelled:
            raise InterruptedError('Validation cancelled')
        if time.monotonic() > self.deadline:
            raise TimeoutError('Run time budget exhausted')
        if digest(json.dumps(self.spec['checks'], sort_keys=True).encode()) != self.checks_hash:
            raise RuntimeError('Frozen check definitions changed')
        if manifest(self.validator) != self.validator_hash:
            raise RuntimeError('Frozen validator inputs changed')
        if manifest(candidate) != files:
            raise RuntimeError('Tested source changed during validation')

    def apply(self, proposal):
        # Build the entire patch off to the side. Failure cannot change the workspace.
        with tempfile.TemporaryDirectory(prefix='patch-', dir=self.root) as scratch:
            staged = Path(scratch) / 'source'
            snapshot(self.workspace, staged)
            self._apply_to(proposal, staged)
            manifest(staged)  # Enforce total source/file budgets before committing it.
            previous = Path(scratch) / 'previous'
            self.workspace.rename(previous)
            try:
                staged.rename(self.workspace)
            except BaseException:
                previous.rename(self.workspace)
                raise

    def _apply_to(self, proposal, workspace):
        if isinstance(proposal, dict) and set(proposal) == {'edits'}:
            if not isinstance(proposal['edits'], list) or len(proposal['edits']) > 30:
                raise ValueError('Edits must be a bounded list')
            files = {}
            for edit in proposal['edits']:
                if isinstance(edit, dict) and set(edit) == {'old', 'new'} and len(self.spec.get('editable', [])) == 1:
                    edit = {'path': self.spec['editable'][0], **edit}
                if not isinstance(edit, dict) or set(edit) != {'path', 'old', 'new'}:
                    raise ValueError('An edit requires path, old and new')
                name = edit['path']
                rel = Path(name)
                if rel.is_absolute() or '..' in rel.parts or not rel.parts or not allowed(rel):
                    raise ValueError('Edit path rejected')
                target = workspace / rel
                if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
                    raise ValueError('Edit symlink rejected')
                text = files.get(name, target.read_text())
                old, new = edit['old'], edit['new']
                if not isinstance(old, str) or not old or not isinstance(new, str) or text.count(old) != 1:
                    raise ValueError('Each old string must match exactly once')
                files[name] = text.replace(old, new, 1)
            proposal = {'files': files}
        if not isinstance(proposal, dict) or set(proposal) != {'files'} or not isinstance(proposal['files'], dict):
            raise ValueError('Model response must be JSON with only a files object')
        if len(proposal['files']) > 30:
            raise ValueError('Patch exceeds file budget')
        for name, text in proposal['files'].items():
            rel = Path(name)
            if rel.is_absolute() or '..' in rel.parts or not rel.parts or not allowed(rel):
                raise ValueError('Patch path rejected')
            if self.spec.get('editable') is not None and name not in self.spec['editable']:
                raise ValueError('File is outside explicit editable scope')
            if not isinstance(text, str) or len(text.encode()) > 256 * 1024:
                raise ValueError('Patch file exceeds size budget')
            # Reject link traversal even if a future backend introduced a link.
            target = workspace / rel
            if any(p.is_symlink() for p in [target, *target.parents]):
                raise ValueError('Patch symlink rejected')
        self.event('patch_proposed', files=list(proposal['files']))
        for name, text in proposal['files'].items():
            target = workspace / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)

    def restore_best(self):
        selected = self.root / 'checkpoints' / self.best['name']
        if manifest(selected) != self.best['files']:
            raise RuntimeError('Selected checkpoint changed after validation')
        shutil.rmtree(self.workspace)
        snapshot(selected, self.workspace)

    def reject_proposal(self, code, error):
        self.feedback = ('Rejected response: ' if code == 'invalid_response' else 'Rejected patch: ') + str(error)
        self.last_decision = {'outcome': 'reject', 'code': code,
                              'gates': {'proposal': False, 'acceptance': None, 'non_regression': None}}
        self.event('proposal_rejected', error=self.feedback, decision=self.last_decision)

    def packet(self, reason):
        self.restore_best()
        base = self.history[0]
        diff = []
        for name in sorted(set(base['files']) | set(self.best['files'])):
            old = self.root / 'checkpoints' / base['name'] / name
            new = self.workspace / name
            try:
                diff.extend(difflib.unified_diff(old.read_text().splitlines(True) if old.exists() else [],
                    new.read_text().splitlines(True) if new.exists() else [], fromfile='a/' + name, tofile='b/' + name))
            except UnicodeError:
                diff.append(f'Binary file changed: {name}\n')
        packet = {'version': 1, 'goal': self.goal, 'reason': reason, 'acceptance': self.spec,
                  'validator_hashes': self.validator_hash, 'baseline': base, 'selected': self.best,
                  'remaining': [r for r in self.best['results'] if r['status'] != 'succeeded'],
                  'attempts': [{'name': r['name'], 'hash': r['hash'], 'passed': r['passed'],
                                'changed_files': [name for name in sorted(set(base['files']) | set(r['files']))
                                                  if base['files'].get(name) != r['files'].get(name)]}
                               for r in self.history],
                  'decision': self.last_decision,
                  'diff': ''.join(diff), 'environment': {'image': self.executor.image, 'network': 'none'}}
        self.write('handoff.json', packet)
        (self.root / 'proposed.patch').write_text(self.clean(packet['diff']))
        return packet

    def prompt(self, packet=None):
        source = {}
        size = 0
        for name in manifest(self.workspace):
            if self.spec.get('editable') is not None and name not in self.spec['editable']:
                continue
            try:
                text = (self.workspace / name).read_text()
            except UnicodeError:
                continue
            ranges = self.spec.get('context', {}).get(name)
            if ranges is not None:
                lines = text.splitlines(keepends=True)
                text = ''.join(f'Lines {start}-{end}:\n' + ''.join(lines[start-1:end]) for start, end in ranges)
            size += len(text.encode())
            if size > 192 * 1024:
                raise ValueError('Source exceeds model context budget; choose a narrower project')
            source[name] = self.clean(text)
        return self.clean(json.dumps({'goal': self.goal, 'stage': self.stage, 'round': self.round,
            'controller': {'policy_version': 1, 'last_decision': self.last_decision,
                'attempts_used': self.attempts_used, 'attempt_limit': self.round_limit,
                'workspace_checkpoint': self.best['name'], 'workspace_hash': source_hash(manifest(self.workspace)),
                'next_action': 'propose_patch'},
            'source': source, 'editable_files': self.spec.get('editable', list(source)), 'last_feedback': self.feedback, 'last_proposal': self.last_proposal,
            'baseline': {k:v for k,v in self.history[0].items() if k != 'files'},
            'current': {k:v for k,v in self.history[-1].items() if k != 'files'},
            'handoff': packet, 'instruction': 'Return ONLY JSON {"files":{"relative/path":"complete content"}} or {"edits":[{"path":"relative/path","old":"unique exact text","new":"replacement"}]}. Repair source. Acceptance checks are frozen externally. Do not change tests. If editable_files contains exactly one file, omit path in edits and replace the entire shown function/class excerpt using one unique old/new edit.'}))

    def run(self, local, cloud=None, rounds=3):
        if not 1 <= rounds <= 10:
            raise ValueError('rounds must be 1..10')
        status, reason, reason_code = 'blocked', '', 'startup_blocked'
        self.round_limit = rounds * (2 if cloud is not None else 1)
        self.write('policy.json', {'version': 1, 'rounds_per_stage': rounds, 'attempt_limit': self.round_limit,
                                  'gates': ['proposal', 'acceptance', 'non_regression'],
                                  'repeat_rejection_limit': 2, 'checks_hash': self.checks_hash,
                                  'validator_hashes': self.validator_hash})
        try:
            self.executor.prepare()
            self.write('environment.json', {'image': self.executor.image, 'network': 'none', 'cpus': 2,
                                           'memory': '1g', 'pids': 128, 'backend': self.backend})
            record = self.checkpoint()
            if record['decision']['gates']['acceptance']:
                status, reason, reason_code = 'unverified', 'All checks already pass at baseline; no repair progress demonstrated', 'baseline_already_passed'
            else:
                for stage, provider in [('local', local), ('cloud', cloud)]:
                    if provider is None:
                        continue
                    self.stage = stage
                    packet = self.packet('Local stage exhausted or stalled') if stage == 'cloud' else None
                    seen = set()
                    rejected = set()
                    for round_number in range(1, rounds + 1):
                        if self.runner.cancelled:
                            raise InterruptedError('Cancelled')
                        if time.monotonic() > self.deadline:
                            raise TimeoutError('Run budget exhausted')
                        self.round = round_number
                        self.attempts_used += 1
                        self.event('model_request', provider=getattr(provider, 'provider', 'test'), model=getattr(provider, 'model', 'test'))
                        request_started = time.monotonic()
                        try:
                            proposal = provider(self.prompt(packet))
                            self.last_proposal = proposal
                            self.write(f'model-{stage}-{round_number}.json', proposal)
                            self.event('model_response', provider=getattr(provider, 'provider', 'test'),
                                       duration=time.monotonic() - request_started)
                        except InterruptedError:
                            raise
                        except TimeoutError as error:
                            self.event('provider_failure', provider=getattr(provider, 'provider', 'test'), status='timed_out', error=str(error))
                            if stage == 'local' and cloud is not None:
                                reason = 'Local model request timed out'
                                break
                            raise
                        except json.JSONDecodeError as error:
                            self.reject_proposal('invalid_response', error)
                            key = ('invalid_response', str(error))
                            if key in rejected:
                                reason, reason_code = 'Repeated invalid model response', 'repeated_rejection'
                                break
                            rejected.add(key)
                            continue
                        except Exception as error:
                            self.event('provider_failure', provider=getattr(provider, 'provider', 'test'), error=self.clean(str(error)))
                            reason = f"{stage} provider failed: {self.clean(str(error))}"
                            if stage == 'local' and cloud is not None:
                                break
                            raise
                        if self.runner.cancelled:
                            raise InterruptedError('Cancelled')
                        try:
                            self.apply(proposal)
                        except (ValueError, OSError) as error:
                            self.reject_proposal('invalid_patch', error)
                            key = ('invalid_patch', digest(json.dumps(proposal, sort_keys=True).encode()))
                            if key in rejected:
                                reason, reason_code = 'Repeated rejected patch', 'repeated_rejection'
                                break
                            rejected.add(key)
                            continue
                        self.feedback = ''
                        record = self.checkpoint()
                        if record['decision']['outcome'] == 'accept':
                            status, reason, reason_code = 'passed_checks', 'All frozen checks passed with progress from baseline', 'required_checks_passed'
                            break
                        if record['hash'] in seen or record['hash'] == self.history[-2]['hash']:
                            reason, reason_code = 'Repeated candidate or no source progress', 'repeated_candidate'
                            break
                        seen.add(record['hash'])
                        # Next attempt starts from the best non-regressing checkpoint.
                        self.restore_best()
                    if status == 'passed_checks':
                        break
                if status != 'passed_checks':
                    status = 'failed'
                    reason = reason or 'Repair round budget exhausted'
                    if reason_code == 'startup_blocked':
                        reason_code = 'round_budget_exhausted'
        except InterruptedError as error:
            status, reason, reason_code = 'cancelled', str(error), 'cancelled'
        except TimeoutError as error:
            status, reason, reason_code = 'timed_out', str(error), 'deadline_exceeded'
        except Exception as error:
            status, reason, reason_code = 'blocked', self.clean(str(error)), 'execution_blocked'
        finally:
            if self.best:
                try:
                    self.packet(reason)
                except Exception as error:
                    status, reason, reason_code = 'blocked', self.clean(str(error)), 'checkpoint_integrity_failed'
            if self.runner.cancelled:
                status, reason, reason_code = 'cancelled', 'Cancelled', 'cancelled'
            result = {'version': 1, 'id': self.id, 'status': status, 'reason': reason,
                      'reason_code': reason_code, 'decision': self.last_decision, 'attempts_used': self.attempts_used,
                      'best': self.best['name'] if self.best else None, 'evidence': str(self.root)}
            self.write('result.json', result)
            self.event('finished', result=result)
        return result

class ModelPatchProvider:
    """Text-only file proposal via configured APIs. Never grant a model host tools."""
    def __init__(self, dispatcher, provider, model):
        if provider not in ('ollama', 'openai', 'gemini', 'anthropic', 'claude-text'):
            raise ValueError('Use Ollama, a direct API, or the tools-disabled Claude text adapter')
        if not model:
            raise ValueError('An explicit model is required for isolated repair')
        self.dispatcher, self.provider, self.model = dispatcher, provider, model

    def __call__(self, prompt):
        system = 'You repair disposable source. Respond only with valid JSON: a files object of complete replacement files, or an edits list with old (unique exact string) and new; include path unless there is exactly one explicitly editable file. No Markdown or shell commands.'
        # Use text transports directly so diagnosis formatting is not the protocol.
        if len(prompt.encode()) > 512 * 1024:
            raise ValueError('Evidence exceeds model context budget; narrow the target/check output')
        previous_mode = getattr(self.dispatcher, 'json_mode', False)
        self.dispatcher.json_mode = self.provider == 'ollama'
        try:
            response = self.dispatcher.query(prompt, system, provider=self.provider, model=self.model)
        finally:
            self.dispatcher.json_mode = previous_mode
        if len(response.encode()) > 512 * 1024:
            raise ValueError('Model response exceeds patch budget')
        # A single fenced JSON object is common; arbitrary prose/errors stay rejected.
        response = response.strip()
        fenced = re.fullmatch(r"```(?:json)?\s*\n([\s\S]*?)\n```", response)
        if fenced:
            response = fenced.group(1)
        return json.loads(response)
