-- ============================================================================
--  SISTEMA GESPP — SCHEMA CONSOLIDATO  (file 1 di 3)
--  Fullylife Solutions
--
--  Schema completo e CORRETTO: incorpora alla radice tutte le modifiche che
--  nella vecchia sequenza erano sparse tra schema + patch 01-17.
--  Da eseguire per PRIMO su un database vuoto.
--
--  Ordine di esecuzione dei tre file consolidati:
--    1. gespp_1_schema.sql            <-- QUESTO (tabelle, tipi, trigger audit)
--    2. gespp_2_funzioni_policy.sql   (funzioni di ruolo, RLS, funzioni applicative)
--    3. gespp_3_dati_iniziali.sql     (catalogo patologie)
--
--  NB: le funzioni di audit (write_audit, fn_audit_write) sono nel file 2, ma
--  i trigger che le usano sono qui. Postgres consente di creare il trigger
--  riferito a una funzione non ancora esistente? NO: la funzione deve esistere.
--  Per questo i CREATE TRIGGER sono spostati nel file 2, DOPO le funzioni.
--  Qui creiamo solo tabelle, tipi, indici e vincoli.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- TIPI
-- ----------------------------------------------------------------------------
create type user_role      as enum ('admin', 'consulente', 'consulente_limitato');
create type person_type    as enum ('dipendente', 'professionista');
create type reciprocita_t  as enum ('Prenditore', 'Prenditore/donatore', 'Donatore/prenditore', 'Donatore');
create type consent_status as enum ('in_attesa', 'attivo', 'revocato');

-- ----------------------------------------------------------------------------
-- UTENTI APPLICATIVI
-- ----------------------------------------------------------------------------
create table public.app_users (
    id        uuid primary key references auth.users(id) on delete cascade,
    nome      text not null,
    cognome   text not null,
    email     text not null,
    ruolo     user_role not null default 'consulente',
    attivo    boolean not null default true,
    created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- AZIENDE, SEDI, REFERENTI
-- ----------------------------------------------------------------------------
create table public.companies (
    id             uuid primary key default gen_random_uuid(),
    ragione_sociale text not null,
    partita_iva    text,
    codice_fiscale text,
    settore        text,
    note           text,
    created_at     timestamptz not null default now()
);

create table public.company_sites (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null references public.companies(id) on delete cascade,
    nome_sede   text not null,
    indirizzo   text,
    citta       text,
    cap         text,
    provincia   text,
    principale  boolean not null default false,     -- patch05
    created_at  timestamptz not null default now()
);

create table public.company_contacts (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null references public.companies(id) on delete cascade,
    nome        text not null,
    cognome     text not null,
    ruolo       text,
    email       text,
    telefono    text,
    created_at  timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- PERSONE  (dipendenti dentro azienda + professionisti singoli)
-- ----------------------------------------------------------------------------
create table public.persons (
    id              uuid primary key default gen_random_uuid(),
    tipo            person_type not null,
    nome            text not null,
    cognome         text not null,
    codice_fiscale  text,
    data_nascita    date,
    email           text,
    telefono        text,
    -- campi per i dipendenti (azienda)
    company_id      uuid references public.companies(id) on delete set null,
    site_id         uuid references public.company_sites(id) on delete set null,
    reparto         text,
    ruolo_aziendale text,
    -- campo per i professionisti
    professione     text,
    -- archiviazione (patch14)
    archiviata      boolean not null default false,
    created_at      timestamptz not null default now()
);

create index idx_persons_company on public.persons(company_id);

-- ----------------------------------------------------------------------------
-- ASSEGNAZIONI consulente <-> azienda / persona
-- ----------------------------------------------------------------------------
create table public.consultant_company (
    id            uuid primary key default gen_random_uuid(),
    consultant_id uuid not null references public.app_users(id) on delete cascade,
    company_id    uuid not null references public.companies(id) on delete cascade,
    unique (consultant_id, company_id)
);

create table public.consultant_person (
    id            uuid primary key default gen_random_uuid(),
    consultant_id uuid not null references public.app_users(id) on delete cascade,
    person_id     uuid not null references public.persons(id) on delete cascade,
    unique (consultant_id, person_id)
);

-- ----------------------------------------------------------------------------
-- SPP — Struttura Psicofisiologica Primaria (storicizzata, 6 assi)
--   Versione FINALE: asse3 text, asse6_reciprocita tipizzato,
--   lateralità Destrimane/Mancino.
-- ----------------------------------------------------------------------------
create table public.spp_profiles (
    id                uuid primary key default gen_random_uuid(),
    person_id         uuid not null references public.persons(id) on delete cascade,
    consultant_id     uuid not null references public.app_users(id),
    data_rilevazione  date not null default current_date,
    asse1_sessualita  text,
    asse2_lateralita  text,
    asse3_bisogni     text,
    asse4_foglietto   text,
    asse5_intensita   text,
    asse6_reciprocita reciprocita_t,
    note              text,
    created_at        timestamptz not null default now(),

    constraint chk_lateralita check (
        asse2_lateralita is null or asse2_lateralita in ('Destrimane','Mancino')
    ),
    constraint chk_bisogni check (
        asse3_bisogni is null or asse3_bisogni in ('Protezione','Identificazione','Spazialità')
    ),
    constraint chk_foglietto check (
        asse4_foglietto is null or asse4_foglietto in ('Boccone','Attacco','Gratificazione','Socialità')
    ),
    constraint chk_intensita check (
        asse5_intensita is null or asse5_intensita in ('Inibizione','Attivazione')
    )
);

create index idx_spp_person on public.spp_profiles(person_id);
create index idx_spp_data   on public.spp_profiles(data_rilevazione);

-- ----------------------------------------------------------------------------
-- CATALOGO PATOLOGIE  (patch02, senza categoria per patch10)
-- ----------------------------------------------------------------------------
create table public.pathologies (
    id            uuid primary key default gen_random_uuid(),
    denominazione text not null unique,
    attiva        boolean not null default true,
    created_at    timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- CONSENSO SANITARIO (art. 9) — versione FINALE con consenso digitale
-- ----------------------------------------------------------------------------
create table public.health_consents (
    id              uuid primary key default gen_random_uuid(),
    person_id       uuid not null references public.persons(id) on delete cascade,
    testo_versione  text not null,
    base_giuridica  text not null default 'art. 9.2.a GDPR — consenso esplicito',
    data_consenso   timestamptz not null default now(),
    stato           consent_status not null default 'attivo',
    data_revoca     timestamptz,
    raccolto_da     uuid references public.app_users(id),
    documento_url   text,
    note            text,
    -- consenso digitale (patch15)
    token            text unique,
    token_scadenza   timestamptz,
    token_usato      boolean not null default false,
    firma_dati       text,
    spunte_accettate jsonb,
    canale           text,

    constraint chk_revoca check (
        (stato = 'in_attesa' and data_revoca is null) or
        (stato = 'attivo'    and data_revoca is null) or
        (stato = 'revocato'  and data_revoca is not null)
    )
);

create index idx_consent_person on public.health_consents(person_id);
create index idx_consent_token  on public.health_consents(token);

-- ----------------------------------------------------------------------------
-- RECORD SANITARI (art. 9) — condizione opzionale (patch07), pathology_id,
-- archiviazione (patch14)
-- ----------------------------------------------------------------------------
create table public.health_records (
    id                uuid primary key default gen_random_uuid(),
    person_id         uuid not null references public.persons(id) on delete cascade,
    consent_id        uuid not null references public.health_consents(id),
    pathology_id      uuid references public.pathologies(id),
    data_rilevazione  date not null default current_date,
    condizione        text,                 -- opzionale: la classificazione passa da pathology_id
    note_self_report  text,
    fonte             text not null default 'persona' check (fonte = 'persona'),
    archiviato        boolean not null default false,
    created_at        timestamptz not null default now()
);

create index idx_health_person on public.health_records(person_id);

-- ----------------------------------------------------------------------------
-- SELF-REPORT nel tempo (patch11) — legati a patologia o diario generale.
-- Dato sanitario art. 9. Archiviazione (patch14).
-- ----------------------------------------------------------------------------
create table public.self_reports (
    id               uuid primary key default gen_random_uuid(),
    person_id        uuid not null references public.persons(id) on delete cascade,
    health_record_id uuid references public.health_records(id) on delete cascade,  -- NULL = diario generale
    consultant_id    uuid not null references public.app_users(id),
    data_nota        date not null default current_date,
    testo            text not null,
    fonte            text not null default 'persona' check (fonte = 'persona'),
    archiviato       boolean not null default false,
    created_at       timestamptz not null default now()
);

create index idx_selfrep_person on public.self_reports(person_id);
create index idx_selfrep_hr     on public.self_reports(health_record_id);

-- ----------------------------------------------------------------------------
-- INCONTRI (patch03)
-- ----------------------------------------------------------------------------
create table public.meetings (
    id            uuid primary key default gen_random_uuid(),
    person_id     uuid not null references public.persons(id) on delete cascade,
    consultant_id uuid not null references public.app_users(id),
    data_ora      timestamptz not null,
    durata_min    integer,
    sintesi       text,
    created_at    timestamptz not null default now()
);

create index idx_meetings_person on public.meetings(person_id);

-- ----------------------------------------------------------------------------
-- STORICO PASSAGGI AZIENDA (patch04)
-- ----------------------------------------------------------------------------
create table public.person_company_history (
    id              uuid primary key default gen_random_uuid(),
    person_id       uuid not null references public.persons(id) on delete cascade,
    company_id      uuid references public.companies(id) on delete set null,
    data_inizio     timestamptz not null default now(),
    data_fine       timestamptz
);

create index idx_pch_person on public.person_company_history(person_id);

-- ----------------------------------------------------------------------------
-- AUDIT LOG
-- ----------------------------------------------------------------------------
create table public.audit_log (
    id          bigint generated always as identity primary key,
    user_id     uuid references public.app_users(id),
    azione      text not null,
    tabella     text not null,
    record_id   uuid,
    dettaglio   jsonb,
    created_at  timestamptz not null default now()
);

create index idx_audit_user on public.audit_log(user_id);
create index idx_audit_time on public.audit_log(created_at);

-- ----------------------------------------------------------------------------
-- CONFIGURAZIONE CONSENSO SANITARIO (informativa + checkbox di consenso)
-- Riga singola (id=1), come booking_email_config nello schema slot-booking.
-- Letta a runtime dalla Edge Function "consenso" invece di essere hardcoded
-- nel suo sorgente: aggiornare il testo legale non richiede più un
-- redeploy. informativa_pdf_url/consenso_pdf_url puntano a file nel bucket
-- Storage pubblico "consensi" (sola lettura per chiunque, upload solo
-- admin) — pagina anonima consenso_pagina.html deve poterli aprire senza
-- login. Entrambi nullable: un solo documento o due, a seconda di come il
-- legale struttura i contenuti.
-- ----------------------------------------------------------------------------
create table public.consent_config (
    id                   integer primary key default 1 check (id = 1),
    versione             text not null default 'v1.0',
    informativa_pdf_url  text,
    consenso_pdf_url     text,
    punti                jsonb not null default '[]',  -- [{chiave, etichetta}, ...]
    aggiornato_da        uuid references public.app_users(id),
    aggiornato_il        timestamptz not null default now()
);

-- Bucket Storage per i PDF di informativa/consenso: pubblico in lettura
-- (consenso_pagina.html e' anonima, deve poter aprire il link senza
-- login), scrittura riservata ad admin (policy su storage.objects nel
-- file 2). RLS su storage.objects e' gia' attiva di default su Supabase.
insert into storage.buckets (id, name, public)
values ('consensi', 'consensi', true)
on conflict (id) do nothing;

-- ----------------------------------------------------------------------------
-- ABILITA RLS SU TUTTE LE TABELLE (le policy sono nel file 2)
-- ----------------------------------------------------------------------------
alter table public.app_users              enable row level security;
alter table public.companies              enable row level security;
alter table public.company_sites          enable row level security;
alter table public.company_contacts       enable row level security;
alter table public.persons                enable row level security;
alter table public.consultant_company     enable row level security;
alter table public.consultant_person      enable row level security;
alter table public.spp_profiles           enable row level security;
alter table public.pathologies            enable row level security;
alter table public.health_consents        enable row level security;
alter table public.health_records         enable row level security;
alter table public.self_reports           enable row level security;
alter table public.meetings               enable row level security;
alter table public.person_company_history enable row level security;
alter table public.audit_log              enable row level security;
alter table public.consent_config         enable row level security;

-- ============================================================================
--  FINE FILE 1. Procedere con gespp_2_funzioni_policy.sql
-- ============================================================================
