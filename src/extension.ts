import * as vscode from 'vscode';

let lastCodeBlock: string | undefined;

export function activate(context: vscode.ExtensionContext) {
  (globalThis as any).__cp_getKey = async () => await context.secrets.get('coding-partner-openai.apiKey');
  (globalThis as any).__cp_promptKey = async () => {
    const val = await vscode.window.showInputBox({ title: 'Enter OpenAI API Key', password: true, ignoreFocusOut: true });
    if (val) { await context.secrets.store('coding-partner-openai.apiKey', val); return val; }
    return undefined;
  };

  const participant = vscode.chat.createChatParticipant('coding-partner-openai.partner', handler);
  context.subscriptions.push(participant);

  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-openai.setApiKey', async () => {
    const val = await vscode.window.showInputBox({
      title: 'Enter OpenAI API Key', prompt: 'Stored in VS Code Secret Storage', password: true, ignoreFocusOut: true
    });
    if (val) { await context.secrets.store('coding-partner-openai.apiKey', val); vscode.window.showInformationMessage('Coding Partner OpenAI key saved'); }
  }));

  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-openai.applyLastCodeBlock', async () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor) { vscode.window.showWarningMessage('Open a file first'); return; }
    if (!lastCodeBlock) { vscode.window.showWarningMessage('No code block captured from the last reply'); return; }
    await editor.edit(edit => {
      const selection = editor.selection;
      if (selection && !selection.isEmpty) { edit.replace(selection, lastCodeBlock!); }
      else {
        const full = new vscode.Range(new vscode.Position(0, 0), editor.document.lineAt(editor.document.lineCount - 1).range.end);
        edit.replace(full, lastCodeBlock!);
      }
    });
    vscode.window.showInformationMessage('Applied code block');
  }));

  context.subscriptions.push(vscode.commands.registerCommand('coding-partner-openai.openReadme', async () => {
    const uri = vscode.Uri.joinPath(context.extensionUri, 'README.md');
    try { await vscode.commands.executeCommand('markdown.showPreview', uri); }
    catch { await vscode.commands.executeCommand('vscode.open', uri); }
  }));
}

async function* openAIStream(apiKey: string, model: string, apiBase: string, messages: any, temperature: number, token: vscode.CancellationToken): AsyncGenerator<string> {
  const resp = await fetch(apiBase.replace(/\/$/, '') + '/chat/completions', {
    method: 'POST',
    headers: { 'Authorization': 'Bearer ' + apiKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, stream: true, temperature, messages })
  });
  if (!resp.ok || !resp.body) {
    const text = await resp.text().catch(() => ''); throw new Error('OpenAI error ' + resp.status + ' ' + text);
  }
  const reader = resp.body.getReader(); const decoder = new TextDecoder(); let buffer = '';
  while (true) {
    const { value, done } = await reader.read(); if (done) break; if (token.isCancellationRequested) break;
    buffer += decoder.decode(value, { stream: true });
    const parts = buffer.split('\n\n'); buffer = parts.pop() || '';
    for (const part of parts) {
      const line = part.trim(); if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim(); if (data === '[DONE]') return;
      try { const json = JSON.parse(data); const delta = json.choices?.[0]?.delta?.content; if (delta) { yield delta as string; } } catch {}
    }
  }
}

function extractLastCodeBlock(md: string): string | undefined {
  const triple = /```[\w+-]*\n([\s\S]*?)\n```/g; let match: RegExpExecArray | null; let last: string | undefined;
  while ((match = triple.exec(md)) !== null) { last = match[1]; } return last;
}

const handler: vscode.ChatRequestHandler = async (request, chatContext, stream, token) => {
  const config = vscode.workspace.getConfiguration('coding-partner-openai');
  const model = (request.model?.name as string) || (config.get('model') as string) || 'gpt-4o-mini';
  const apiBase = (config.get('apiBase') as string) || 'https://api.openai.com/v1';
  const temperature = (config.get('temperature') as number) ?? 0.2;
  const getKey = (globalThis as any).__cp_getKey as () => Promise<string | undefined>;
  const promptKey = (globalThis as any).__cp_promptKey as () => Promise<string | undefined>;
  let apiKey = await getKey(); if (!apiKey) { apiKey = await promptKey(); }
  if (!apiKey) { stream.markdown('No OpenAI key set. Run **Coding Partner OpenAI: Set API Key** then retry.'); return { metadata: { error: 'no-key' } }; }
  stream.progress('Partner is thinking');
  const editor = vscode.window.activeTextEditor;
  const hasSelection = editor && !editor.selection.isEmpty;
  const selectedText = hasSelection ? editor?.document.getText(editor.selection) : undefined;
  const intent = request.command ?? 'freeform';
  const sys = [
    'You are Coding Partner.',
    'Be direct, clear, practical.',
    'Prefer minimal explanations.',
    'When editing code, return a fenced code block containing the full updated file or snippet.',
    'When giving tests, include runnable examples.'
  ].join('\n');
  const contextLines: string[] = [];
  if (selectedText) { contextLines.push('Selected code follows', '```', selectedText, '```'); }
  else if (editor) {
    const text = editor.document.getText();
    if (text && text.length <= 60000) { contextLines.push('Active file content follows', '```', text, '```'); }
  }
  const userPrompt = [ intent !== 'freeform' ? `User called /${intent}` : 'User request', request.prompt, contextLines.join('\n') ].filter(Boolean).join('\n\n');
  const messages = [ { role: 'system', content: sys }, { role: 'user', content: userPrompt } ];
  let full = '';
  try {
    for await (const chunk of openAIStream(apiKey, model, apiBase, messages, temperature, token)) {
      full += chunk; stream.markdown(chunk);
    }
    lastCodeBlock = extractLastCodeBlock(full);
if (lastCodeBlock) {
  stream.markdown('\n\n_Run **Coding Partner OpenAI: Apply Last Code Block** to apply it._');
}
return { metadata: { ok: true, intent } };

  } catch (err: any) {
    stream.markdown('OpenAI request failed. ' + (err?.message || 'Unknown error')); return { metadata: { error: 'openai-error' } };
  }
};

export function deactivate() {}
