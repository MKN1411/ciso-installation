# CISO Assistant – read-only Datenbankvergleich

Dieses Tool vergleicht die lokalen CISO-Assistant-Instanzen unter `D:\_Docker`, ohne eine der Datenbanken zu veraendern. Es wurde fuer die vorhandenen Instanzen `ciso-assistant-local`, `ciso-assistant-dev01`, `ciso-assistant-dev02` und `ciso-assistant-grc-dev` erstellt und soll insbesondere klaeren, in welcher Instanz der fruehere Microsoft-365-Asset-Import liegt.

## Ziel

Der Vergleich beantwortet technisch folgende Fragen:

- Welche Instanzen besitzen eine CISO-Assistant-SQLite-Datenbank?
- Sind zwei Datenbanken byte-identisch (SHA-256)?
- Welche Datenbank ist groesser und zuletzt geaendert worden?
- Wie viele fachliche Datensaetze befinden sich in Asset-, Evidence-, Risk-, Assessment-, Perimeter-, Folder-, Control-, Requirement-, Incident-, Supplier- und User-Tabellen?
- In welchen Tabellen finden sich Hinweise auf M365, Microsoft 365, Office 365, Entra, Intune, Defender, Exchange, SharePoint, OneDrive, Teams, Purview oder Azure?
- Welche Instanz ist damit der staerkste technische Kandidat fuer den frueheren M365-Asset-Import?

## Dateien

### `Compare-CisoAssistantDatabases.ps1`

PowerShell-Orchestrator. Das Skript sucht fuer jede Instanz standardmaessig nach `db\ciso-assistant.sqlite3`, berechnet Dateimetadaten und SHA-256 und startet anschliessend einen kurzlebigen, isolierten Analyse-Container. Es startet oder stoppt keine vorhandene CISO-Assistant-Instanz.

### `Inspect-CisoAssistantDatabase.py`

Python-Helfer fuer die SQLite-Auswertung. Die Datenbank wird mit SQLite URI `mode=ro` geoeffnet und zusaetzlich mit `PRAGMA query_only=ON` abgesichert. Das Skript ermittelt Tabellen, Spalten, Zeilenanzahlen, letzte Zeitstempel, Migrationen und M365-bezogene Treffer. Die Ausgabe erfolgt ausschliesslich als JSON auf stdout.

## Sicherheitsmodell

Die Analyse ist bewusst nicht-destruktiv aufgebaut:

- Datenbankverzeichnis wird im Analyse-Container `readonly` eingebunden.
- Tool-Verzeichnis wird ebenfalls `readonly` eingebunden.
- Der Analyse-Container selbst nutzt `--read-only`.
- Netzwerk wird mit `--network none` deaktiviert.
- `--pull never` verhindert einen Download oder eine Aktualisierung des Backend-Images.
- Es werden keine Django-Migrationen ausgefuehrt.
- Bestehende Container werden nicht gestartet, gestoppt, neu erstellt oder aktualisiert.
- Die Datenbank wird nicht kopiert, geaendert oder bereinigt.

Das aktuell verwendete CISO-Assistant-Docker-Layout bindet `./db` nach `/code/db` ein; die Standard-SQLite-Datei lautet `db/ciso-assistant.sqlite3`. Das Tool greift jedoch ueber einen separaten read-only Mount auf das jeweilige `db`-Verzeichnis zu.

## Voraussetzungen

- Windows 11 mit PowerShell 7 oder neuer.
- Docker Desktop und funktionierende Docker CLI.
- Das CISO-Assistant-Backend-Image ist bereits lokal vorhanden: `ghcr.io/intuitem/ciso-assistant-community/backend:latest`.
- Die Instanzen liegen standardmaessig unter `D:\_Docker`.

Das Tool zieht absichtlich kein fehlendes Image aus dem Internet. Fehlt das Backend-Image, wird die Auswertung mit einer klaren Fehlermeldung beendet.

## Ausfuehrung

Im Repository `ciso-installation`:

```powershell
Set-Location .\tools\database-comparison
.\Compare-CisoAssistantDatabases.ps1
```

Alternativ ohne Beispieldatensaetze im JSON-Detailreport:

```powershell
.\Compare-CisoAssistantDatabases.ps1 -SampleLimit 0
```

Alternative Docker-Root-Struktur:

```powershell
.\Compare-CisoAssistantDatabases.ps1 -DockerRoot 'E:\Docker'
```

## Ergebnisdateien

Unter `D:\_Docker\_CisoDatabaseComparison\<Zeitstempel>\` werden erzeugt:

- `ciso-database-comparison.md` – lesbarer Vergleich mit Kernaussage und M365-Treffern.
- `ciso-database-comparison.csv` – kompakte Vergleichstabelle.
- `ciso-database-comparison.json` – technische Detaildaten inklusive Tabelleninventar und optionalen Beispieldatensaetzen.

Die Quelldatenbanken bleiben unveraendert.

## Interpretation

Der wichtigste Wert fuer die aktuelle Fragestellung ist `AssetM365Matches`. Findet genau eine Instanz deutlich mehr M365-bezogene Datensaetze in Asset-Tabellen, ist sie der staerkste Kandidat fuer den frueheren M365-Asset-Import. Zusaetzlich sollten `AssetRows`, `EvidenceRows`, `AssessmentRows`, `M365KeywordMatches`, Datenbankzeitpunkt und Hash betrachtet werden.

Ein identischer SHA-256-Hash beweist, dass zwei SQLite-Dateien zum Zeitpunkt des Vergleichs byte-identisch sind. Unterschiedliche Hashes allein beweisen dagegen nicht, welche Datenbank fachlich aktueller ist.

## PSScriptAnalyzer

Das PowerShell-Skript verwendet ausschliesslich freigegebene PowerShell-Verben fuer eigene Funktionen (`Get`, `Test`, `Invoke`, `Write`, `Export`). Wenn PSScriptAnalyzer lokal installiert ist, kann die Pruefung mit den bereits im Repository vorhandenen Einstellungen ausgefuehrt werden:

```powershell
Invoke-ScriptAnalyzer `
    -Path .\Compare-CisoAssistantDatabases.ps1 `
    -Settings ..\..\PSScriptAnalyzerSettings.psd1
```

Fehler oder Warnungen sollten vor einer funktionalen Erweiterung des Tools dokumentiert und bewertet werden.

## Datenschutz

Der JSON-Detailreport kann bei `SampleLimit > 0` kurze Beispieldatensaetze aus Tabellen enthalten, in denen M365-Schluesselwoerter gefunden wurden. Der Report bleibt lokal unter `D:\_Docker\_CisoDatabaseComparison`. Fuer eine rein quantitative Auswertung sollte `-SampleLimit 0` verwendet werden.
