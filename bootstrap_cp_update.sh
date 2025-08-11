#!/usr/bin/env bash
set -euo pipefail

# set these to match the installed Extension ID so it updates in place
PUBLISHER="your-name-or-org"
NAME="coding-partner-chatui"
VERSION="0.3.0"
APP_DIR="${NAME}-build"

# code CLI optional
if command -v code >/dev/null 2>&1; then SKIP_CODE=0; else SKIP_CODE=1; fi

# get key
if [ "${1-}" != "" ]; then
  OPENAI_KEY="$1"
else
  read -r -s -p "OpenAI API key: " OPENAI_KEY; echo
fi
[ -z "${OPENAI_KEY}" ] && { echo "no key provided"; exit 1; }

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/media"

cat > "$APP_DIR/package.json" <<JSON
{
  "name": "$NAME",
  "displayName": "Coding Partner Chat UI",
  "description": "Chat, inline suggestions, repo context, PR tools, multi-file edits.",
  "version": "$VERSION",
  "publisher": "$PUBLISHER",
  "license": "MIT",
  "engines": { "vscode": "^1.95.0" },
  "categories": ["Other"],
  "main": "./extension.js",
  "contributes": {
    "viewsContainers": {
      "activitybar": [
        { "id": "coding-partner", "title": "Coding Partner", "icon": "media/icon.svg" }
      ]
    },
    "views": {
      "coding-partner": [
        { "type": "webview", "name": "Chat", "id": "coding-partner.chat" }
      ]
    },
    "commands": [
      { "command": "coding-partner-chatui.openChat", "title": "Coding Partner Open Chat" },
      { "command": "coding-partner-chatui.setApiKey", "title": "Coding Partner Set API Key" },
      { "command": "coding-partner-chatui.applyLastCodeBlock", "title": "Coding Partner Apply Last Code Block" },
      { "command": "coding-partner-chatui.toggleInline", "title": "Coding Partner Toggle Inline Completions" },
      { "command": "coding-partner-chatui.prSummary", "title": "Coding Partner Generate PR Summary" },
      { "command": "coding-partner-chatui.reviewDiff", "title": "Coding Partner Review Diff" },
      { "command": "coding-partner-chatui.previewMultiEdit", "title": "Coding Partner Preview Multi File Edit" },
      { "command": "coding-partner-chatui.applyMultiEdit", "title": "Coding Partner Apply Multi File Edit" },
      { "command": "coding-partner-chatui.diagnoseKey", "title": "Coding Partner Diagnose Key" },
      { "command": "coding-partner-chatui.runTaskWithAssist", "title": "Coding Partner Run Task With Assist" },
      { "command": "coding-partner-chatui.reindexRepo", "title": "Coding Partner Reindex Repo" }
    ],
    "configuration": {
      "title": "Coding Partner",
      "properties": {
        "coding-partner-chatui.provider": { "type": "string", "enum": ["openai","anthropic","google"], "default": "openai" },
        "coding-partner-chatui.model": { "type": "string", "default": "gpt-4o-mini" },
        "coding-partner-chatui.apiBase": { "type": "string", "default": "https://api.openai.com/v1" },
        "coding-partner-chatui.apiKey": { "type": "string", "default": "" },
        "coding-partner-chatui.anthropicKey": { "type": "string", "default": "" },
        "coding-partner-chatui.googleKey": { "type": "string", "default": "" },
        "coding-partner-chatui.enableInline": { "type": "boolean", "default": true },
        "coding-partner-chatui.review.guidelines": {
          "type": "string",
          "default": "Keep changes minimal. Enforce project style. Flag security, performance, and API breaks.",
          "markdownDescription": "Guidelines for AI code review."
        }
      }
    }
  },
  "activationEvents": [
    "onView:coding-partner.chat",
    "onCommand:coding-partner-chatui.openChat",
    "onCommand:coding-partner-chatui.setApiKey",
    "onCommand:coding-partner-chatui.applyLastCodeBlock",
    "onCommand:coding-partner-chatui.toggleInline",
    "onCommand:coding-partner-chatui.prSummary",
    "onCommand:coding-partner-chatui.reviewDiff",
    "onCommand:coding-partner-chatui.previewMultiEdit",
    "onCommand:coding-partner-chatui.applyMultiEdit",
    "onCommand:coding-partner-chatui.diagnoseKey",
    "onCommand:coding-partner-chatui.runTaskWithAssist",
    "onCommand:coding-partner-chatui.reindexRepo",
    "onUri"
  ],
  "devDependencies": { "vsce": "^2.15.0" }
}
JSON

cat > "$APP_DIR/media/icon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
<rect x="3" y="3" width="18" height="18" rx="3" ry="3"></rect>
<path d="M7 8h10M7 12h7M7 16h5"></path>
</svg>
SVG

# extension with
# nonce in script
# streaming with retry and error text
# repo context
# review report
# multi file edits JSON format
# task helper
cat > "$APP_DIR/extension.js" <<'JS'
const vscode = require('vscode');
const cp = require('child_process');

let lastCodeBlock;
let lastMultiEdit; // {changes:[{path, content}]}

function cfg() { return vscode.workspace.getConfiguration('coding-partner-chatui'); }

async function getKey(provider) {
  const sec = await globalThis.__cp_secret_get?.('coding-partner-chatui.apiKey');
  if (sec) return sec;
  if (provider === 'openai') return cfg().get('apiKey') || process.env.OPENAI_API_KEY;
  if (provider === 'anthropic') return cfg().get('anthropicKey') || process.env.ANTHROPIC_API_KEY;
  if (provider === 'google') return cfg().get('googleKey') || process.env.GOOGLE_API_KEY || process.env.GEMINI_API_KEY;
}

function model() {
  return {
    provider: cfg().get('provider') || 'openai',
    model: cfg().get('model') || 'gpt-4o-mini',
    apiBase: cfg().get('apiBase') || 'https://api.openai.com/v1'
  };
}

async function askOnce(payload, m) {
  const key = await getKey(m.provider);
  if (!key) throw new Error('missing api key');
  if (m.provider === 'openai') {
    const r = await fetch(m.apiBase.replace(/\/$/, '') + '/chat/completions', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: m.model,
        temperature: 0.2,
        messages: [
          { role: 'system', content: 'Return only the code or short text requested.' },
          { role: 'user', content: JSON.stringify(payload) }
        ]
      })
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`HTTP ${r.status} ${(j.error?.message || '')}`.trim());
    return j.choices?.[0]?.message?.content?.trim() || '';
  }
  throw new Error('provider not implemented');
}

async function askStream(messages, m, onChunk) {
  const key = await getKey(m.provider);
  if (!key) throw new Error('missing api key');
  if (m.provider !== 'openai') throw new Error('streaming only for openai in this build');
  const url = m.apiBase.replace(/\/$/, '') + '/chat/completions';

  let lastCall = Number(globalThis.__cp_last || 0);
  const gap = Date.now() - lastCall;
  if (gap < 1200) await new Promise(r => setTimeout(r, 1200 - gap));
  globalThis.__cp_last = Date.now();

  for (let attempt = 1; attempt <= 3; attempt++) {
    const resp = await fetch(url, {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: m.model, temperature: 0.2, stream: true, messages })
    });
    if (!resp.ok || !resp.body) {
      const txt = await resp.text().catch(() => '');
      if (resp.status === 429 && attempt < 3) { await new Promise(r => setTimeout(r, attempt * 1500)); continue; }
      throw new Error(`HTTP ${resp.status} ${txt.slice(0,300)}`.trim());
    }
    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    while (true) {
      const { value, done } = await reader.read();
      if (done) return;
      buffer += decoder.decode(value, { stream: true });
      const parts = buffer.split('\n\n'); buffer = parts.pop() || '';
      for (const part of parts) {
        const line = part.trim(); if (!line.startsWith('data:')) continue;
        const data = line.slice(5).trim(); if (data === '[DONE]') return;
        try { const j = JSON.parse(data); const delta = j.choices?.[0]?.delta?.content; if (delta) onChunk(delta); } catch {}
      }
    }
  }
}

function extractLastCode(md) {
  const re = /```[\w+-]*\n([\s\S]*?)\n```/g;
  let m, last; while ((m = re.exec(md)) !== null) last = m[1];
  return last;
}

function extractLastJson(md) {
  const re = /```json\s+([\s\S]*?)\s+```/g;
  let m, last; while ((m = re.exec(md)) !== null) last = m[1];
  try { return last ? JSON.parse(last) : undefined; } catch { return undefined; }
}

async function repoContext(limit = 12) {
  const ignore = ['**/{node_modules,.git,dist,out,build,.next,target}/**'];
  const masks = ['**/*.{ts,tsx,js,jsx,py,cs,java,kt,go,rs,rb,php,swift,scala,sql}', '**/*.{json,yml,yaml,md}'];
  const uris = new Map();
  for (const pat of masks) {
    for (const u of await vscode.workspace.findFiles(pat, `{${ignore.join(',')}}`, limit * 2)) {
      uris.set(u.fsPath, u);
    }
  }
  const uniq = Array.from(uris.values()).slice(0, limit);
  const picks = [];
  for (const u of uniq) {
    try {
      const doc = await vscode.workspace.openTextDocument(u);
      const head = doc.getText(new vscode.Range(0,0, Math.min(400, doc.lineCount-1), 999));
      picks.push({ path: vscode.workspace.asRelativePath(u), head });
    } catch {}
  }
  const open = vscode.window.visibleTextEditors.map(e => ({ path: vscode.workspace.asRelativePath(e.document.uri), lang: e.document.languageId }));
  return { open, picks };
}

function chatHtml(webview) {
  const csp = webview.cspSource; const nonce = String(Math.random()).slice(2);
  return `<!doctype html>
<html><head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${csp} https: data:; style-src ${csp} 'unsafe-inline'; script-src ${csp} 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
html,body{height:100%} body{margin:0;color:var(--vscode-foreground);background:var(--vscode-sideBar-background);display:grid;grid-template-rows:auto 1fr auto}
header{display:flex;gap:8px;align-items:center;padding:8px 12px;border-bottom:1px solid var(--vscode-editorWidget-border)}
header .spacer{flex:1} header button{background:transparent;border:0;color:inherit;cursor:pointer}
#history{padding:12px;overflow:auto;background:var(--vscode-editor-background)}
.msg{max-width:900px;margin:12px auto;padding:10px 12px;border-radius:8px}
.user{background:rgba(64,128,255,.10)} .ai{background:rgba(255,255,255,.04)}
#composer{border-top:1px solid var(--vscode-editorWidget-border);padding:10px 12px}
#bar{max-width:900px;margin:0 auto;display:grid;gap:8px}
#row1{display:flex;gap:8px;align-items:center}
#prompt{flex:1;min-height:44px;max-height:160px;resize:vertical;border:1px solid var(--vscode-editorWidget-border);border-radius:8px;padding:10px 12px;background:var(--vscode/input-background);color:var(--vscode/input-foreground)}
#send{padding:10px 14px;border-radius:8px;border:0;cursor:pointer;background:var(--vscode-button-background);color:var(--vscode-button-foreground)}
#send:hover{background:var(--vscode-button-hoverBackground)}
.hint{color:var(--vscode-descriptionForeground);font-size:12px;margin-left:auto}
</style>
</head>
<body>
<header><strong>Chat</strong><span class="spacer"></span><button id="settingsBtn">⚙️</button><button id="keyBtn">🔑</button><button id="applyBtn">📥</button></header>
<div id="history"></div>
<div id="composer"><div id="bar"><div id="row1"><textarea id="prompt" placeholder="Ask about your code"></textarea><button id="send">Send</button></div><div class="hint" id="hint"></div></div></div>
<script nonce="${nonce}">
const vscode = acquireVsCodeApi();
const history = document.getElementById('history'); const promptEl = document.getElementById('prompt'); const hintEl = document.getElementById('hint');
let streaming = false;
function add(type, text){ const d=document.createElement('div'); d.className='msg '+(type==='user'?'user':'ai'); d.textContent=text; history.appendChild(d); history.scrollTop=history.scrollHeight; }
document.getElementById('send').addEventListener('click', () => { if (streaming) return; const prompt = promptEl.value.trim(); if (!prompt) return; add('user', prompt); hintEl.textContent=''; vscode.postMessage({ type:'sendPrompt', prompt }); });
document.getElementById('applyBtn').addEventListener('click', () => vscode.postMessage({ type:'apply' }));
document.getElementById('keyBtn').addEventListener('click', () => { const v = prompt('Enter OpenAI API key'); vscode.postMessage({ type:'setApiKey', value: v || '' }); });
document.getElementById('settingsBtn').addEventListener('click', () => vscode.postMessage({ type:'openSettings' }));
window.addEventListener('message', e => { const m=e.data; if (m.type==='start'){ streaming=true; add('ai','…'); } else if (m.type==='stream'){ const last=history.lastElementChild; if (last&&last.classList.contains('ai')) { last.textContent+=m.chunk; history.scrollTop=history.scrollHeight; } } else if (m.type==='done'){ streaming=false; hintEl.textContent=m.hasCode?'Use Coding Partner Apply Last Code Block':''; } else if (m.type==='error'){ streaming=false; add('ai', m.text); } else if (m.type==='info'){ add('ai', m.text); } });
</script>
</body></html>`;
}

class ChatProvider {
  constructor(context){ this.context = context; }
  resolveWebviewView(view) {
    const w = view.webview; w.options = { enableScripts: true }; w.html = chatHtml(w);
    w.onDidReceiveMessage(async (msg) => {
      if (msg?.type === 'sendPrompt') { await this.handle(w, msg.prompt); }
      else if (msg?.type === 'apply') { await vscode.commands.executeCommand('coding-partner-chatui.applyLastCodeBlock'); }
      else if (msg?.type === 'setApiKey') { await this.context.secrets.store('coding-partner-chatui.apiKey', msg.value || ''); w.postMessage({ type:'info', text:'Key saved' }); }
      else if (msg?.type === 'openSettings') { await vscode.commands.executeCommand('workbench.action.openSettings', '@ext:' + PUBLISHER + '.' + NAME); }
    });
  }
  async handle(webview, prompt) {
    const m = model();
    const editor = vscode.window.activeTextEditor;
    const sel = editor && !editor.selection.isEmpty ? editor.document.getText(editor.selection) : undefined;
    const body = editor?.document.getText();
    const ctx = await repoContext(12);
    const lines = [];
    if (sel) lines.push('Selected code', '```', sel, '```');
    else if (body && body.length <= 60000) lines.push('Active file', '```', body, '```');
    lines.push('Repo context sample', '```json', JSON.stringify(ctx, null, 2), '```');

    const sys = [
      'You are Coding Partner. Be precise.',
      'For multi-file edits return a JSON block like:',
      '```json',
      '{ "changes": [ {"path":"relative/path.ext","content":"full new content"} ] }',
      '```'
    ].join('\n');

    const messages = [
      { role:'system', content: sys },
      { role:'user', content: [prompt, lines.join('\n')].join('\n\n') }
    ];

    try {
      webview.postMessage({ type:'start' });
      let full = '';
      await askStream(messages, m, chunk => { full += chunk; webview.postMessage({ type:'stream', chunk }); });
      lastCodeBlock = extractLastCode(full);
      lastMultiEdit = extractLastJson(full);
      webview.postMessage({ type:'done', hasCode: !!lastCodeBlock });
    } catch (err) {
      webview.postMessage({ type:'error', text: 'OpenAI request failed. ' + (err?.message || 'Unknown') });
    }
  }
}

async function prSummary() {
  const diff = await collectDiff();
  if (!diff) return vscode.window.showWarningMessage('no changes to summarize');
  const text = await askOnce({
    intent: 'pr-summary',
    prompt: 'Summarize diff. Sections overview motivation notable changes risks testing breaking changes commit message.',
    attachments: [{ name: 'diff.patch', content: diff }]
  }, model());
  const ws = vscode.workspace.workspaceFolders?.[0]?.uri; if (!ws) return;
  const uri = vscode.Uri.joinPath(ws, 'PR_DESCRIBE.md');
  await vscode.workspace.fs.writeFile(uri, Buffer.from(text || '# PR Summary\n', 'utf8'));
  await vscode.window.showTextDocument(uri);
}

async function reviewDiff() {
  const diff = await collectDiff();
  if (!diff) return vscode.window.showWarningMessage('no changes to review');
  const guide = cfg().get('review.guidelines') || '';
  const text = await askOnce({
    intent: 'review',
    prompt: 'Act as code reviewer. Use guidelines below. Output markdown with issues, risks, suggestions, and ready to commit checklist.',
    guidelines: guide,
    attachments: [{ name: 'diff.patch', content: diff }]
  }, model());
  const ws = vscode.workspace.workspaceFolders?.[0]?.uri; if (!ws) return;
  const uri = vscode.Uri.joinPath(ws, 'PR_REVIEW.md');
  await vscode.workspace.fs.writeFile(uri, Buffer.from(text || '# Review\n', 'utf8'));
  await vscode.window.showTextDocument(uri);
}

async function collectDiff() {
  try {
    const api = vscode.extensions.getExtension('vscode.git')?.exports?.getAPI?.(1);
    const repo = api?.repositories?.[0];
    if (repo?.rootUri) {
      const staged = await exec(['diff','--staged'], repo.rootUri.fsPath);
      const unstaged = await exec(['diff'], repo.rootUri.fsPath);
      return [staged, unstaged].filter(Boolean).join('\n');
    }
  } catch {}
  const ws = vscode.workspace.workspaceFolders?.[0]?.uri?.fsPath;
  if (!ws) return '';
  return await exec(['diff'], ws);
}

function exec(args, cwd) {
  return new Promise((resolve) => {
    if (!cwd) return resolve('');
    const p = cp.spawn('git', args, { cwd });
    let out = ''; p.stdout.on('data', d => out += d.toString());
    p.on('close', code => resolve(code === 0 ? out.trim() : ''));
  });
}

async function previewMultiEdit() {
  if (!lastMultiEdit?.changes?.length) return vscode.window.showWarningMessage('no multi-file edit in last reply');
  const ws = vscode.workspace.workspaceFolders?.[0]?.uri; if (!ws) return;
  for (const ch of lastMultiEdit.changes) {
    const uri = vscode.Uri.joinPath(ws, ch.path);
    const left = uri;
    const right = uri.with({ scheme: 'untitled', path: uri.path + '.cp-preview' });
    await vscode.workspace.fs.writeFile(right, Buffer.from(ch.content, 'utf8')).catch(()=>{});
    await vscode.commands.executeCommand('vscode.diff', left, right, 'Preview ' + ch.path);
  }
}

async function applyMultiEdit() {
  if (!lastMultiEdit?.changes?.length) return vscode.window.showWarningMessage('no multi-file edit in last reply');
  const ws = vscode.workspace.workspaceFolders?.[0]?.uri; if (!ws) return;
  const we = new vscode.WorkspaceEdit();
  for (const ch of lastMultiEdit.changes) {
    const uri = vscode.Uri.joinPath(ws, ch.path);
    we.set(uri, [vscode.TextEdit.replace(new vscode.Range(0,0, Number.MAX_SAFE_INTEGER, 0), ch.content)]);
  }
  await vscode.workspace.applyEdit(we);
  vscode.window.showInformationMessage('applied multi-file edit');
}

async function runTaskWithAssist() {
  const m = model();
  const cmd = await vscode.window.showInputBox({ prompt:'shell command to run', placeHolder:'npm test' }); if (!cmd) return;
  const explain = await askOnce({ intent:'cli', prompt:'Explain this command and risks', command: cmd }, m);
  const pick = await vscode.window.showQuickPick(['Run','Cancel'], { placeHolder: (explain || 'Run command').slice(0,200) });
  if (pick !== 'Run') return;
  const task = new vscode.Task({ type:'shell' }, vscode.TaskScope.Workspace, 'Run with Coding Partner', 'Coding Partner', new vscode.ShellExecution(cmd));
  vscode.tasks.executeTask(task);
}

function activate(context) {
  globalThis.PUBLISHER = '${PUBLISHER}'; // for settings link
  globalThis.NAME = '${NAME}';
  globalThis.__cp_secret_get = (k) => context.secrets.get(k);

  context.subscriptions.push(vscode.window.registerWebviewViewProvider('coding-partner.chat', new ChatProvider(context), { webviewOptions: { retainContextWhenHidden: true } }));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.openChat', () => vscode.commands.executeCommand('workbench.view.extension.coding-partner')));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.setApiKey', async () => {
    const v = await vscode.window.showInputBox({ title:'Enter OpenAI API Key', password:true, ignoreFocusOut:true }); if (v) { await context.secrets.store('coding-partner-chatui.apiKey', v); vscode.window.showInformationMessage('key saved'); }
  }));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.applyLastCodeBlock', async () => {
    const ed = vscode.window.activeTextEditor; if (!ed) return vscode.window.showWarningMessage('open a file');
    if (!lastCodeBlock) return vscode.window.showWarningMessage('no code block');
    await ed.edit(e => {
      const sel = ed.selection;
      if (sel && !sel.isEmpty) e.replace(sel, lastCodeBlock);
      else {
        const end = ed.document.lineAt(ed.document.lineCount - 1).range.end;
        e.replace(new vscode.Range(0,0,end.line,end.character), lastCodeBlock);
      }
    });
    vscode.window.showInformationMessage('applied');
  }));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.toggleInline', async () => {
    const c = cfg(); const cur = c.get('enableInline') !== false; await c.update('enableInline', !cur, vscode.ConfigurationTarget.Global);
    vscode.window.showInformationMessage('inline ' + (!cur ? 'enabled' : 'disabled'));
  }));
  // inline provider basic
  context.subscriptions.push(vscode.languages.registerInlineCompletionItemProvider({ pattern: "**" }, {
    provideInlineCompletionItems: async (doc, pos) => {
      if (cfg().get('enableInline') === false) return;
      try {
        const before = doc.getText(new vscode.Range(Math.max(0, pos.line-20),0,pos.line,pos.character));
        const text = await askOnce({ intent:'inline', line: doc.lineAt(pos.line).text.slice(0,pos.character), prefix: before, languageId: doc.languageId }, model());
        if (!text) return;
        return { items: [ { insertText: text } ] };
      } catch { return; }
    }
  }));

  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.prSummary', prSummary));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.reviewDiff', reviewDiff));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.previewMultiEdit', previewMultiEdit));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.applyMultiEdit', applyMultiEdit));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.diagnoseKey', async () => {
    const sec = await context.secrets.get('coding-partner-chatui.apiKey'); vscode.window.showInformationMessage('secret ' + (sec ? 'set' : 'missing'));
  }));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.runTaskWithAssist', runTaskWithAssist));
  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-chatui.reindexRepo', async () => { const c = await repoContext(20); vscode.window.showInformationMessage('indexed ' + c.picks.length + ' files'); }));

  // uri handler to store key
  context.subscriptions.push(vscode.window.registerUriHandler({
    handleUri: async (uri) => {
      if (uri.authority !== '${PUBLISHER}.${NAME}') return;
      const params = new URLSearchParams(uri.query);
      const action = (uri.path || '').replace(/^\//,'');
      if (action === 'installKey') {
        const value = params.get('value') || '';
        if (value) { await context.secrets.store('coding-partner-chatui.apiKey', value); vscode.window.showInformationMessage('key saved from link'); }
      }
    }
  }));
}

function deactivate(){}

module.exports = { activate, deactivate };
JS

pushd "$APP_DIR" >/dev/null
npx --yes vsce@2.15.0 package >/dev/null
VSIX="$(ls -1 *.vsix | head -n1)"
popd >/dev/null

if [ "$SKIP_CODE" -eq 0 ]; then
  code --install-extension "$APP_DIR/$VSIX"
  echo "installed $VSIX"
else
  echo "no code CLI"
  echo "install from VSIX"
  echo "$(pwd)/$APP_DIR/$VSIX"
fi

# store key through URI handler
URLENC_KEY="$(python3 - <<PY
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
"$OPENAI_KEY"
)"
open "vscode://$PUBLISHER.$NAME/installKey?provider=openai&value=$URLENC_KEY" >/dev/null 2>&1 || true
echo "key stored in Secret Storage"
echo "open the Coding Partner panel and test"
