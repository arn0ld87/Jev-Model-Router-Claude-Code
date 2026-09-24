# Jev Model Router für Claude Code

Ein Hook plus Skill, der für jeden Prompt in Claude Code fragt: **Welches Claude-Modell braucht diese Aufgabe wirklich?** Die Antwort liefert [Jev](https://typesafe.ai) von TypeSafe AI in unter einer halben Sekunde. Liegt die Stufe unter deinem Session-Modell und ist die Aufgabe in sich geschlossen, gibt Claude sie an einen Subagenten mit dem günstigeren Modell.

Begleitmaterial zum Video „Jev + Claude Code: 3 Use Cases".

## Wie es funktioniert

1. Ein `UserPromptSubmit`-Hook (`jev-router/route.sh`) schickt den Text deines Prompts an Jev.
2. Jev beantwortet zwei typisierte Fragen: die günstigste Stufe (`haiku` / `sonnet` / `opus` / `fable`) und die Wahrscheinlichkeit, dass die Aufgabe vom bisherigen Gespräch abhängt.
3. Der Hook blendet Claude eine Zeile ein: `DELEGATE` (Subagent mit dem genannten Modell) oder `handle` (in der Session bleiben).
4. Der Skill `/jev` schaltet den Router ein und aus und zeigt dir seine Entscheidungen.

**Was an TypeSafe geht:** nur der Text deines Prompts (max. 12.000 Zeichen). Keine Dateien, kein Code, kein Gesprächsverlauf. Der Router ist fail-open: Antwortet Jev nicht innerhalb von 5 Sekunden, läuft dein Prompt unverändert durch.

## Voraussetzungen

- Claude Code
- `jq` und `curl` (Mac: `brew install jq`, curl ist vorinstalliert)
- Ein API-Key von [console.typesafe.ai](https://console.typesafe.ai) (neue Accounts bekommen Startguthaben)

## Installation

Repo klonen, dann Claude Code **in dem geklonten Ordner** starten und diesen Prompt einfügen:

```bash
git clone https://github.com/AlexPEClub/Jev-Model-Router-Claude-Code-.git jev-model-router
cd jev-model-router
claude
```

```
Richte mir den Jev Model Router aus diesem Repo ein. Kopiere die Dateien exakt,
ohne den Inhalt zu verändern:

1. jev-router/route.sh    → ~/.claude/jev-router/route.sh   (ausführbar machen)
2. jev-router/jev.sh      → ~/.claude/jev-router/jev.sh     (ausführbar machen)
3. jev-router/config.json → ~/.claude/jev-router/config.json
4. skills/jev/SKILL.md    → ~/.claude/skills/jev/SKILL.md
5. Den Hook-Block aus hook-settings.json in ~/.claude/settings.json unter
   hooks.UserPromptSubmit ERGÄNZEN, ohne bestehende Hooks oder andere
   Einstellungen zu überschreiben. Existiert die Datei noch nicht, lege sie an.

Danach:
- Frag mich, welches Modell meine Claude-Code-Session normalerweise nutzt
  (haiku, sonnet, opus oder fable), und trage es in ~/.claude/jev-router/config.json
  als "session_model" ein.
- Prüfe, ob jq und curl installiert sind. Falls jq fehlt, nenn mir den
  Installationsbefehl für mein System.
- Prüfe, ob TYPESAFE_API_KEY in meiner Umgebung gesetzt ist. Falls nicht, sag mir,
  dass ich den Key selbst in die Datei ~/.claude/jev-router/.env als Zeile
  TYPESAFE_API_KEY=... eintragen soll (Datei mit chmod 600 schützen).
  Schreib den Key niemals selbst in eine Datei.
- Schalte den Router NICHT ein (keine Datei "enabled" anlegen). Das mache ich
  selbst mit /jev on.
- Zum Schluss: bash ~/.claude/jev-router/jev.sh test "Wo wird in diesem Projekt
  der Supabase-Client initialisiert?" ausführen und mir die Ausgabe zeigen.
```

Wenn Claude fertig ist: Claude Code einmal beenden und neu starten, damit der Hook und der Skill `/jev` geladen werden.

## Benutzen

```
/jev on
```

Danach ganz normal arbeiten. Bei jedem Prompt, den Jev als delegierbar einstuft, startet Claude seine Antwort mit `→ haiku (Jev)` und gibt die Aufgabe an einen Subagenten mit diesem Modell. Bleibt die Aufgabe in der Session, beginnt die Antwort mit `→ opus (Jev: haiku, ctx 0.89)`, du siehst also immer, was Jev empfohlen hat und warum es trotzdem in der Session blieb.

| Befehl | Was er tut |
|--------|------------|
| `/jev on` | Router einschalten (Prompt-Text geht ab jetzt an api.typesafe.ai) |
| `/jev off` | Router ausschalten, nichts verlässt mehr die Maschine |
| `/jev status` | An/Aus, Session-Modell, Verteilung nach Stufe, Anzahl Delegationen, mittlere Latenz |
| `/jev test <Prompt>` | Trockenlauf: Jevs Entscheidung sehen, ohne etwas zu verändern |
| `/jev log 20` | Die letzten 20 Entscheidungen |

Slash-Commands und Prompts unter 12 Zeichen werden nie klassifiziert.

## Anpassen

Alles Einstellbare liegt in `~/.claude/jev-router/config.json`:

| Feld | Bedeutung | Standard |
|------|-----------|----------|
| `session_model` | Das Modell deiner Session. Delegiert wird nur an Stufen darunter. | `opus` |
| `min_confidence` | Unter dieser Konfidenz bleibt die Aufgabe in der Session | `0.6` |
| `context_threshold` | Ab dieser Wahrscheinlichkeit für „hängt vom Gespräch ab" bleibt die Aufgabe in der Session | `0.5` |
| `questions.route.criteria` | Die Beschreibung der vier Stufen. Hier schärfst du nach, wenn Jev zu oft oder zu selten delegiert. | siehe Datei |
| `model` | Jev-Version. Nach dem Kalibrieren der Schwellen auf eine feste Version pinnen. | `jev-latest` |

## Ehrliche Einschränkungen

- Der Hook blendet nur die Entscheidung ein. Die Delegation macht Claude selbst. In der Praxis hält sich Claude daran, garantiert ist es nicht. Wer das hart erzwingen will, findet in [gargpratyush/jev-router](https://github.com/gargpratyush/jev-router) einen Proxy-Ansatz, der das Modell wirklich austauscht.
- Subagenten starten mit frischem Kontext. Deshalb die zweite Frage an Jev: Hängt die Aufgabe vom Gespräch ab? Wenn ja, bleibt sie im Session-Modell.
- Ob die Ersparnis für deine Arbeit passt, musst du selbst messen. `/jev status` und `/jev log` zeigen dir die Datenbasis.
- `~/.claude/jev-router/log.jsonl` enthält die ersten 120 Zeichen jedes klassifizierten Prompts. Nicht teilen, nicht committen.
- Datenschutz: Dein Prompt-Text geht an einen US-Anbieter. Für Arbeit mit Kundendaten gilt dieselbe Prüfung wie bei jedem anderen KI-Dienst, siehe [docs.typesafe.ai/legal](https://docs.typesafe.ai/legal). Im Zweifel `/jev off`.

## Dateien in diesem Repo

```
jev-router/route.sh      der Hook (bash + curl + jq)
jev-router/jev.sh        das CLI hinter /jev
jev-router/config.json   Modell, Schwellen, Kriterien
skills/jev/SKILL.md      der Skill
hook-settings.json       der Block für ~/.claude/settings.json
```

## Links

- TypeSafe Console: https://console.typesafe.ai
- TypeSafe Doku: https://docs.typesafe.ai
- Offizieller TypeSafe-Skill für Claude Code: https://github.com/typesafe-ai/skills
- Claude-Code-Hooks-Referenz: https://code.claude.com/docs/en/hooks
