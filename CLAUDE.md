# GESPP

## Note di architettura / attenzioni

**RPC sensibili (security definer che espongono dati di persone).** Le
funzioni `team_members_light()` e `team_categories()` sono `security
definer` con `row_security = off`: bypassano di proposito la RLS di
`persons`, per esporre rispettivamente i membri di un team (nome/cognome/
azienda) e il conteggio aziende per team. Il bypass è confinato — restituiscono
solo quei campi, mai dati sanitari. Il gate d'accesso resta
`can_access_team(team_id)`: chiunque le modifichi (un campo in più nel
return, un cambio al gate) deve **ri-eseguire i test GDPR T1-T4**:
- un consulente vede solo i team a cui è assegnato;
- un admin li vede tutti;
- il conteggio aziende resta corretto anche quando la RLS di `persons`
  negherebbe l'accesso diretto (team interaziendale con un membro di
  un'azienda a cui il consulente non è collegato → `n_aziende` deve
  restare esatto, non falsato per difetto);
- nessun dato di persona esce oltre ai campi dichiarati dalla funzione.

**Team interni vs interaziendali (derivati, nessun campo dedicato).** La
categoria di un team non è memorizzata da nessuna parte: si deriva dal
numero di aziende distinte tra i suoi membri — 1 azienda = team interno a
quell'azienda, ≥2 = interaziendale, 0 (nessun membro) = resta nella
sezione team globale come default sicuro. `teams` non ha una colonna
`company_id`: è una scelta voluta, non una dimenticanza (neutralità del
team rispetto all'azienda). Un team interno che riceve un membro di
un'altra azienda migra automaticamente dalla scheda azienda alla sezione
team globale, senza bisogno di logica dedicata alla migrazione. L'accesso
resta comunque governato da `can_access_team` — un grafo separato da
`can_access_person`: dentro la scheda di un'azienda, un consulente vede
solo i team interni a cui è assegnato, non tutti i team di quell'azienda.

**Trasferte (tab "Trasferte", tabelle `travel_*`, script `schema/gespp_trasferte.sql`).**
Ogni consulente registra schede cliente (percorso abituale) e trasferte su più
giorni, solo per le aziende assegnate (`travel_company_ok()`: admin tutte,
altri via `consultant_company` — NON basta leggere `companies`, chi ha
`puo_fatturare` le legge tutte). Il gestionale le legge e le mette in fattura:
una trasferta con `invoice_id` è bloccata (RLS) e `invoice_id` lo scrivono solo
le RPC `travel_trip_link/unlink/move_invoice`. km e caselli dalla Edge Function
`travel-route` (`functions/edge_travel_route.ts`, secret `HERE_API_KEY`); il
pedaggio in euro resta manuale di proposito: HERE sovrastima in modo
irregolare rispetto a Moveo (+9%/+15%/+40% su tre tratte, 2026-11-14).
Veicoli (`travel_vehicles`, solo proprietario): la scheda punta al veicolo e
NON salva la tariffa (aggiornamento ACI annuale in un punto solo); la
trasferta salva una COPIA di nome/tariffa, così le note spese passate non
cambiano. Pedaggio automatico dalla scheda (`TR_EDIT.autoPed`): andata primo
giorno, ritorno ultimo, ricalcolato a ogni cambio date/A-R finché l'utente non
scrive un pedaggio a mano.
