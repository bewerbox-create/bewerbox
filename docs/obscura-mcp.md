# Obscura jako serwer MCP dla Claude Code

[Obscura](https://github.com/h4ckf0r0day/obscura) to lekka przeglądarka headless (Rust)
dla agentów AI. Plik `.mcp.json` w katalogu głównym repo rejestruje ją w Claude Code
jako serwer MCP `obscura` (transport stdio, komenda `obscura mcp`).

## Instalacja (Windows)

1. Pobierz `.zip` dla Windows z https://github.com/h4ckf0r0day/obscura/releases
2. Rozpakuj do np. `C:\Tools\obscura\` (plik `obscura-worker` musi leżeć obok `obscura`).
3. Dodaj `C:\Tools\obscura` do zmiennej PATH:
   ```powershell
   [Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Tools\obscura", "User")
   ```
4. Otwórz nowy terminal i sprawdź: `obscura --version`

Jeśli nie chcesz zmieniać PATH, wpisz w `.mcp.json` pełną ścieżkę, np.
`"command": "C:\\Tools\\obscura\\obscura.exe"`.

## Uruchomienie

W katalogu repo uruchom `claude`. Przy pierwszym starcie Claude Code zapyta,
czy zaufać serwerowi z `.mcp.json`, więc zatwierdź. Status sprawdzisz komendą `/mcp`.

Udostępnione narzędzia: `browser_navigate`, `browser_snapshot`, `browser_click`,
`browser_fill`, `browser_type`, `browser_press_key`, `browser_select_option`,
`browser_evaluate`, `browser_wait_for`, `browser_network_requests`,
`browser_console_messages`, `browser_close` (oraz `browser_screenshot` i `browser_pdf`
w buildzie z `render`).

Opcjonalne flagi (dopisz do `args`): `--proxy <URL>`, `--user-agent <UA>`, `--stealth`.

## Zasady

Używaj do własnych stron (np. testy bewerbox.de) i serwisów, których regulamin
na to pozwala. Nie scrapuj eBay ani portali, które tego zabraniają. Uważaj na dane
osobowe (DSGVO).
