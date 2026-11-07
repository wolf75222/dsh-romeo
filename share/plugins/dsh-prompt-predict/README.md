# dsh-prompt-predict (dsh-romeo build)

[dsh-prompt-predict](https://github.com/ferrisching/dsh-prompt-predict) 0.2.13 by ferrisching (MIT),
with two features added for dsh-romeo:

- Live completion while you type, as in an IDE: after 700 ms without a key, a grey continuation
  appears at the cursor, aligned with your text. Tab inserts it, Esc hides it (until the draft
  changes), typing on keeps it while your keys match it. In a session it reads the last messages;
  in the box of a session not started yet, the prompt alone.
- Right-click in the message box: "Correct the prompt" fixes spelling, grammar and spacing and
  keeps paths, code, commands, @mentions and /commands as they are. The menu also has Cut, Copy,
  Paste and Select all.

The next-message suggestion after each answer is unchanged. Under dsh-romeo all three run on
DeepSeek without reasoning (`dsh-romeo` sets the plugin's provider and model), so they never wait for
Kimi. Turn the live completion off in Settings, "Prompt suggestions".

Installed by dsh-romeo's `install.sh` (turned off; turn it on in the Plugins page), linked from this
folder. `client/client.js` is built from `client/src` (`node scripts/build-client.mjs`); the tests are in
`test/` and run with dsh-romeo's `tests/run.sh`. In French, English or Chinese, as dsh.
