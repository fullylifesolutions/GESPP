-- ============================================================================
--  TRASFERTE — schede cliente, trasferte su più giorni, collegamento in fattura
--  Da eseguire su TEST, poi su PROD (SQL Editor), DOPO gli script GESPP e
--  gestionale (usa companies, app_users, consultant_company, invoices,
--  can_bill(), can_use_emitter(), is_admin(), fn_audit_write()).
--
--  travel_profiles   scheda trasferta di un consulente per un cliente
--                    (percorso, km, tariffa, pedaggio abituale): si compila
--                    una volta, poi precompila ogni nuova trasferta.
--  travel_trips      la singola trasferta: giorno di partenza e di rientro,
--                    km/tariffa una volta sola per tutta la trasferta.
--  travel_trip_days  una riga per ogni giorno: pedaggi, parcheggi, trasporti,
--                    vitto, alloggio, altre spese.
--
--  Chi vede cosa:
--   - schede: solo il proprietario (l'admin le legge tutte);
--   - trasferte: il proprietario; in lettura anche admin e chi ha
--     puo_fatturare (le mette in fattura dal gestionale);
--   - si creano solo per aziende ASSEGNATE (consultant_company) — l'admin su
--     tutte;
--   - una trasferta già inserita in un documento (invoice_id valorizzato)
--     non è più modificabile né cancellabile dal proprietario.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TABELLE
-- ----------------------------------------------------------------------------
create table if not exists public.travel_profiles (
    id               uuid primary key default gen_random_uuid(),
    owner_id         uuid not null references public.app_users(id) on delete cascade,
    company_id       uuid not null references public.companies(id) on delete cascade,
    partenza         text not null,
    destinazione     text not null,
    km_andata        numeric(7,1) check (km_andata >= 0),
    andata_ritorno   boolean not null default true,
    tariffa_km       numeric(6,4) check (tariffa_km >= 0),
    veicolo          text,
    -- pedaggio di SOLA andata, inserito a mano (es. da Moveo): il valore
    -- calcolato da HERE non è affidabile, vedi edge_travel_route.ts
    pedaggio_andata  numeric(8,2) check (pedaggio_andata >= 0),
    caselli          text,   -- informativo, da HERE (es. "Melegnano → Casalecchio di Reno")
    note             text,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz
);
create index if not exists idx_travel_profiles_owner   on public.travel_profiles(owner_id);
create index if not exists idx_travel_profiles_company on public.travel_profiles(company_id);

create table if not exists public.travel_trips (
    id               uuid primary key default gen_random_uuid(),
    -- nessun on delete: una trasferta è un dato contabile, non deve sparire
    -- con l'utente o con l'azienda (la cancellazione resta bloccata dalla FK)
    owner_id         uuid not null references public.app_users(id),
    owner_nome       text,   -- copia del nome, per il gestionale (app_users è leggibile solo dall'admin)
    company_id       uuid not null references public.companies(id),
    profile_id       uuid references public.travel_profiles(id) on delete set null,
    data_partenza    date not null,
    data_rientro     date not null,
    partenza         text not null,
    destinazione     text not null,
    km_andata        numeric(7,1) not null default 0 check (km_andata >= 0),
    andata_ritorno   boolean not null default true,
    tariffa_km       numeric(6,4) not null default 0 check (tariffa_km >= 0),
    veicolo          text,
    caselli          text,
    descrizione      text,
    -- calcolato dal DB, arrotondato al centesimo: niente valori a 3+ decimali in fattura
    rimborso_km      numeric(12,2) generated always as
                     (round(km_andata * (case when andata_ritorno then 2 else 1 end) * tariffa_km, 2)) stored,
    -- documento del gestionale in cui è stata inserita. Scritto SOLO dalle
    -- funzioni travel_trip_link_invoice/travel_trip_unlink_invoice. Se il
    -- documento (bozza) viene cancellato, la trasferta torna da fatturare.
    invoice_id       uuid references public.invoices(id) on delete set null,
    collegata_at     timestamptz,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz,
    check (data_rientro >= data_partenza),
    check (data_rientro - data_partenza <= 60)
);
create index if not exists idx_travel_trips_owner   on public.travel_trips(owner_id);
create index if not exists idx_travel_trips_company on public.travel_trips(company_id);
create index if not exists idx_travel_trips_invoice on public.travel_trips(invoice_id);

create table if not exists public.travel_trip_days (
    id          uuid primary key default gen_random_uuid(),   -- serve a fn_audit_write
    trip_id     uuid not null references public.travel_trips(id) on delete cascade,
    giorno      date not null,
    pedaggi     numeric(10,2) not null default 0 check (pedaggi   >= 0),
    parcheggi   numeric(10,2) not null default 0 check (parcheggi >= 0),
    trasporti   numeric(10,2) not null default 0 check (trasporti >= 0),
    vitto       numeric(10,2) not null default 0 check (vitto     >= 0),
    alloggio    numeric(10,2) not null default 0 check (alloggio  >= 0),
    altre       numeric(10,2) not null default 0 check (altre     >= 0),
    note        text,
    unique (trip_id, giorno)
);

alter table public.travel_profiles  enable row level security;
alter table public.travel_trips     enable row level security;
alter table public.travel_trip_days enable row level security;

-- ----------------------------------------------------------------------------
-- 2. FUNZIONI
-- ----------------------------------------------------------------------------
-- Azienda utilizzabile per schede/trasferte: admin tutte, altri solo le
-- aziende assegnate. NB: NON basta poter leggere companies — chi ha
-- puo_fatturare le legge tutte (companies_billing_select).
create or replace function public.travel_company_ok(p_company_id uuid)
returns boolean language sql stable security definer
set search_path = public set row_security = off
as $$
    select public.is_admin() or exists (
        select 1 from public.consultant_company cc
        where cc.company_id = p_company_id and cc.consultant_id = auth.uid()
    );
$$;

-- Timbro lato DB: proprietario e date non arrivano mai dal frontend.
create or replace function public.travel_profiles_stamp()
returns trigger language plpgsql set search_path = public
as $$
begin
    if TG_OP = 'INSERT' then
        NEW.owner_id   := auth.uid();
        NEW.created_at := now();
        NEW.updated_at := null;
    else
        NEW.owner_id   := OLD.owner_id;
        NEW.created_at := OLD.created_at;
        NEW.updated_at := now();
    end if;
    return NEW;
end; $$;

create or replace function public.travel_trips_stamp()
returns trigger language plpgsql set search_path = public
as $$
begin
    if TG_OP = 'INSERT' then
        NEW.owner_id     := auth.uid();
        NEW.owner_nome   := (select trim(coalesce(u.nome,'') || ' ' || coalesce(u.cognome,''))
                             from public.app_users u where u.id = auth.uid());
        NEW.invoice_id   := null;
        NEW.collegata_at := null;
        NEW.created_at   := now();
        NEW.updated_at   := null;
    else
        NEW.owner_id   := OLD.owner_id;
        NEW.owner_nome := OLD.owner_nome;
        NEW.created_at := OLD.created_at;
        NEW.updated_at := now();
    end if;
    return NEW;
end; $$;

drop trigger if exists trg_travel_profiles_stamp on public.travel_profiles;
create trigger trg_travel_profiles_stamp before insert or update on public.travel_profiles
    for each row execute function public.travel_profiles_stamp();
drop trigger if exists trg_travel_trips_stamp on public.travel_trips;
create trigger trg_travel_trips_stamp before insert or update on public.travel_trips
    for each row execute function public.travel_trips_stamp();

-- Salvataggio di una trasferta con tutti i suoi giorni in UNA transazione
-- (testata + giorni insieme, mai una trasferta salvata a metà).
-- security INVOKER: valgono le policy RLS di chi chiama.
--   p_trip: {id?, company_id, profile_id?, data_partenza, data_rientro,
--            partenza, destinazione, km_andata, andata_ritorno, tariffa_km,
--            veicolo, caselli, descrizione}
--   p_days: [{giorno, pedaggi, parcheggi, trasporti, vitto, alloggio, altre, note}]
create or replace function public.travel_trip_save(p_trip jsonb, p_days jsonb)
returns uuid language plpgsql security invoker set search_path = public
as $$
declare
    v_id uuid := nullif(p_trip->>'id','')::uuid;
    v_dp date := nullif(p_trip->>'data_partenza','')::date;
    v_dr date := nullif(p_trip->>'data_rientro','')::date;
    v_n  integer;
begin
    if v_dp is null or v_dr is null or v_dr < v_dp then
        raise exception 'Date della trasferta non valide' using errcode = '22023';
    end if;

    if v_id is null then
        insert into public.travel_trips (company_id, profile_id, data_partenza, data_rientro,
            partenza, destinazione, km_andata, andata_ritorno, tariffa_km, veicolo, caselli, descrizione)
        values (
            (p_trip->>'company_id')::uuid,
            nullif(p_trip->>'profile_id','')::uuid,
            v_dp, v_dr,
            p_trip->>'partenza', p_trip->>'destinazione',
            coalesce(nullif(p_trip->>'km_andata','')::numeric, 0),
            coalesce((p_trip->>'andata_ritorno')::boolean, true),
            coalesce(nullif(p_trip->>'tariffa_km','')::numeric, 0),
            nullif(p_trip->>'veicolo',''), nullif(p_trip->>'caselli',''), nullif(p_trip->>'descrizione','')
        )
        returning id into v_id;
    else
        update public.travel_trips set
            company_id     = (p_trip->>'company_id')::uuid,
            profile_id     = nullif(p_trip->>'profile_id','')::uuid,
            data_partenza  = v_dp,
            data_rientro   = v_dr,
            partenza       = p_trip->>'partenza',
            destinazione   = p_trip->>'destinazione',
            km_andata      = coalesce(nullif(p_trip->>'km_andata','')::numeric, 0),
            andata_ritorno = coalesce((p_trip->>'andata_ritorno')::boolean, true),
            tariffa_km     = coalesce(nullif(p_trip->>'tariffa_km','')::numeric, 0),
            veicolo        = nullif(p_trip->>'veicolo',''),
            caselli        = nullif(p_trip->>'caselli',''),
            descrizione    = nullif(p_trip->>'descrizione','')
        where id = v_id;
        get diagnostics v_n = row_count;
        -- 0 righe = la RLS l'ha esclusa: non è tua o è già in un documento
        if v_n = 0 then
            raise exception 'Trasferta non modificabile: è già stata inserita in un documento oppure non è tua'
                using errcode = '42501';
        end if;
    end if;

    delete from public.travel_trip_days where trip_id = v_id;
    insert into public.travel_trip_days (trip_id, giorno, pedaggi, parcheggi, trasporti, vitto, alloggio, altre, note)
    select v_id,
           (d->>'giorno')::date,
           coalesce(nullif(d->>'pedaggi','')::numeric, 0),
           coalesce(nullif(d->>'parcheggi','')::numeric, 0),
           coalesce(nullif(d->>'trasporti','')::numeric, 0),
           coalesce(nullif(d->>'vitto','')::numeric, 0),
           coalesce(nullif(d->>'alloggio','')::numeric, 0),
           coalesce(nullif(d->>'altre','')::numeric, 0),
           nullif(d->>'note','')
    from jsonb_array_elements(coalesce(p_days, '[]'::jsonb)) d;

    if exists (select 1 from public.travel_trip_days
               where trip_id = v_id and (giorno < v_dp or giorno > v_dr)) then
        raise exception 'Un giorno di spesa è fuori dal periodo della trasferta' using errcode = '22023';
    end if;

    return v_id;
end; $$;

-- Collega la trasferta a un documento del gestionale. Chiamata dal
-- gestionale SOLO dopo il salvataggio riuscito del documento.
-- security DEFINER: il proprietario non può scrivere invoice_id (policy),
-- quindi questo è l'unico percorso. Controlli: permesso di fatturazione,
-- emittente del documento utilizzabile, trasferta non già collegata a un
-- altro documento (la garanzia contro la doppia fatturazione).
-- NB lo stato del documento NON si controlla qui: il frontend offre come
-- destinazione solo bozze o documenti nuovi, ma il collegamento avviene
-- dopo il salvataggio, quando un documento nuovo può essere già "emesso"
-- (salvato direttamente come inviato).
create or replace function public.travel_trip_link_invoice(p_trip_id uuid, p_invoice_id uuid)
returns void language plpgsql security definer
set search_path = public set row_security = off
as $$
declare
    v_emitter uuid;
begin
    if not (public.can_bill() or public.is_admin()) then
        raise exception 'Permesso di fatturazione mancante' using errcode = '42501';
    end if;
    select i.emitter_id into v_emitter
      from public.invoices i where i.id = p_invoice_id;
    if v_emitter is null or not public.can_use_emitter(v_emitter) then
        raise exception 'Documento non accessibile' using errcode = '42501';
    end if;
    update public.travel_trips
       set invoice_id = p_invoice_id, collegata_at = now()
     where id = p_trip_id and (invoice_id is null or invoice_id = p_invoice_id);
    if not found then
        raise exception 'Trasferta inesistente o già inserita in un altro documento' using errcode = '23505';
    end if;
end; $$;

-- Scollega (es. la riga è stata tolta dal documento): consentito se il
-- documento è in bozza OPPURE è un preventivo NON archiviato (non fiscale,
-- in qualunque stato). Archiviato = già convertito in proforma/fattura
-- (convDoc), che ne ha copiato le righe: scollegarlo permetterebbe di
-- fatturare la trasferta due volte (il collegamento passa comunque al nuovo
-- documento, vedi travel_trip_move_invoice). Escluso anche un preventivo con
-- tranche già in proforma/fattura: l'importo è già dentro le tranche.
-- Fatture, proforma e note di credito emesse restano collegate per sempre.
create or replace function public.travel_trip_unlink_invoice(p_trip_id uuid)
returns void language plpgsql security definer
set search_path = public set row_security = off
as $$
declare
    v_invoice uuid;
    v_emitter uuid;
    v_stato   text;
    v_tipo    text;
    v_arch    boolean;
begin
    if not (public.can_bill() or public.is_admin()) then
        raise exception 'Permesso di fatturazione mancante' using errcode = '42501';
    end if;
    select t.invoice_id into v_invoice from public.travel_trips t where t.id = p_trip_id;
    if v_invoice is null then
        return;
    end if;
    select i.emitter_id, i.stato::text, i.tipo, i.archiviato into v_emitter, v_stato, v_tipo, v_arch
      from public.invoices i where i.id = v_invoice;
    if not public.can_use_emitter(v_emitter) then
        raise exception 'Documento non accessibile' using errcode = '42501';
    end if;
    if v_stato <> 'bozza' and not (
           v_tipo = 'preventivo' and not coalesce(v_arch, false)
           and not exists (select 1 from public.quote_tranches q
                           where q.preventivo_id = v_invoice and q.stato <> 'da_fatturare')
       ) then
        raise exception 'Il documento è già stato emesso: la trasferta non si può scollegare' using errcode = '22023';
    end if;
    update public.travel_trips set invoice_id = null, collegata_at = null where id = p_trip_id;
end; $$;

-- Conversione documento (convDoc nel gestionale: preventivo→proforma/fattura,
-- proforma→fattura): le righe vengono copiate nel nuovo documento, quindi le
-- trasferte collegate all'originale passano al nuovo. Chiamata dopo il
-- salvataggio riuscito del nuovo documento. Restituisce quante ne ha spostate.
create or replace function public.travel_trip_move_invoice(p_from_invoice_id uuid, p_to_invoice_id uuid)
returns integer language plpgsql security definer
set search_path = public set row_security = off
as $$
declare
    v_from uuid;
    v_to   uuid;
    v_n    integer;
begin
    if not (public.can_bill() or public.is_admin()) then
        raise exception 'Permesso di fatturazione mancante' using errcode = '42501';
    end if;
    select emitter_id into v_from from public.invoices where id = p_from_invoice_id;
    select emitter_id into v_to   from public.invoices where id = p_to_invoice_id;
    if v_from is null or v_to is null
       or not public.can_use_emitter(v_from) or not public.can_use_emitter(v_to) then
        raise exception 'Documento non accessibile' using errcode = '42501';
    end if;
    update public.travel_trips
       set invoice_id = p_to_invoice_id, collegata_at = now()
     where invoice_id = p_from_invoice_id;
    get diagnostics v_n = row_count;
    return v_n;
end; $$;


-- ----------------------------------------------------------------------------
-- 3. AUDIT (dati non sanitari: full, come persons)
-- ----------------------------------------------------------------------------
drop trigger if exists trg_audit_travel_profiles on public.travel_profiles;
create trigger trg_audit_travel_profiles after insert or update or delete on public.travel_profiles
    for each row execute function public.fn_audit_write('full');
drop trigger if exists trg_audit_travel_trips on public.travel_trips;
create trigger trg_audit_travel_trips after insert or update or delete on public.travel_trips
    for each row execute function public.fn_audit_write('full');
drop trigger if exists trg_audit_travel_trip_days on public.travel_trip_days;
create trigger trg_audit_travel_trip_days after insert or update or delete on public.travel_trip_days
    for each row execute function public.fn_audit_write('full');

-- ----------------------------------------------------------------------------
-- 4. POLICY RLS
-- ----------------------------------------------------------------------------
-- Schede: proprietario; l'admin le legge tutte. Nessun can_write(): anche il
-- consulente_limitato registra le proprie trasferte.
drop policy if exists travel_profiles_select on public.travel_profiles;
create policy travel_profiles_select on public.travel_profiles
    for select using ( owner_id = auth.uid() or public.is_admin() );
drop policy if exists travel_profiles_insert on public.travel_profiles;
create policy travel_profiles_insert on public.travel_profiles
    for insert with check ( owner_id = auth.uid() and public.travel_company_ok(company_id) );
drop policy if exists travel_profiles_update on public.travel_profiles;
create policy travel_profiles_update on public.travel_profiles
    for update using ( owner_id = auth.uid() )
    with check ( owner_id = auth.uid() and public.travel_company_ok(company_id) );
drop policy if exists travel_profiles_delete on public.travel_profiles;
create policy travel_profiles_delete on public.travel_profiles
    for delete using ( owner_id = auth.uid() );

-- Trasferte: lettura anche ad admin e fatturazione; scrittura solo al
-- proprietario e solo finché non è in un documento.
drop policy if exists travel_trips_select on public.travel_trips;
create policy travel_trips_select on public.travel_trips
    for select using ( owner_id = auth.uid() or public.is_admin() or public.can_bill() );
drop policy if exists travel_trips_insert on public.travel_trips;
create policy travel_trips_insert on public.travel_trips
    for insert with check ( owner_id = auth.uid() and invoice_id is null
                            and public.travel_company_ok(company_id) );
drop policy if exists travel_trips_update on public.travel_trips;
create policy travel_trips_update on public.travel_trips
    for update using ( owner_id = auth.uid() and invoice_id is null )
    with check ( owner_id = auth.uid() and invoice_id is null and public.travel_company_ok(company_id) );
drop policy if exists travel_trips_delete on public.travel_trips;
create policy travel_trips_delete on public.travel_trips
    for delete using ( owner_id = auth.uid() and invoice_id is null );

-- Giorni: lettura a chi vede la trasferta (la sottoquery passa dalla RLS di
-- travel_trips); scrittura solo se la trasferta è tua e non in un documento.
drop policy if exists travel_days_select on public.travel_trip_days;
create policy travel_days_select on public.travel_trip_days
    for select using ( exists (select 1 from public.travel_trips t where t.id = travel_trip_days.trip_id) );
drop policy if exists travel_days_write on public.travel_trip_days;
create policy travel_days_write on public.travel_trip_days
    for all using ( exists (select 1 from public.travel_trips t
                            where t.id = travel_trip_days.trip_id
                              and t.owner_id = auth.uid() and t.invoice_id is null) )
    with check ( exists (select 1 from public.travel_trips t
                         where t.id = travel_trip_days.trip_id
                           and t.owner_id = auth.uid() and t.invoice_id is null) );

-- ----------------------------------------------------------------------------
-- 5. GRANT espliciti (da 2026-10-30 Supabase non li concede più in automatico)
-- ----------------------------------------------------------------------------
grant select, insert, update, delete on public.travel_profiles, public.travel_trips, public.travel_trip_days to authenticated;

revoke execute on function public.travel_company_ok(uuid)                from public, anon;
revoke execute on function public.travel_trip_save(jsonb, jsonb)         from public, anon;
revoke execute on function public.travel_trip_link_invoice(uuid, uuid)   from public, anon;
revoke execute on function public.travel_trip_unlink_invoice(uuid)       from public, anon;
revoke execute on function public.travel_trip_move_invoice(uuid, uuid)   from public, anon;
grant  execute on function public.travel_company_ok(uuid)                to authenticated;
grant  execute on function public.travel_trip_save(jsonb, jsonb)         to authenticated;
grant  execute on function public.travel_trip_link_invoice(uuid, uuid)   to authenticated;
grant  execute on function public.travel_trip_unlink_invoice(uuid)       to authenticated;
grant  execute on function public.travel_trip_move_invoice(uuid, uuid)   to authenticated;
