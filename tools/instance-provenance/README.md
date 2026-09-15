# CISO Assistant Instance Provenance

Dieses Tool rekonstruiert read-only, woher die lokalen CISO-Assistant-Instanzen stammen und welche Wrapper-/Installer-Repositories auf dem Rechner vorhanden sind.

## Warum `git remote -v` allein nicht reicht

`Deploy-Local.ps1` aus `MKN1411/ciso-installation` klont fuer jede Zielinstanz direkt das Upstream-Repository:

```text
https://github.com/intuitem/ciso-assistant-community.git
```

Deshalb wird `origin` in `D:\_Docker\ciso-assistant-*` normalerweise immer auf `intuitem/ciso-assistant-community` zeigen. Daraus kann nicht direkt abgeleitet werden, ob das Deployment aus `MKN1411/ciso-installation`, `ankbs/ciso-installation` oder einem anderen Fork gestartet wurde.

Der Provenance-Check kombiniert daher vier Evidenzquellen:

1. Git-Metadaten der vier CISO-Assistant-Instanzen (`origin`, Branch, HEAD, Reflog, lokale tracked Aenderungen).
2. Docker-Compose-Labels (`project`, `working_dir`, `config_files`).
3. Git-Repositories unter `D:\_GRC_Agent` inklusive ihrer `origin`-URLs.
4. PowerShell/PSReadLine-Historie fuer Aufrufe von `Deploy-Local.ps1`, `Install-LocalDocker.ps1`, `MKN1411`, `ankbs`, `dev01`, `dev02` und `grc-dev`.

## Ausfuehrung

Nach `git pull`:

```powershell
Set-Location D:\_GRC_Agent\ciso-installation\tools\instance-provenance
.\Get-CisoAssistantInstanceProvenance.ps1
```

Das Skript prueft standardmaessig:

```text
D:\_Docker\ciso-assistant-local
D:\_Docker\ciso-assistant-dev01
D:\_Docker\ciso-assistant-dev02
D:\_Docker\ciso-assistant-grc-dev
```

und sucht Wrapper-Repositories unter:

```text
D:\_GRC_Agent
```

## Ergebnis

Die Ergebnisse werden unter folgendem Pfad gespeichert:

```text
D:\_Docker\_CisoInstanceProvenance\<Zeitstempel>\
```

mit:

- `ciso-instance-provenance.md`
- `ciso-instance-provenance.json`
- `ciso-instance-provenance.csv`

## Sicherheitsmerkmale

Das Skript ist read-only:

- kein `git pull`, `git fetch`, `git checkout`, `git reset` oder `git clean`
- kein `docker start`, `stop`, `compose up`, `down` oder Volume-Loeschen
- keine Aenderung an SQLite-Datenbanken
- keine Aenderung an Repository-Dateien
- keine Aenderung an PowerShell-Historie

Es liest ausschliesslich vorhandene Metadaten und erzeugt neue Reportdateien im separaten Ergebnisordner.

## Interpretation

Besonders aussagekraeftig sind:

- `WrapperRepositories`: zeigt, ob lokale Wrapper-Clones auf `MKN1411/ciso-installation`, `ankbs/ciso-installation` oder andere Quellen verweisen.
- `PowerShellHistory`: kann den damaligen Startpfad bzw. den konkreten Installer-Aufruf enthalten.
- `FirstReflogEntry`: liefert den initialen Clone-Eintrag und dessen zeitliche Einordnung.
- `DirectoryCreated`: dient zur Korrelation mit den bekannten GitHub-Fork-Zeitpunkten.

Die Kombination dieser Daten ist belastbarer als eine Zuordnung nur anhand des Instanznamens.
