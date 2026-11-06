import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { extname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const ignored = new Set(['.git', '.build', '.swiftpm', 'node_modules', 'dist', 'DerivedData', '.derivedData']);
const files = [];
function visit(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || ignored.has(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) visit(path);
    else files.push(path);
  }
}
visit(root);

const failures = [];
const sources = files.filter(path => ['.js', '.mjs', '.swift', '.py', '.json'].includes(extname(path)));
for (const path of sources) {
  const text = readFileSync(path, 'utf8');
  const name = relative(root, path);
  if (!text.endsWith('\n')) failures.push(`${name}: missing final newline`);
  text.split('\n').forEach((line, index) => {
    if (/[\t ]+$/.test(line)) failures.push(`${name}:${index + 1}: trailing whitespace`);
  });
  if (path.endsWith('.json')) {
    try { JSON.parse(text); }
    catch (error) { failures.push(`${name}: ${error.message}`); }
  }
}

function check(command, args) {
  try { execFileSync(command, args, { cwd: root, stdio: 'pipe' }); }
  catch (error) {
    failures.push(`${command} ${args.join(' ')}\n${error.stderr?.toString() || error.message}`);
  }
}

const javascript = sources.filter(path => ['.js', '.mjs'].includes(extname(path)));
for (const path of javascript) check(process.execPath, ['--check', path]);

const python = sources.filter(path => path.endsWith('.py'));
if (python.length) {
  check('python3', ['-c', 'import ast, pathlib, sys; [ast.parse(pathlib.Path(p).read_text(), filename=p) for p in sys.argv[1:]]', ...python]);
}

if (process.platform === 'darwin') {
  const swift = sources.filter(path => path.endsWith('.swift') && !path.endsWith('Package.swift'));
  if (swift.length) check('xcrun', ['swiftc', '-frontend', '-parse', ...swift]);
  check('plutil', ['-lint', 'native/FormFlow.xcodeproj/project.pbxproj']);
}

if (failures.length) {
  console.error(failures.join('\n'));
  process.exitCode = 1;
} else {
  console.log(`Lint passed: ${sources.length} source/data files, ${javascript.length} JavaScript syntax checks${process.platform === 'darwin' ? ', Swift syntax and Xcode project checks' : ''}.`);
}
