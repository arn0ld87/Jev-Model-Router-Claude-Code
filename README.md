# JEV Model Router für Claude Code

Der Router fragt [TypeSafe JEV](https://typesafe.ai) an sinnvollen Task-Grenzen nach einem Modell. Normale Prompts, direkte Slash-/MCP-Prompt-Erweiterungen, programmatische Skill-Aufrufe und `Agent`-Aufgaben werden getrennt behandelt. Bei `Agent`-Aufrufen setzt ein `PreToolUse`-Hook das `model`-Argument vor der Ausführung auf die JEV-Empfehlung. Für das Hauptgespräch kann ein Hook nur Kontext mit einer Empfehlung liefern; er kann dessen Modell nicht selbst umschalten.

## Ereignisse und Wirkung

| Claude-Code-Ereignis | JEV-Aufruf? | Wirkung |
| --- | --- | --- |
| `UserPromptSubmit` | Ja, für normale Nutzereingaben | Modell-Empfehlung als `additionalContext`; gegebenenfalls Delegationsempfehlung |
| `UserPromptExpansion` | Ja, für direkt eingegebene Skills, Slash-Commands und MCP-Prompts | Modell-Empfehlung für die expandierte Aufgabe |
| `PreToolUse` mit `Skill` | Ja, bei von Claude gestarteten Skills | Empfehlung für den Skill-Task |
| `PreToolUse` mit `Agent` | Ja, für jeden neuen Agent-Task, auch innerhalb eines Subagenten | `updatedInput.model` setzt das konkrete Agent-Modell |
| `PostToolUse` mit `Agent` | Nein | Protokolliert den vom Hook beobachteten Tool-Input |
| `SubagentStart` | Nein | Protokolliert Start und Agent-Typ; der Task-Prompt ist hier nicht verfügbar |
| `SubagentStop` | Nein | Abschlussereignis ohne neue Modellentscheidung |
| `TaskCreated`/`TaskCompleted` | Nein | Betreffen `TaskCreate`/`TaskUpdate`, nicht jeden LLM-Task oder Agent-Start |
| `PreModelSwitch`/`PostModelSwitch` | Nein | Beobachten bzw. blockieren Session-Modellwechsel, wählen kein Modell für einen Task |
| `Read`, `Edit`, `Write`, `Glob`, `Grep`, `Bash` | Nein | Primitive Tools innerhalb eines bereits laufenden Tasks |

Diese Aussagen entsprechen der [aktuellen Hook-Referenz](https://code.claude.com/docs/en/hooks) und der [Subagent-Modellreihenfolge](https://code.claude.com/docs/en/sub-agents). `UserPromptExpansion` liefert den ursprünglichen Befehl und dessen Argumente, nicht den vollständig expandierten Skill-Text. Bei programmatisch aufgerufenen Skills liefert `PreToolUse` die Skill-Argumente. Deshalb klassifiziert JEV diese Aufgaben anhand des Befehls und der verfügbaren Argumente.

Ein direkt eingegebener Slash-Command wird erst bei `UserPromptExpansion` bewertet. So laufen eingebaute Steuerbefehle, die keinen Prompt expandieren, nicht durch JEV. `/jev` ist ausdrücklich ausgenommen, damit Status, Log und Umschalten den Router nicht rekursiv auslösen.

## Agenten und verschachtelte Tasks

```text
User: "Prüfe die Anmeldung"        → UserPromptSubmit → JEV empfiehlt opus
  Agent("Finde Auth-Tests")         → PreToolUse Agent → JEV wählt haiku
    Agent("Ergänze fehlende Tests") → PreToolUse Agent → JEV wählt sonnet
```

Das zweite `Agent`-Ereignis wird auch im Subagenten durch denselben Hook erfasst. `updatedInput` übernimmt die übrigen Tool-Parameter unverändert und ersetzt nur `model`, sofern JEVs Konfidenz mindestens `min_confidence` erreicht. Bei niedrigerer Konfidenz bleibt der ursprüngliche Agent-Aufruf bestehen. Der Hook gibt keine `permissionDecision: "allow"` zurück, damit Claude Codes normale Berechtigungsprüfung erhalten bleibt. Ein identischer Task innerhalb der Cache-TTL nutzt die erste JEV-Antwort erneut.

Das Hauptgespräch behält sein bereits gewähltes Modell. Wenn JEV ein günstigeres Modell mit hinreichender Konfidenz und geringer Kontextabhängigkeit empfiehlt, erhält Claude eine Delegationsempfehlung. Ob es delegiert, bleibt bei Claude. Das ist die technische Grenze von `UserPromptSubmit`.

## Installation und Upgrade

Voraussetzungen: Claude Code, Bash, `jq`, `curl`, `shasum` und ein TypeSafe-API-Key. Auf macOS: `brew install jq`. Prüfe, ob deine Claude-Code-Version die genannten Hook-Ereignisse und `PreToolUse.updatedInput` unterstützt.

```bash
git clone https://github.com/arn0ld87/Jev-Model-Router-Claude-Code.git
cd Jev-Model-Router-Claude-Code
bash install.sh
```

`install.sh` legt die Skripte unter `~/.claude/jev-router/` und den Skill unter `~/.claude/skills/jev/` ab. Es ergänzt die Hook-Konfiguration in `~/.claude/settings.json` und entfernt nur alte JEV-Router-Hook-Einträge, bevor es die neuen einträgt. Andere Hooks und Einstellungen bleiben erhalten. Bei einem Upgrade werden vorhandene Skripte, Skill, Konfiguration und Settings mit Zeitstempel gesichert. Die bestehende `.env`, `log.jsonl`, der Cache und der `enabled`-Status bleiben erhalten. In älteren Standardkonfigurationen wird `min_prompt_chars: 12` auf `1` migriert; andere Werte bleiben bestehen. Die Installation schaltet JEV nicht automatisch ein.

Ältere `log.jsonl`-Einträge können noch die früher protokollierten ersten 120 Prompt-Zeichen enthalten. Das Upgrade bewahrt diese Einträge, setzt die Dateiberechtigung auf `600` und zeigt sie im neuen `/jev log` nicht an. Prüfe oder entferne die alte Logdatei selbst, wenn sie vertrauliche Alt-Daten enthält.

Lege den Key selbst in der Umgebung oder in `~/.claude/jev-router/.env` ab:

```text
TYPESAFE_API_KEY=...
```

Schütze die Datei mit `chmod 600 ~/.claude/jev-router/.env`. Der Router liest eine `.env` mit anderen Berechtigungen nicht ein. API-Key und Task-Payload werden nicht als Argumente an `curl` übergeben. Starte Claude Code nach der Installation neu, damit die neuen Hooks und der Skill geladen werden.

## Bedienung

| Befehl | Wirkung |
| --- | --- |
| `/jev on` | Aktiviert die JEV-Anfragen; Task-Text kann an TypeSafe gehen |
| `/jev off` | Deaktiviert den Router |
| `/jev status` | Zähler, Verteilung, Cache, Fehler, Latenz und ausgewählte Agent-Modelle |
| `/jev log 20` | Letzte Ereignisse mit Task-Hash, Empfehlung, Modell und Ergebnis |
| `/jev debug on` / `off` | Fügt Hook-Kontext zu Empfehlung, Konfidenz, Cache und Latenz hinzu |
| `/jev test <Task>` | Klassifiziert einen Test-Task ohne den Aktivierungsstatus zu ändern |

Die CLI ist auch direkt mit `bash ~/.claude/jev-router/jev.sh <Befehl>` verfügbar. `/jev test` sendet den angegebenen Text auch dann an TypeSafe, wenn der Router ausgeschaltet ist.

## Konfiguration

`~/.claude/jev-router/config.json` enthält:

| Feld | Standard | Bedeutung |
| --- | --- | --- |
| `enabled_events` | alle vier Task-Ereignisse aktiv | Schaltet Prompt-, Expansion-, Skill- und Agent-Routing einzeln |
| `cache_ttl_seconds` | `30` | Wiederverwendung identischer Tasks derselben Session |
| `max_state_chars` | `12000` | Maximale Länge des Task-Texts im JEV-Request; harte Obergrenze ebenfalls 12000 |
| `min_prompt_chars` | `1` | Mindestlänge; kurze Eingaben wie „teste“ laufen durch JEV |
| `session_model` | `opus` | Fallback für die Delegationsempfehlung des Hauptgesprächs |
| `context_threshold`, `min_confidence` | `0.5`, `0.6` | Schwellen für die Delegationsempfehlung; `min_confidence` gilt auch für Agent-Modelländerungen |
| `debug` | `false` | Ausführlicher Hook-Kontext |
| `model`, `questions` | siehe Datei | JEV-Version und Routing-Kriterien |

Der Cache-Schlüssel enthält Session-ID und Task-Text; Ereignistypen teilen sich damit Treffer für denselben Task. Ein User-Prompt, der unmittelbar mit identischem Text an `Agent` geht, verursacht nur eine JEV-Anfrage. Der Cache speichert nur Modell, Konfidenz und Kontextabhängigkeit, nicht den Task-Text.

## Daten, Fehler und Beobachtbarkeit

An TypeSafe gehen der gekürzte Task-Text, Ereignistyp, Agent-Typ, vom Agent angefragtes Modell und das konfigurierte Session-Modell. Die Prompt- und Tool-Hooks liefern das tatsächlich aktive Hauptmodell und den Parent-Task nicht zuverlässig; diese Werte werden deshalb nicht vorgetäuscht. Es gehen keine Dateien, Transkripte oder kompletter Sourcecode automatisch mit. Wenn der Task selbst Code oder sensible Daten enthält, können diese im Task-Text stehen. Eine konservative Erkennung überspringt erkennbare Zugangsdaten; sie kann nicht jedes Geheimnis erkennen. Nutze `/jev off` für vertrauliche Arbeit.

`log.jsonl` enthält Zeit, Ereignis, kurzen SHA-256-Task-Hash, JEV-Empfehlung, ausgewähltes Modell, Cache-Status, Latenz und Fehlerart. Es speichert keine Prompt-Texte, API-Antworten oder Keys. `/jev status` zählt JEV-Anfragen nach Ereignistyp, Cache-Treffer, Empfehlungen, ausgewählte Agent-Modelle, API-Fehler und mittlere Latenz. Falls Claude Code für `PreToolUse` und `PostToolUse` dieselbe `tool_use_id` meldet, zählt es außerdem Abweichungen zwischen `updatedInput.model` und dem später beobachteten Tool-Input. „Vermiedene Opus-Aufrufe“ ist eine Schätzung aus den vom Hook ausgewählten Agent-Modellen, keine Abrechnungszahl.

Ein `PostToolUse`-Hook sieht den Tool-Input, aber nicht zwingend das tatsächlich abgerechnete Modell. Claude Code kann bei `availableModels`-Regeln ein Modell ersetzen; `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` kann pro Aufruf gewählte Modelle übergehen. Den wirklichen Subagent-Modellnamen zeigt Claude Code in `/tasks` (unterstützte Versionen). Deshalb bezeichnet das Log `selected` als Hook-Entscheidung und `observed_tool_input` als beobachteten Tool-Input; es behauptet keine Billing-Wahrheit.

Bei fehlendem Key, unsicherer `.env`, Timeout, HTTP-Fehler, ungültiger Antwort oder Cache-Schreibfehler läuft Claude Code normal weiter. Der Router protokolliert erkennbare Fehler ohne Task-Text. Er setzt `JEV_ROUTER_ACTIVE=1` als Reentrancy-Guard. Die Hook-Timeouts sind auf acht Sekunden gesetzt, der API-Timeout auf fünf Sekunden.

## Tests

```bash
bash tests/test-router.sh
bash tests/test-install.sh
bash -n jev-router/*.sh install.sh tests/*.sh
```

Die Tests verwenden einen lokalen `curl`-Mock und senden keine API-Anfragen. Sie prüfen normale und kurze Prompts, Slash-Commands, Agenten, verschachtelte Agenten, Cache, primitive Tools, Fehlerfälle, Log-Datenschutz sowie eine wiederholte Migration. Falls `shellcheck` installiert ist: `shellcheck jev-router/*.sh install.sh tests/*.sh`.

## Dateien

| Datei | Aufgabe |
| --- | --- |
| `jev-router/route.sh` | Kleiner Hook-Einstieg und Reentrancy-Guard |
| `jev-router/router-core.sh` | Zentrale JEV-Abfrage, Cache, Modellwahl und Logging |
| `jev-router/jev.sh` | `/jev`-CLI |
| `jev-router/config.json` | Routing-Regeln und Konfiguration |
| `hook-settings.json` | Hook-Einträge für Claude Code |
| `skills/jev/SKILL.md` | Bedienung über `/jev` |
| `install.sh` | Upgrade und Migration |
| `tests/` | Reproduzierbare Offline-Tests |
