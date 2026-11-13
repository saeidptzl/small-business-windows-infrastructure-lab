# Small Business Windows Infrastructure Lab · panoramica

**Laboratorio personale.** Un dominio Windows per un piccolo ufficio, con due macchine virtuali su una
rete virtuale isolata, configurato con script PowerShell e verificato con test documentati.
Documentazione completa in inglese: [README.md](README.md).

## Cosa contiene

| | |
|---|---|
| **Server DC01** | Windows Server 2025 Standard (valutazione), Server Core: Active Directory (AD DS), DNS, condivisioni SMB, Windows Server Backup |
| **Client CL01** | Windows 11 Enterprise LTSC 2024 (valutazione), aggiunto al dominio, Secure Boot e TPM 2.0 |
| **Rete** | 10.10.50.0/24 isolata: solo tra le due VM, senza gateway né Internet |
| **Virtualizzazione** | QEMU/KVM su Ubuntu, senza privilegi di root |

* **Active Directory:** dominio `corp.smallbiz.test`, struttura di OU, gruppi secondo il modello
  **AGDLP** (gruppo globale di reparto → gruppo locale di dominio → permesso), utenti fittizi.
* **Cartelle di reparto:** Finance e Operations, con accesso controllato da **permessi di condivisione e
  NTFS**. L'accesso è verificato sui percorsi UNC, non solo tramite la lettera di unità.
* **Group Policy:** una sola GPO che mappa `F:` (Finance) o `O:` (Operations) in base al gruppo.
* **Backup e ripristino:** ripristino di un file con Windows Server Backup in un percorso alternativo,
  verificato con hash SHA-256. Ambito volutamente limitato: un solo file, nessuna strategia 3-2-1.

## I due ticket di assistenza

1. **Onboarding di un nuovo dipendente:** creazione dell'account nel reparto giusto, primo accesso con
   cambio password obbligatorio, unità del proprio reparto presente, accesso alla propria cartella
   consentito e alla cartella dell'altro reparto **negato**. Esito: 7/7 PASS (un caso eseguito a mano,
   uno con lo script).
2. **Guasto DNS:** il client punta a un DNS pubblico (8.8.8.8). Dopo il riavvio l'utente non trova più
   l'unità e il percorso di rete non viene trovato. Diagnosi dal client (IP raggiungibile, DNS
   sbagliato, il DNS di Active Directory risponde correttamente), correzione e verifica. Esito: 7/7 PASS.
   Il primo tentativo di correzione ha evidenziato un problema di canale sicuro, risolto e documentato.

Risultati dettagliati (atteso e osservato per ogni controllo): [docs/test-results.md](docs/test-results.md) ·
Procedure operative: [RB-01](docs/runbooks/RB-01-new-employee-onboarding.md),
[RB-02](docs/runbooks/RB-02-dns-resolution-incident.md), [RB-03](docs/runbooks/RB-03-file-recovery.md).

## Limiti dichiarati

* Licenze di valutazione senza connessione: il client Windows 11 è andato subito in modalità
  "notifica" (licenza scaduta). Il laboratorio ha funzionato comunque.
* AD DS, DNS e file server sullo stesso server vanno bene per un laboratorio, ma in produzione
  creano un unico punto di guasto. La soluzione consigliata è descritta in
  [docs/architecture.md](docs/architecture.md).
