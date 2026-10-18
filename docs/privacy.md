# Pyslopnista Privacy Policy

Effective 2026-10-18.

Pyslopnista is a Python editor for iPhone and iPad. This policy covers the
app. The short version: **the developer collects no data.** The app has no
analytics, no advertising, no tracking and no accounts of its own.

## Your files and programs

Your files stay on your device: in the app's folder (which you can see in
the Files app) and in folders you link from other places, such as iCloud
Drive. Python runs on the device. Settings, conversations with the coding
agent and the list of linked folders are stored on the device too.
Passwords, API keys and sign-in tokens are kept in the device's Keychain.

## Network connections

The app connects to the internet only when you do something that needs it:

- **Your programs** connect to the servers they ask for (for example with
  `requests` or `urllib`).
- **Installing packages** (a program's dependencies, `%pip`, micropip)
  downloads them from the Python Package Index (pypi.org,
  files.pythonhosted.org) and from Pyodide's package files (cdn.jsdelivr.net).
- **Links** you open in Markdown files, the documentation or the agent's
  answers open in Safari.

These services receive what any web request carries, such as your IP
address. Their own privacy policies apply.

## The coding agent

The coding agent is optional. It works only after you sign in to a model
provider or add an API key (for example Radius, Anthropic, OpenAI, Google,
GitHub Copilot, xAI, Mistral, Groq, DeepSeek, OpenRouter, Kimi or Meta).

Before the first message goes to a provider, the app asks for your
permission. After that, when you send a message, the app sends to the provider
you chose:

- your message;
- what the agent reads to answer it: files of the current project, the
  output and errors of programs it runs, and the file and lines you have
  open in the editor.

The provider processes this data under its own terms and privacy policy.
The developer of Pyslopnista does not receive it. You can sign out of a
provider under Accounts in the agent's menu; this deletes its tokens or key
from the device.

## Device features

Programs you write can use the camera, photos, location, motion sensors,
microphone, speech recognition, contacts, reminders and notifications
through the app's device modules. iOS asks for your permission the first
time a program uses one. What a program reads stays on the device unless
the program itself sends it somewhere.

## Deleting your data

Everything the app stores is on your device. Deleting the app deletes it,
except files in linked folders, which stay where they are. Signing out of a
model provider deletes its credentials. Data you sent to a model provider is
kept or deleted under that provider's policy.

## Children

The app is a general-purpose programming tool and is not directed at
children. It contains no advertising and collects no data from anyone.

## Changes and contact

Changes to this policy are published in this file, with a new date. The
history is in the [repository](https://github.com/mitsuhiko/pyslopnista).
Questions: [open an issue](https://github.com/mitsuhiko/pyslopnista/issues).
