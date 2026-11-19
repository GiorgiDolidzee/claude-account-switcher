# Re-measure the login (Step 0)

Use this if switching stops working after a Claude update. It finds out which files make up a Claude login on your Mac. It takes about 10 minutes and you need two Claude accounts.

**What it saves:** names, sizes, dates and short fingerprints of files and settings.
**What it never saves:** passwords, cookies, tokens, or file contents.

## Start

From the menu: **ⓘ → Re-measure login…**. Or from the project folder:

```bash
./scripts/step0/step0.sh
```

Save your work first: Claude quits several times. The script tells you each step; press Enter after each one.

1. Quit Claude.
2. Open Claude, wait until it loads, do nothing, quit.
3. Open Claude, **log out**, quit.
4. Open Claude, log in to your **other** account, quit.
5. Claude Code starts in the Terminal. Type `/exit`.
6. It starts again. Type `/logout`.
7. It starts again. Log in with your **other** account, then `/exit`.
8. If all checks pass, it asks whether to use the new measurement. Then log back in to the account you started with.

The report is in `~/Library/Application Support/ClaudeSwitcher/step0/report.md`.
