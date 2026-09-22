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
