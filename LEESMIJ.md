# LiDAR Scan – eigen iPhone-app zonder abonnement

Voor iPhones met LiDAR (12 Pro en nieuwer, gemaakt voor iPhone 15 Pro), iOS 17 of nieuwer.

## Wat zit erin (versie 1.1)

| Tabblad | Wat het doet | Bestanden |
|---|---|---|
| **Scan** | Live LiDAR-mesh + gekleurde puntenwolk (5 mm raster, alleen betrouwbare punten). Optie "alleen object rond het kruisje" + "alleen grootste stuk" haalt losse rommel/vloer weg. Toont direct de afmetingen. | `.stl` (mm, z omhoog, op printbed), `.obj` (meters), `.ply` (meters, kleur) |
| **3D-print** | Apple Object Capture (foto's + LiDAR), op de iPhone zelf verwerkt. Meerdere rondes (laag/midden/hoog) en object omdraaien voor de onderkant. Toont afmeting in mm. | `.usdz` (met textuur) + `.stl` (mm) |
| **Kamer** | Apple RoomPlan: plattegrond met muurmaten, vloer-/wandoppervlak (bruto/netto), plafondhoogte, deuren, ramen, meubels. | `.pdf` (A4, voor offerte/klant), `.usdz`, `plattegrond.png`, `maten.txt` |
| **Meten** | Punten plaatsen met het kruisje: afstand per stuk, totaal, hoogteverschil, oppervlakte. Live afstand tot het kruisje. Opslaan als tekst. | `Meting ….txt` |
| **Bestanden** | Ingebouwde 3D-viewer voor STL/OBJ/PLY met afmetingen; voorbeeld van PDF/PNG/USDZ; delen (AirDrop, mail, WhatsApp); vegen = verwijderen. Ook zichtbaar in de Bestanden-app onder *Op mijn iPhone › LiDAR Scan*. | – |

Overig: scherm blijft aan tijdens gebruik, trillingsfeedback bij acties, exports draaien op de achtergrond.

**Tips**
- Voor 3D-printen van kleine/gedetailleerde dingen: tabblad **3D-print**. De mesh uit **Scan** is ca. 1–2 cm nauwkeurig – prima voor ruimtes, meubels en grote onderdelen.
- Controleer na een scan altijd één maat met een duimstok; de app toont de afmetingen zodat je dat snel ziet.
- Glanzende, doorzichtige of hele donkere objecten scannen slecht (bij elke LiDAR-app). Mat maken met wat poeder/krijtspray helpt.
- Puntenwolk `.ply` opent in CloudCompare (gratis), MeshLab of Autodesk ReCap.

---

## Installeren met een Windows-pc (eenmalig, ~30 min)

Nodig: Windows-pc, USB-kabel, gratis GitHub-account, je gewone Apple ID. Geen Mac en geen betaald account.

### Stap 1 – GitHub bouwt de app
1. Maak een account op github.com → **New repository**, naam bijv. `lidarscan`, kies **Public** (dan werkt de downloadlink zonder inloggen; de code bevat geen geheimen).
2. Pak de zip uit. Zet in Verkenner **Beeld › Verborgen items** aan (voor de map `.github`).
3. Klik **uploading an existing file** en sleep de **inhoud** van de map `LidarScan` erin (`project.yml`, `LEESMIJ.md`, `LidarScan/`, `.github/`). Klik **Commit changes**.
4. Tabblad **Actions**: wacht op het groene vinkje (5–10 min).
5. De app staat nu onder **Releases** (rechts op de repository-pagina). Vaste downloadlink voor je iPhone:
   `https://github.com/JOUWNAAM/lidarscan/releases/latest/download/LidarScan.ipa`

### Stap 2 – Pc voorbereiden
- Installeer **iTunes van apple.com** (niet de Microsoft Store-versie) – voor de iPhone-drivers.
- Installeer **iloader** (iloader.app → Windows-installer).

### Stap 3 – iPhone klaarzetten
- Aansluiten met kabel, ontgrendelen, **Vertrouw**.
- **Instellingen › Privacy en beveiliging › Ontwikkelaarsmodus** aan → herstart → bevestigen.

### Stap 4 – SideStore installeren
- iloader → **Add Account** (Apple ID, hoofdlettergevoelig) → kies je iPhone → **Install SideStore (Stable)** → 2FA-code invullen.
- iPhone: **Instellingen › Algemeen › VPN en apparaatbeheer** → je Apple ID → **Vertrouw**.
- Open SideStore, log in met dezelfde Apple ID en installeer de lokale VPN-app die SideStore aangeeft (gratis, App Store). Kabel mag eruit.

### Stap 5 – LiDAR Scan installeren
- Open de downloadlink uit stap 1 in Safari → download.
- SideStore → **My Apps** → **+** → kies `LidarScan.ipa` uit Downloads.

### Elke 7 dagen verversen (op de telefoon zelf)
VPN-app aan → SideStore → **Refresh All**. Of zet achtergrondverversing aan in SideStore. Je scans blijven bewaard.

### Updates
Nieuwe versie van de code uploaden naar GitHub → nieuwe build verschijnt bij Releases → zelfde downloadlink → in SideStore opnieuw installeren (over de oude heen, scans blijven staan).

Let op: een gratis Apple ID mag 3 eigen apps tegelijk hebben (SideStore telt mee).

---

## Als de bouw mislukt (rood kruis)
Klik op de mislukte run → stap **Foutmeldingen tonen** → kopieer de regels met `error:` (of download **build-log**) en stuur ze naar Claude.

## Projectstructuur
```
project.yml                 – projectdefinitie (XcodeGen maakt hier het Xcode-project van)
.github/workflows/build.yml – bouwt de .ipa op een Mac van GitHub
LidarScan/
  LidarScanApp.swift        – app + tabbladen
  ScanScreen.swift          – LiDAR-mesh + puntenwolk
  ObjectCaptureScreen.swift – 3D-print scan (Object Capture)
  RoomScreen.swift          – kamerscan + plattegrond (RoomPlan)
  MeasureScreen.swift       – meten
  FilesScreen.swift         – bestandenoverzicht
  MeshIO.swift              – export naar STL / OBJ / PLY, opschonen (samenvoegen, grootste stuk)
  ModelViewer.swift         – 3D-viewer met afmetingen
  Assets.xcassets           – app-icoon
```
