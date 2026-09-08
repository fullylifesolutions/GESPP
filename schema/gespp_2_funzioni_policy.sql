-- ============================================================================
--  SISTEMA GESPP — FUNZIONI, POLICY, TRIGGER  (file 2 di 3)
--  Da eseguire DOPO gespp_1_schema.sql.
--
--  Contiene, nelle versioni FINALI e corrette:
--   - funzioni di ruolo (my_role con row_security=off, is_admin, ...)
--   - funzioni applicative (write_audit, get_health_records, get_self_reports,
--     merge_pathology, hard_delete_health_data, consenso_leggi, consenso_firma,
--     spp_patologia_dettaglio)
--   - funzione + trigger di audit
--   - tutte le policy RLS
--   - la vista statistica
-- ============================================================================

-- ============================================================================
--  1. FUNZIONI DI RUOLO
-- ============================================================================
create or replace function public.my_role()
returns user_role language plpgsql stable security definer
set search_path = public set row_security = off
as $$
declare r user_role;
begin
    select ruolo into r from public.app_users where id = auth.uid();
    return r;
end; $$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select public.my_role() = 'admin'; $$;

create or replace function public.current_role()
returns user_role language sql stable security definer set search_path = public
as $$ select public.my_role(); $$;

create or replace function public.can_write()
returns boolean language sql stable security definer set search_path = public
as $$ select public.my_role() in ('admin','consulente'); $$;

create or replace function public.can_access_person(p_person_id uuid)
returns boolean language sql stable security definer set search_path = public set row_security = off
as $$
    select
        public.is_admin()
        or exists (
            select 1 from public.persons p
            join public.consultant_company cc on cc.company_id = p.company_id
            where p.id = p_person_id and cc.consultant_id = auth.uid()
        )
        or exists (
            select 1 from public.consultant_person cp
            where cp.person_id = p_person_id and cp.consultant_id = auth.uid()
        );
$$;

create or replace function public.has_active_health_consent(p_person_id uuid)
returns boolean language sql stable security definer set search_path = public set row_security = off
as $$
    select exists (
        select 1 from public.health_consents
        where person_id = p_person_id and stato = 'attivo'
    );
$$;

-- ============================================================================
--  2. AUDIT: funzione di scrittura + funzione trigger
-- ============================================================================
create or replace function public.write_audit(
    p_azione text, p_tabella text, p_record_id uuid, p_dettaglio jsonb
) returns void language plpgsql security definer set search_path = public set row_security = off
as $$
begin
    insert into public.audit_log (user_id, azione, tabella, record_id, dettaglio)
    values (auth.uid(), p_azione, p_tabella, p_record_id, p_dettaglio);
end; $$;

create or replace function public.fn_audit_write()
returns trigger language plpgsql security definer set search_path = public set row_security = off
as $$
declare
    v_mode      text := coalesce(TG_ARGV[0], 'full');
    v_azione    text := lower(TG_OP);
    v_record_id uuid;
    v_dettaglio jsonb;
    v_changed   text[];
    v_key       text;
begin
    if TG_OP = 'DELETE' then v_record_id := OLD.id; else v_record_id := NEW.id; end if;

    if v_mode = 'sensitive' then
        if TG_OP = 'UPDATE' then
            v_changed := array[]::text[];
            for v_key in select jsonb_object_keys(to_jsonb(NEW)) loop
                if to_jsonb(NEW) -> v_key is distinct from to_jsonb(OLD) -> v_key then
                    v_changed := array_append(v_changed, v_key);
                end if;
            end loop;
            v_dettaglio := jsonb_build_object('campi_modificati', v_changed);
        else
            v_dettaglio := jsonb_build_object('nota','operazione su dato sanitario');
        end if;
    else
        if TG_OP = 'INSERT' then v_dettaglio := jsonb_build_object('new', to_jsonb(NEW));
        elsif TG_OP = 'UPDATE' then v_dettaglio := jsonb_build_object('old', to_jsonb(OLD), 'new', to_jsonb(NEW));
        else v_dettaglio := jsonb_build_object('old', to_jsonb(OLD)); end if;
    end if;

    insert into public.audit_log (user_id, azione, tabella, record_id, dettaglio)
    values (auth.uid(), v_azione, TG_TABLE_NAME, v_record_id, v_dettaglio);

    if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
end; $$;

-- ============================================================================
--  3. TRIGGER DI AUDIT (ora che fn_audit_write esiste)
-- ============================================================================
create trigger trg_audit_persons  after insert or update or delete on public.persons
    for each row execute function public.fn_audit_write('full');
create trigger trg_audit_spp      after insert or update or delete on public.spp_profiles
    for each row execute function public.fn_audit_write('full');
create trigger trg_audit_consents after insert or update or delete on public.health_consents
    for each row execute function public.fn_audit_write('sensitive');
create trigger trg_audit_health   after insert or update or delete on public.health_records
    for each row execute function public.fn_audit_write('sensitive');
create trigger trg_audit_selfrep  after insert or update or delete on public.self_reports
    for each row execute function public.fn_audit_write('sensitive');
create trigger trg_audit_meetings after insert or update or delete on public.meetings
    for each row execute function public.fn_audit_write('full');

-- trigger storico passaggi azienda
create or replace function public.fn_track_company()
returns trigger language plpgsql security definer set search_path = public set row_security = off
as $$
begin
    if TG_OP = 'INSERT' and NEW.company_id is not null then
        insert into public.person_company_history (person_id, company_id) values (NEW.id, NEW.company_id);
    elsif TG_OP = 'UPDATE' and NEW.company_id is distinct from OLD.company_id then
        update public.person_company_history set data_fine = now()
            where person_id = NEW.id and data_fine is null;
        if NEW.company_id is not null then
            insert into public.person_company_history (person_id, company_id) values (NEW.id, NEW.company_id);
        end if;
    end if;
    return NEW;
end; $$;

create trigger trg_track_company after insert or update on public.persons
    for each row execute function public.fn_track_company();

-- ============================================================================
--  4. FUNZIONI APPLICATIVE (lettura tracciata, manutenzione, consenso)
-- ============================================================================
create or replace function public.get_health_records(p_person_id uuid)
returns setof public.health_records language plpgsql security invoker set search_path = public
as $$
begin
    perform public.write_audit('view','health_records',p_person_id,
        jsonb_build_object('nota','lettura dati sanitari della persona'));
    return query select * from public.health_records
        where person_id = p_person_id and archiviato = false;
end; $$;

create or replace function public.get_self_reports(p_person_id uuid)
returns setof public.self_reports language plpgsql security invoker set search_path = public
as $$
begin
    perform public.write_audit('view','self_reports',p_person_id,
        jsonb_build_object('nota','lettura self-report della persona'));
    return query select * from public.self_reports
        where person_id = p_person_id and archiviato = false order by data_nota desc;
end; $$;

create or replace function public.merge_pathology(p_source uuid, p_target uuid)
returns integer language plpgsql security definer set search_path = public set row_security = off
as $$
declare v_count integer; v_src text; v_dst text;
begin
    if not public.is_admin() then raise exception 'Operazione riservata agli amministratori.'; end if;
    if p_source = p_target then raise exception 'Sorgente e destinazione coincidono.'; end if;
    select denominazione into v_src from public.pathologies where id = p_source;
    select denominazione into v_dst from public.pathologies where id = p_target;
    if v_src is null or v_dst is null then raise exception 'Patologia inesistente.'; end if;
    select count(*) into v_count from public.health_records where pathology_id = p_source;
    update public.health_records set pathology_id = p_target where pathology_id = p_source;
    update public.pathologies set attiva = false where id = p_source;
    perform public.write_audit('merge','pathologies',p_source,
        jsonb_build_object('da',v_src,'a',v_dst,'record_spostati',v_count));
    return v_count;
end; $$;

create or replace function public.hard_delete_health_data(p_person_id uuid)
returns integer language plpgsql security definer set search_path = public set row_security = off
as $$
declare v_count integer;
begin
    if not public.is_admin() then raise exception 'Operazione riservata agli amministratori (diritto all''oblio).'; end if;
    select count(*) into v_count from public.health_records where person_id = p_person_id;
    perform public.write_audit('hard_delete','health_records',p_person_id,
        jsonb_build_object('nota','cancellazione definitiva dati sanitari (diritto all''oblio)','record_cancellati',v_count));
    delete from public.self_reports   where person_id = p_person_id;
    delete from public.health_records where person_id = p_person_id;
    return v_count;
end; $$;

-- Configurazione del consenso (informativa/consenso PDF + checkbox), letta
-- dalla Edge Function "consenso" tramite RPC invece che con una select
-- diretta su consent_config: stesso motivo di consenso_leggi/consenso_firma
-- sotto — gira con i privilegi di chi l'ha creata, non serve dare grant
-- specifici al ruolo con cui gira la Edge Function.
create or replace function public.consent_config_leggi()
returns table (versione text, informativa_pdf_url text, consenso_pdf_url text, punti jsonb)
language sql security definer set search_path = public set row_security = off
as $$
    select versione, informativa_pdf_url, consenso_pdf_url, punti
    from public.consent_config where id = 1;
$$;
grant execute on function public.consent_config_leggi() to anon, authenticated;

create or replace function public.consenso_leggi(p_token text)
returns table (person_id uuid, nome text, cognome text)
language plpgsql security definer set search_path = public set row_security = off
as $$
begin
    return query
    select c.person_id, p.nome, p.cognome
    from public.health_consents c
    join public.persons p on p.id = c.person_id
    where c.token = p_token and c.token_usato = false and c.stato = 'in_attesa'
      and (c.token_scadenza is null or c.token_scadenza > now());
end; $$;

create or replace function public.consenso_firma(
    p_token text, p_spunte jsonb, p_firma text, p_canale text, p_versione text
) returns text language plpgsql security definer set search_path = public set row_security = off
as $$
declare v_id uuid; v_person uuid; v_nome text;
begin
    select c.id, c.person_id, p.nome || ' ' || p.cognome
    into v_id, v_person, v_nome
    from public.health_consents c
    join public.persons p on p.id = c.person_id
    where c.token = p_token and c.token_usato = false and c.stato = 'in_attesa'
      and (c.token_scadenza is null or c.token_scadenza > now());
    if v_id is null then raise exception 'TOKEN_NON_VALIDO'; end if;
    update public.health_consents
    set stato='attivo', data_consenso=now(), testo_versione=coalesce(p_versione,testo_versione),
        spunte_accettate=p_spunte, firma_dati=p_firma,
        canale=case when p_canale='presenza' then 'presenza' else 'remoto' end, token_usato=true
    where id = v_id;
    perform public.write_audit('consent_signed','health_consents',v_person,
        jsonb_build_object('nota','consenso firmato digitalmente','canale',p_canale));
    return v_nome;
end; $$;

create or replace function public.spp_patologia_dettaglio(
    p_patologia text default null, p_sessualita text default null, p_lateralita text default null,
    p_bisogni text default null, p_foglietto text default null, p_intensita text default null,
    p_reciprocita reciprocita_t default null
) returns table (
    persona text, azienda text, patologia text, sessualita text, lateralita text,
    bisogni text, foglietto text, intensita text, reciprocita reciprocita_t,
    n_incontri bigint, ultimo_incontro timestamptz
) language plpgsql security definer set search_path = public
as $$
begin
    if not public.is_admin() then raise exception 'Accesso negato: riservato agli amministratori.'; end if;
    perform public.write_audit('view','spp_patologia_dettaglio',null,
        jsonb_build_object('nota','analisi nominativa SPP-patologia','filtro_patologia',p_patologia));
    return query
    with ultima_spp as (
        select distinct on (person_id) person_id, asse1_sessualita, asse2_lateralita, asse3_bisogni,
            asse4_foglietto, asse5_intensita, asse6_reciprocita
        from public.spp_profiles order by person_id, data_rilevazione desc
    )
    select p.nome||' '||p.cognome, c.ragione_sociale, pat.denominazione,
        s.asse1_sessualita, s.asse2_lateralita, s.asse3_bisogni, s.asse4_foglietto, s.asse5_intensita, s.asse6_reciprocita,
        (select count(*) from public.meetings m where m.person_id = p.id),
        (select max(m.data_ora) from public.meetings m where m.person_id = p.id)
    from public.health_records hr
    join public.pathologies pat on pat.id = hr.pathology_id
    join public.persons p on p.id = hr.person_id
    left join public.companies c on c.id = p.company_id
    join ultima_spp s on s.person_id = hr.person_id
    where (p_patologia is null or pat.denominazione = p_patologia)
      and (p_sessualita is null or s.asse1_sessualita = p_sessualita)
      and (p_lateralita is null or s.asse2_lateralita = p_lateralita)
      and (p_bisogni is null or s.asse3_bisogni = p_bisogni)
      and (p_foglietto is null or s.asse4_foglietto = p_foglietto)
      and (p_intensita is null or s.asse5_intensita = p_intensita)
      and (p_reciprocita is null or s.asse6_reciprocita = p_reciprocita);
end; $$;

-- GRANT sulle funzioni
grant execute on function public.write_audit(text,text,uuid,jsonb) to authenticated;
grant execute on function public.get_health_records(uuid) to authenticated;
grant execute on function public.get_self_reports(uuid) to authenticated;
grant execute on function public.merge_pathology(uuid,uuid) to authenticated;
grant execute on function public.hard_delete_health_data(uuid) to authenticated;
grant execute on function public.consenso_leggi(text) to anon, authenticated;
grant execute on function public.consenso_firma(text,jsonb,text,text,text) to anon, authenticated;
grant execute on function public.spp_patologia_dettaglio to authenticated;

-- ============================================================================
--  5. VISTA STATISTICA (senza categoria)
--
--  Decisione (2026-09-08): conteggi pieni, nessuna soppressione — chi accede
--  ha comunque diritto ai dati individuali. La protezione è la restrizione
--  d'accesso, su due livelli indipendenti:
--    - security_invoker = true: la vista rispetta la RLS di health_records/
--      spp_profiles invece di girare con i privilegi dell'owner (postgres),
--      che altrimenti bypassano la RLS come qualunque owner/superuser — è il
--      backstop strutturale, non negoziabile.
--    - where public.is_admin(): restringe ulteriormente la funzionalità
--      statistiche al solo ruolo amministratore (più stretto di quanto la
--      sola RLS garantirebbe: un consulente non limitato con legami
--      legittimi vedrebbe altrimenti un aggregato parziale sul suo
--      sottoinsieme, non zero).
--  Verificato sul DB reale il 2026-09-08: prima di questa versione la vista
--  (insieme alla gemella orfana v_pathology_stats, mai referenziata dal
--  frontend e rimossa) aveva reloptions null (nessun security_invoker) ed
--  era leggibile da qualunque utente 'authenticated', aggregato completo
--  incluso il breakdown per assi SPP — corretto qui.
-- ============================================================================
create or replace view public.v_spp_patologia_agg
with (security_invoker = true) as
with ultima_spp as (
    select distinct on (person_id) person_id, asse1_sessualita, asse2_lateralita, asse3_bisogni,
        asse4_foglietto, asse5_intensita, asse6_reciprocita
    from public.spp_profiles order by person_id, data_rilevazione desc
)
select pat.denominazione,
    s.asse1_sessualita, s.asse2_lateralita, s.asse3_bisogni, s.asse4_foglietto, s.asse5_intensita, s.asse6_reciprocita,
    count(*) as numero_casi
from public.health_records hr
join public.pathologies pat on pat.id = hr.pathology_id
join ultima_spp s on s.person_id = hr.person_id
where public.is_admin()
group by pat.denominazione, s.asse1_sessualita, s.asse2_lateralita, s.asse3_bisogni,
    s.asse4_foglietto, s.asse5_intensita, s.asse6_reciprocita;

-- ============================================================================
--  6. POLICY RLS
-- ============================================================================
-- app_users
create policy app_users_read on public.app_users
    for select using ( id = auth.uid() or public.my_role() = 'admin' );
create policy app_users_write on public.app_users
    for all using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- companies
create policy companies_read on public.companies
    for select using ( public.is_admin() or exists (
        select 1 from public.consultant_company cc where cc.company_id = companies.id and cc.consultant_id = auth.uid()) );
create policy companies_admin_write on public.companies
    for all using (public.is_admin()) with check (public.is_admin());

-- company_sites
create policy sites_read on public.company_sites
    for select using ( public.is_admin() or exists (
        select 1 from public.consultant_company cc where cc.company_id = company_sites.company_id and cc.consultant_id = auth.uid()) );
create policy sites_write on public.company_sites
    for all using (public.can_write() and ( public.is_admin() or exists (
        select 1 from public.consultant_company cc where cc.company_id = company_sites.company_id and cc.consultant_id = auth.uid()) ))
    with check (public.can_write() and ( public.is_admin() or exists (
        select 1 from public.consultant_company cc where cc.company_id = company_sites.company_id and cc.consultant_id = auth.uid()) ));

-- company_contacts
create policy contacts_read on public.company_contacts
    for select using ( public.is_admin() or exists (
        select 1 from public.consultant_company cc where cc.company_id = company_contacts.company_id and cc.consultant_id = auth.uid()) );
create policy contacts_write on public.company_contacts
    for all using (public.can_write() and ( public.is_admin() or exists (
        select 1 from public.consultant_company cc where cc.company_id = company_contacts.company_id and cc.consultant_id = auth.uid()) ))
    with check (public.can_write() and ( public.is_admin() or exists (
        select 1 from public.consultant_company cc where cc.company_id = company_contacts.company_id and cc.consultant_id = auth.uid()) ));

-- persons
create policy persons_read on public.persons
    for select using (public.can_access_person(id));
create policy persons_insert on public.persons
    for insert with check (
        public.is_admin() or (
            public.can_write() and tipo = 'dipendente' and company_id is not null
            and exists (select 1 from public.consultant_company cc
                where cc.company_id = persons.company_id and cc.consultant_id = auth.uid())
        ));
create policy persons_update on public.persons
    for update using ( public.is_admin() or (public.can_write() and public.can_access_person(id)) )
    with check ( public.is_admin() or (public.can_write() and public.can_access_person(id)) );
create policy persons_delete on public.persons
    for delete using ( public.is_admin() or (public.can_write() and public.can_access_person(id)) );

-- assegnazioni
create policy cc_read on public.consultant_company
    for select using (consultant_id = auth.uid() or public.is_admin());
create policy cc_admin_write on public.consultant_company
    for all using (public.is_admin()) with check (public.is_admin());
create policy cp_read on public.consultant_person
    for select using (consultant_id = auth.uid() or public.is_admin());
create policy cp_admin_write on public.consultant_person
    for all using (public.is_admin()) with check (public.is_admin());

-- spp_profiles
create policy spp_read on public.spp_profiles
    for select using (public.can_access_person(person_id));
create policy spp_insert on public.spp_profiles
    for insert with check (public.can_write() and public.can_access_person(person_id));
create policy spp_update on public.spp_profiles
    for update using (public.can_write() and public.can_access_person(person_id))
    with check (public.can_write() and public.can_access_person(person_id));
create policy spp_delete on public.spp_profiles
    for delete using (public.can_write() and public.can_access_person(person_id));

-- pathologies
create policy pathologies_read on public.pathologies
    for select using (auth.role() = 'authenticated');
create policy pathologies_insert on public.pathologies
    for insert with check (public.can_write());
create policy pathologies_admin_modify on public.pathologies
    for update using (public.is_admin()) with check (public.is_admin());
create policy pathologies_admin_delete on public.pathologies
    for delete using (public.is_admin());

-- health_consents
create policy consents_access on public.health_consents
    for select using ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato' );
create policy consents_write on public.health_consents
    for all using ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato' )
    with check ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato' );

-- health_records
create policy health_access on public.health_records
    for select using ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato'
        and public.has_active_health_consent(person_id) );
create policy health_write on public.health_records
    for all using ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato'
        and public.has_active_health_consent(person_id) )
    with check ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato'
        and public.has_active_health_consent(person_id) );

-- self_reports
create policy selfrep_access on public.self_reports
    for select using ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato'
        and public.has_active_health_consent(person_id) );
create policy selfrep_write on public.self_reports
    for all using ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato'
        and public.has_active_health_consent(person_id) )
    with check ( public.can_access_person(person_id) and public.current_role() <> 'consulente_limitato'
        and public.has_active_health_consent(person_id) );

-- meetings
create policy meetings_read on public.meetings
    for select using (public.can_access_person(person_id));
create policy meetings_insert on public.meetings
    for insert with check (public.can_write() and public.can_access_person(person_id));
create policy meetings_update on public.meetings
    for update using (public.can_write() and public.can_access_person(person_id))
    with check (public.can_write() and public.can_access_person(person_id));
create policy meetings_delete on public.meetings
    for delete using (public.can_write() and public.can_access_person(person_id));

-- person_company_history
create policy pch_read on public.person_company_history
    for select using (public.can_access_person(person_id));
create policy pch_write on public.person_company_history
    for all using (public.can_write() and public.can_access_person(person_id))
    with check (public.can_write() and public.can_access_person(person_id));

-- audit_log
create policy audit_admin_read on public.audit_log
    for select using (public.is_admin());

-- consent_config: letta da qualunque utente loggato (contenuto non
-- sensibile, serve alla schermata di gestione), scritta solo da admin —
-- e' un contenuto legale valido per l'intero sistema, stesso criterio gia'
-- usato per gli emittenti fiscali nel gestionale. "to authenticated"
-- esplicito su entrambe: senza, si applicherebbero anche ad anon, che non
-- deve toccare questa tabella (la Edge Function la legge con la service
-- role, bypassando comunque la RLS).
create policy consent_config_read on public.consent_config
    for select to authenticated using (true);
create policy consent_config_write on public.consent_config
    for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- storage.objects per il bucket "consensi": lettura pubblica (anche
-- anonima, consenso_pagina.html non ha login), scrittura/sostituzione/
-- cancellazione solo admin.
create policy consensi_public_read on storage.objects
    for select to anon, authenticated using (bucket_id = 'consensi');
create policy consensi_admin_insert on storage.objects
    for insert to authenticated with check (bucket_id = 'consensi' and public.is_admin());
create policy consensi_admin_update on storage.objects
    for update to authenticated using (bucket_id = 'consensi' and public.is_admin())
    with check (bucket_id = 'consensi' and public.is_admin());
create policy consensi_admin_delete on storage.objects
    for delete to authenticated using (bucket_id = 'consensi' and public.is_admin());

-- ----------------------------------------------------------------------------
-- WORK CALENDAR — funzione e policy (tabelle wc_* nel file 1).
-- Chi fa parte del "team" di un task: il proprietario, chi e' taggato sul
-- task, chi e' taggato su uno dei suoi subtask. security definer perche'
-- valutata dentro le policy di piu' tabelle diverse (stesso motivo di
-- can_access_person sopra: evita di dover dare grant incrociati fra le
-- tabelle wc_* solo per farle leggere l'un l'altra durante la valutazione
-- della RLS).
-- ----------------------------------------------------------------------------
create or replace function public.wc_can_see_task(p_task_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
    select exists(
        select 1 from public.wc_tasks t
        where t.id = p_task_id
          and (
            t.owner_id = auth.uid()
            or public.is_admin()
            or exists(select 1 from public.wc_task_operators o where o.task_id = t.id and o.operator_id = auth.uid())
            or exists(
                select 1 from public.wc_subtasks s
                join public.wc_subtask_operators so on so.subtask_id = s.id
                where s.task_id = t.id and so.operator_id = auth.uid()
            )
          )
    );
$$;
grant execute on function public.wc_can_see_task(uuid) to authenticated;

-- categorie/backlog: solo il proprietario, calendario privato.
create policy wc_categories_owner on public.wc_categories
    for all to authenticated using (owner_id = auth.uid() or public.is_admin())
    with check (owner_id = auth.uid() or public.is_admin());
create policy wc_backlog_owner on public.wc_backlog
    for all to authenticated using (owner_id = auth.uid() or public.is_admin())
    with check (owner_id = auth.uid() or public.is_admin());

-- Il team di un task deve poter leggere nome/colore delle categorie usate
-- da quel task — non l'intero elenco categorie del proprietario, solo
-- quelle effettivamente referenziate da un task che puo' vedere. Sola
-- lettura: nessuna policy di scrittura aggiuntiva, resta owner-only.
create policy wc_categories_team_read on public.wc_categories
    for select to authenticated using (
        exists(select 1 from public.wc_tasks t where t.categoria_id = wc_categories.id and public.wc_can_see_task(t.id))
    );

-- task: il proprietario ha pieno controllo; il team lo vede soltanto —
-- nessuna policy di update/delete per i taggati sulla riga task stessa,
-- la struttura resta del proprietario.
create policy wc_tasks_owner_all on public.wc_tasks
    for all to authenticated using (owner_id = auth.uid() or public.is_admin())
    with check (owner_id = auth.uid() or public.is_admin());
create policy wc_tasks_team_read on public.wc_tasks
    for select to authenticated using (public.wc_can_see_task(id));

-- taggature: il proprietario del task le gestisce; il team vede chi altro
-- e' taggato (utile per sapere con chi si sta collaborando).
create policy wc_task_operators_owner_write on public.wc_task_operators
    for all to authenticated using (
        exists(select 1 from public.wc_tasks t where t.id = task_id and (t.owner_id = auth.uid() or public.is_admin()))
    ) with check (
        exists(select 1 from public.wc_tasks t where t.id = task_id and (t.owner_id = auth.uid() or public.is_admin()))
    );
create policy wc_task_operators_team_read on public.wc_task_operators
    for select to authenticated using (public.wc_can_see_task(task_id));

-- subtask: il proprietario del task ha pieno controllo (struttura,
-- creazione, cancellazione). Il team lo vede in lettura. Lo stato invece
-- lo puo' cambiare solo chi e' taggato su QUEL subtask specifico (non
-- tutto il team del task) — coerente con "aggiornamenti sulla propria
-- parte".
create policy wc_subtasks_owner_all on public.wc_subtasks
    for all to authenticated using (
        exists(select 1 from public.wc_tasks t where t.id = task_id and (t.owner_id = auth.uid() or public.is_admin()))
    ) with check (
        exists(select 1 from public.wc_tasks t where t.id = task_id and (t.owner_id = auth.uid() or public.is_admin()))
    );
create policy wc_subtasks_team_read on public.wc_subtasks
    for select to authenticated using (public.wc_can_see_task(task_id));
create policy wc_subtasks_assigned_update on public.wc_subtasks
    for update to authenticated using (
        exists(select 1 from public.wc_subtask_operators so where so.subtask_id = id and so.operator_id = auth.uid())
    ) with check (
        exists(select 1 from public.wc_subtask_operators so where so.subtask_id = id and so.operator_id = auth.uid())
    );

create policy wc_subtask_operators_owner_write on public.wc_subtask_operators
    for all to authenticated using (
        exists(select 1 from public.wc_subtasks s join public.wc_tasks t on t.id = s.task_id
               where s.id = subtask_id and (t.owner_id = auth.uid() or public.is_admin()))
    ) with check (
        exists(select 1 from public.wc_subtasks s join public.wc_tasks t on t.id = s.task_id
               where s.id = subtask_id and (t.owner_id = auth.uid() or public.is_admin()))
    );
create policy wc_subtask_operators_team_read on public.wc_subtask_operators
    for select to authenticated using (
        exists(select 1 from public.wc_subtasks s where s.id = subtask_id and public.wc_can_see_task(s.task_id))
    );

-- aggiornamenti: tutto il team del task legge e scrive (sempre a nome
-- proprio — mai a nome di qualcun altro); solo l'autore (o l'admin) elimina.
create policy wc_task_updates_team_read on public.wc_task_updates
    for select to authenticated using (public.wc_can_see_task(task_id));
create policy wc_task_updates_team_insert on public.wc_task_updates
    for insert to authenticated with check (author_id = auth.uid() and public.wc_can_see_task(task_id));
create policy wc_task_updates_author_delete on public.wc_task_updates
    for delete to authenticated using (author_id = auth.uid() or public.is_admin());

grant select, insert, update, delete on
    public.wc_categories, public.wc_backlog, public.wc_tasks, public.wc_task_operators,
    public.wc_subtasks, public.wc_subtask_operators, public.wc_task_updates
    to authenticated;

-- ============================================================================
--  FINE FILE 2. Procedere con gespp_3_dati_iniziali.sql
-- ============================================================================
