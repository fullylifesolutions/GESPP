-- ============================================================================
--  TEST GDPR — team_categories() — quattro scenari indipendenti (gate FASE B)
--
--  PREREQUISITO team_categories(): la funzione deve già esistere in TEST
--  (FASE A applicata) prima di lanciare questo script.
--
--  SCENARIO T1: un consulente assegnato SOLO ad alcuni team (via
--  consultant_team) deve ottenere da team_categories() solo quei team —
--  non tutti i team esistenti nel database.
--
--  SCENARIO T2: un admin deve ottenere TUTTI i team (bypass di
--  can_access_team via is_admin()), incluso ciò che T1 escludeva.
--
--  SCENARIO T3 (chiave — dimostra che row_security=off è necessario, non
--  solo "comodo"): un team con membri di 2 aziende diverse, dove il
--  consulente è assegnato al TEAM (consultant_team) ma NON a nessuna delle
--  due aziende (nessuna riga consultant_company) né alle persone
--  (nessuna consultant_person). Se il bypass RLS su persons non ci fosse,
--  il join interno alla funzione vedrebbe zero persone (can_access_person()
--  le nasconderebbe entrambe) e n_aziende risulterebbe 0 — un team
--  interaziendale classificato come "vuoto", categoria sbagliata. Con
--  row_security=off il conteggio è quello vero: n_aziende=2.
--
--  SCENARIO T4: la funzione non deve restituire alcun dato di persona
--  (nome/cognome) oltre al conteggio aziende e al company_id univoco —
--  né in forma di colonna dichiarata né in forma di valore in una colonna
--  testuale esistente (es. infilato per errore nella colonna "nome" del
--  team). Verificato in due modi: (a) le colonne dichiarate dalla funzione
--  (catalogo, nessuna RLS coinvolta) sono esattamente team_id/nome/
--  n_aziende/company_id; (b) un marcatore univoco messo nel nome/cognome di
--  una persona di test NON compare in nessuna riga restituita.
--
--  PREREQUISITO (una tantum per ambiente, non automatizzabile in SQL):
--    app_users.id referenzia auth.users(id) — serve un vero utente Auth
--    usa-e-getta: Dashboard Supabase (TEST) → Authentication → Users →
--    Add user (email/password a piacere, "Auto Confirm User" attivo).
--    Copia il suo UUID: va incollato UNA VOLTA PER SCRIPT al posto di
--    'INCOLLA-QUI-UUID-UTENTE-AUTH' (stesso utente per tutti e quattro gli
--    scenari, riconfigurato di volta in volta).
--
--  ESECUZIONE — QUATTRO SCRIPT INDIPENDENTI, UNO ALLA VOLTA: svuota l'SQL
--  Editor (Ctrl+A, Canc), incolla e lancia SOLO uno script, leggi l'esito,
--  svuota di nuovo, passa al successivo. Non incollarne due insieme.
--
--  Ogni script è autocontenuto (crea i propri team/aziende/persone di
--  prova) dentro un'UNICA transazione con rollback finale SEMPRE eseguito:
--  zero residui, ripetibile quante volte serve. L'utente Auth stesso resta
--  e va riusato o eliminato manualmente dal Dashboard quando non serve più.
--
--  ESITO ATTESO: ogni riga dice da sola cosa verifica e cosa si aspetta
--  nella colonna "verifica". Le righe "ATTESO: ... controllo positivo"
--  sono obbligatorie sopra zero: senza, uno zero altrove sarebbe un falso
--  positivo (sessione mal impersonata), non una prova reale di isolamento.
-- ============================================================================


-- ============================================================================
--  SCRIPT 1/4 — SCENARIO T1
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

insert into public.app_users (id, nome, cognome, email, ruolo, attivo, puo_fatturare)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'TeamCat T1',
        'test.teamcat.t1@example.invalid', 'consulente', true, false)
on conflict (id) do update
    set ruolo = 'consulente', attivo = true, puo_fatturare = false;

-- Pulizia difensiva: niente assegnazioni residue da eventuali usi precedenti
-- di questo stesso utente Auth fuori da una transazione con rollback.
delete from public.consultant_team where consultant_id = current_setting('test.gdpr_user_id')::uuid;

-- Due team di prova indipendenti: A (il nostro utente sarà assegnato) e B
-- (non assegnato) — nessuna delle due categorie conta qui, serve solo che
-- esistano e che siano distinguibili.
with ta as (
    insert into public.teams (nome) values ('TEST team_categories T1 — team A (assegnato)') returning id
)
select set_config('test.team_a_id', id::text, true) from ta;

with tb as (
    insert into public.teams (nome) values ('TEST team_categories T1 — team B (non assegnato)') returning id
)
select set_config('test.team_b_id', id::text, true) from tb;

insert into public.consultant_team (consultant_id, team_id)
values (current_setting('test.gdpr_user_id')::uuid, current_setting('test.team_a_id')::uuid);

set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('T1. ruolo utente (atteso: consulente)', (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid)::text),
    ('T1. vede team A (ATTESO: 1 - controllo positivo, assegnato via consultant_team)', (select count(*) from public.team_categories() where team_id = current_setting('test.team_a_id')::uuid)::text),
    ('T1. NON vede team B (atteso: 0 - non assegnato)', (select count(*) from public.team_categories() where team_id = current_setting('test.team_b_id')::uuid)::text)
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, team A/B, assegnazione. Zero
          -- residui, ripetibile quante volte serve.


-- ============================================================================
--  SCRIPT 2/4 — SCENARIO T2 (eseguire DOPO aver letto l'esito dello Script 1,
--  in un editor svuotato — non incollare di seguito allo Script 1)
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

insert into public.app_users (id, nome, cognome, email, ruolo, attivo)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'TeamCat T2',
        'test.teamcat.t2@example.invalid', 'admin', true)
on conflict (id) do update
    set ruolo = 'admin', attivo = true;

delete from public.consultant_team where consultant_id = current_setting('test.gdpr_user_id')::uuid;

-- Stessa coppia di team di T1, senza NESSUNA assegnazione consultant_team:
-- l'admin deve vederli comunque entrambi (bypass is_admin() dentro
-- can_access_team, non dipende da alcuna riga in consultant_team).
with ta as (
    insert into public.teams (nome) values ('TEST team_categories T2 — team A') returning id
)
select set_config('test.team_a_id', id::text, true) from ta;

with tb as (
    insert into public.teams (nome) values ('TEST team_categories T2 — team B') returning id
)
select set_config('test.team_b_id', id::text, true) from tb;

set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('T2. ruolo utente (atteso: admin)', (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid)::text),
    ('T2. vede team A (ATTESO: 1 - controllo positivo, admin bypassa consultant_team)', (select count(*) from public.team_categories() where team_id = current_setting('test.team_a_id')::uuid)::text),
    ('T2. vede ANCHE team B senza alcuna assegnazione (ATTESO: 1 - controllo positivo, stessa dimostrazione)', (select count(*) from public.team_categories() where team_id = current_setting('test.team_b_id')::uuid)::text)
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, team A/B. Zero residui,
          -- ripetibile quante volte serve.


-- ============================================================================
--  SCRIPT 3/4 — SCENARIO T3 — CHIAVE (eseguire DOPO aver letto l'esito dello
--  Script 2, in un editor svuotato — non incollare di seguito ai precedenti)
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

insert into public.app_users (id, nome, cognome, email, ruolo, attivo, puo_fatturare)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'TeamCat T3',
        'test.teamcat.t3@example.invalid', 'consulente', true, false)
on conflict (id) do update
    set ruolo = 'consulente', attivo = true, puo_fatturare = false;

-- Pulizia difensiva su TUTTI i legami che darebbero accesso a persons/
-- companies per altra via: il punto dello scenario è che l'UNICO legame
-- del consulente è al TEAM, non alle aziende né alle persone.
delete from public.consultant_team    where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_company where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_person  where consultant_id = current_setting('test.gdpr_user_id')::uuid;

-- Due aziende di prova, nessun legame consultant_company verso nessuna
-- delle due.
with x as (
    insert into public.companies (ragione_sociale) values ('TEST team_categories T3 — azienda X') returning id
)
select set_config('test.company_x_id', id::text, true) from x;

with y as (
    insert into public.companies (ragione_sociale) values ('TEST team_categories T3 — azienda Y') returning id
)
select set_config('test.company_y_id', id::text, true) from y;

-- Una persona per azienda, nessun legame consultant_person.
with px as (
    insert into public.persons (tipo, nome, cognome, company_id)
    values ('dipendente', 'Test', 'Persona X', current_setting('test.company_x_id')::uuid)
    returning id
)
select set_config('test.person_x_id', id::text, true) from px;

with py as (
    insert into public.persons (tipo, nome, cognome, company_id)
    values ('dipendente', 'Test', 'Persona Y', current_setting('test.company_y_id')::uuid)
    returning id
)
select set_config('test.person_y_id', id::text, true) from py;

-- Il team interaziendale: un membro di X, uno di Y.
with tc as (
    insert into public.teams (nome) values ('TEST team_categories T3 — team interaziendale') returning id
)
select set_config('test.team_c_id', id::text, true) from tc;

insert into public.team_members (team_id, person_id) values
    (current_setting('test.team_c_id')::uuid, current_setting('test.person_x_id')::uuid),
    (current_setting('test.team_c_id')::uuid, current_setting('test.person_y_id')::uuid);

-- L'UNICO legame del consulente: al team, non alle aziende/persone.
insert into public.consultant_team (consultant_id, team_id)
values (current_setting('test.gdpr_user_id')::uuid, current_setting('test.team_c_id')::uuid);

set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('T3. ruolo utente (atteso: consulente)', (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid)::text),
    ('T3. NON vede azienda X direttamente (atteso: 0 - nessun legame, prova che non e per quella via che arriva il conteggio)', (select count(*) from public.companies where id = current_setting('test.company_x_id')::uuid)::text),
    ('T3. NON vede la persona di X direttamente (atteso: 0 - can_access_person nega, nessun legame)', (select count(*) from public.persons where id = current_setting('test.person_x_id')::uuid)::text),
    ('T3. vede il team (ATTESO: 1 - controllo positivo, assegnato via consultant_team)', (select count(*) from public.team_categories() where team_id = current_setting('test.team_c_id')::uuid)::text),
    ('T3. n_aziende del team (ATTESO: 2 - conteggio VERO grazie al bypass row_security=off, non 0 ne 1)', (select n_aziende from public.team_categories() where team_id = current_setting('test.team_c_id')::uuid)::text),
    ('T3. company_id del team (atteso: NULL - n_aziende>1, nessun company_id univoco)', coalesce((select company_id from public.team_categories() where team_id = current_setting('test.team_c_id')::uuid)::text, 'NULL'))
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, aziende X/Y, persone, team,
          -- membership, assegnazione. Zero residui, ripetibile quante
          -- volte serve.


-- ============================================================================
--  SCRIPT 4/4 — SCENARIO T4 (eseguire DOPO aver letto l'esito dello Script 3,
--  in un editor svuotato — non incollare di seguito ai precedenti)
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

insert into public.app_users (id, nome, cognome, email, ruolo, attivo, puo_fatturare)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'TeamCat T4',
        'test.teamcat.t4@example.invalid', 'consulente', true, false)
on conflict (id) do update
    set ruolo = 'consulente', attivo = true, puo_fatturare = false;

delete from public.consultant_team    where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_company where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_person  where consultant_id = current_setting('test.gdpr_user_id')::uuid;

-- Un'azienda, una persona con un marcatore univoco nel nome/cognome (mai
-- usato altrove, riconoscibile senza ambiguità in un LIKE), un team con
-- quella persona come unico membro. Nome del TEAM tenuto deliberatamente
-- diverso dal marcatore: se il marcatore comparisse comunque in una riga
-- restituita da team_categories(), sarebbe una fuga di dato di persona.
with x as (
    insert into public.companies (ragione_sociale) values ('TEST team_categories T4 — azienda') returning id
)
select set_config('test.company_x_id', id::text, true) from x;

with p as (
    insert into public.persons (tipo, nome, cognome, company_id)
    values ('dipendente', 'MARCATORE-PERSONA-UNIVOCO-T4', 'NON-DEVE-COMPARIRE', current_setting('test.company_x_id')::uuid)
    returning id
)
select set_config('test.person_id', id::text, true) from p;

with t as (
    insert into public.teams (nome) values ('TEST team_categories T4 — team innocuo') returning id
)
select set_config('test.team_id', id::text, true) from t;

insert into public.team_members (team_id, person_id)
values (current_setting('test.team_id')::uuid, current_setting('test.person_id')::uuid);

insert into public.consultant_team (consultant_id, team_id)
values (current_setting('test.gdpr_user_id')::uuid, current_setting('test.team_id')::uuid);

set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('T4. ruolo utente (atteso: consulente)', (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid)::text),
    ('T4. vede il team (ATTESO: 1 - controllo positivo, altrimenti gli altri 0 sarebbero un falso positivo)', (select count(*) from public.team_categories() where team_id = current_setting('test.team_id')::uuid)::text),
    ('T4. n_aziende del team (atteso: 1 - un solo membro/azienda, informativo)', (select n_aziende from public.team_categories() where team_id = current_setting('test.team_id')::uuid)::text),
    ('T4. colonne dichiarate dalla funzione (atteso: esattamente team_id uuid, nome text, n_aziende integer, company_id uuid - nessuna colonna di persona)', pg_get_function_result('public.team_categories()'::regprocedure)),
    ('T4. marcatore nome persona NON compare in nessuna riga (ATTESO: 0 - la funzione non emette mai nome/cognome di persons)', (select count(*) from public.team_categories() where nome ilike '%MARCATORE-PERSONA%' or team_id::text ilike '%MARCATORE-PERSONA%')::text)
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, azienda, persona (marcatore
          -- incluso), team, membership, assegnazione. Zero residui,
          -- ripetibile quante volte serve.
