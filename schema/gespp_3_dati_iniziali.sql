-- ============================================================================
--  SISTEMA GESPP — DATI INIZIALI  (file 3 di 3)
--  Da eseguire DOPO gespp_2_funzioni_policy.sql.
--  Popola il catalogo patologie. Ri-eseguibile (on conflict do nothing).
-- ============================================================================

insert into public.pathologies (denominazione) values
-- Cardiovascolari
('Ipertensione arteriosa'),
('Cardiopatia ischemica'),
('Aritmia cardiaca'),
('Scompenso cardiaco'),
('Trombosi venosa profonda'),
-- Metaboliche ed endocrine
('Diabete mellito tipo 1'),
('Diabete mellito tipo 2'),
('Ipotiroidismo'),
('Ipertiroidismo'),
('Obesità'),
('Dislipidemia'),
('Sindrome metabolica'),
('Iperuricemia / gotta'),
-- Respiratorie
('Asma bronchiale'),
('Broncopneumopatia cronica ostruttiva (BPCO)'),
('Rinite allergica'),
('Apnee notturne'),
-- Gastrointestinali
('Reflusso gastroesofageo'),
('Gastrite'),
('Ulcera peptica'),
('Sindrome dell''intestino irritabile'),
('Morbo di Crohn'),
('Colite ulcerosa'),
('Celiachia'),
('Calcolosi biliare'),
-- Muscolo-scheletriche
('Artrosi'),
('Artrite reumatoide'),
('Osteoporosi'),
('Lombalgia cronica'),
('Cervicalgia'),
('Fibromialgia'),
('Ernia del disco'),
-- Neurologiche
('Emicrania'),
('Cefalea tensiva'),
('Epilessia'),
('Sclerosi multipla'),
('Morbo di Parkinson'),
('Neuropatia periferica'),
-- Psicologiche / psichiatriche
('Disturbo d''ansia'),
('Disturbo depressivo'),
('Disturbo del sonno / insonnia'),
('Disturbo da attacchi di panico'),
('Disturbo ossessivo-compulsivo'),
('Disturbo da stress post-traumatico'),
('Burnout'),
('Disturbo del comportamento alimentare'),
-- Dermatologiche
('Dermatite atopica'),
('Psoriasi'),
('Orticaria cronica'),
('Acne'),
-- Urogenitali / renali
('Insufficienza renale cronica'),
('Calcolosi renale'),
('Infezioni ricorrenti delle vie urinarie'),
('Endometriosi'),
('Sindrome dell''ovaio policistico'),
-- Sensoriali
('Ipoacusia'),
('Acufeni'),
('Disturbi della vista (miopia/ipermetropia/astigmatismo)'),
-- Allergologiche / immunitarie
('Allergia alimentare'),
('Allergia a farmaci'),
('Allergia agli acari / polveri'),
-- Oncologiche (generico)
('Patologia oncologica (in trattamento o follow-up)'),
-- Altre comuni
('Anemia'),
('Disfunzione tiroidea (non specificata)'),
('Sindrome del tunnel carpale'),
('Vertigini / disturbi dell''equilibrio')
on conflict (denominazione) do nothing;

-- ----------------------------------------------------------------------------
-- Riga singola di configurazione del consenso, migrata dal placeholder che
-- era hardcoded in edge_consenso.ts. informativa_pdf_url/consenso_pdf_url
-- restano null finche' non viene caricato un PDF vero dalla schermata
-- admin "Consenso sanitario" — fino ad allora la pagina di firma mostra
-- "informativa non ancora disponibile", MAI la vecchia bozza intesa come
-- testo definitivo.
-- ----------------------------------------------------------------------------
insert into public.consent_config (id, versione, punti) values (
    1,
    'v1.0-bozza',
    '[
        {"chiave":"informativa","etichetta":"Ho letto e compreso l''informativa."},
        {"chiave":"trattamento","etichetta":"Acconsento al trattamento dei miei dati relativi alla salute."},
        {"chiave":"revoca","etichetta":"So di poter revocare il consenso in qualsiasi momento, senza conseguenze."}
    ]'::jsonb
) on conflict (id) do nothing;
