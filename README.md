# Coding Partner OpenAI (v0.0.3)
Chat participant for VS Code that calls OpenAI directly and streams the reply. Uses your own API key.

Setup
1. Open this folder in VS Code
2. Run `npm install`
3. Run `npm run compile`
4. Press F5 to start the Extension Development Host
5. Run the command Coding Partner OpenAI Set API Key
6. Open the Chat view and type `@partner explain` or select code and run `@partner /tests`

Apply edits
If the reply includes a fenced code block, run Coding Partner OpenAI Apply Last Code Block to replace the current selection or the whole file if nothing is selected.

Settings
- coding-partner-openai.model default gpt-4o-mini
- coding-partner-openai.apiBase default https://api.openai.com/v1
- coding-partner-openai.temperature default 0.2

Notes
- Your key is stored in VS Code Secret Storage
- You can also set OPENAI_API_KEY in your shell environment
- This is not GitHub Copilot. It is a lightweight, local chat participant that talks to OpenAI
