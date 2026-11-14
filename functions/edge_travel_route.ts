// ============================================================================
//  GESPP — EDGE FUNCTION "travel-route"
//  Da partenza e destinazione (comune o indirizzo, testo libero) restituisce
//  i km di sola andata, la durata e i caselli autostradali del percorso, via
//  HERE (Geocoding & Search v7 + Routing v8).
//
//  Il PEDAGGIO in euro NON viene restituito di proposito: confrontato con
//  Moveo (2026-11-14) HERE sovrastima sempre, con scarti non regolari
//  (+9%, +15%, +40% su tre tratte) — inutilizzabile in una nota spese che
//  finisce in fattura. Si restituisce solo se il percorso ha pedaggi e da
//  quali caselli, l'importo lo inserisce l'utente.
//
//  Caselli: HERE dà il nome del COMUNE del punto di pedaggio ("Pero"), non
//  quello del casello che serve su Moveo ("Barriera Milano Ghisolfa"): il
//  nome si ricava cercando il casello vero accanto al punto (nomeCasello).
//  Percorso calcolato senza traffico (departureTime=any), così è stabile.
//
//  Accesso: solo utenti GESPP autenticati e attivi. verify_jwt da solo NON
//  basta: la anon key (pubblica nell'HTML) è anch'essa un JWT valido, quindi
//  si verifica l'utente con auth.getUser() e il profilo app_users.attivo —
//  altrimenti chiunque potrebbe consumare la quota HERE.
//
//  Secret (mai nel codice): HERE_API_KEY. SUPABASE_URL e SUPABASE_ANON_KEY
//  sono iniettate automaticamente da Supabase.
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Luogo = { lat: number; lng: number; label: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ errore: "Metodo non consentito." }, 405);

  // ── utente autenticato e attivo ──
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return json({ errore: "Accesso non autorizzato." }, 401);
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData?.user) return json({ errore: "Accesso non autorizzato." }, 401);
  const { data: profilo } = await supabase.from("app_users").select("attivo").eq("id", userData.user.id).maybeSingle();
  if (!profilo?.attivo) return json({ errore: "Accesso non autorizzato." }, 403);

  // ── parametri ──
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ errore: "Richiesta non valida." }, 400);
  }
  const partenza = typeof body.partenza === "string" ? body.partenza.trim() : "";
  const destinazione = typeof body.destinazione === "string" ? body.destinazione.trim() : "";
  if (partenza.length < 2 || partenza.length > 200 || destinazione.length < 2 || destinazione.length > 200) {
    return json({ errore: "Indica partenza e destinazione (da 2 a 200 caratteri)." }, 400);
  }

  const apiKey = Deno.env.get("HERE_API_KEY");
  if (!apiKey) {
    console.error("travel-route: secret HERE_API_KEY mancante");
    return json({ errore: "Servizio percorsi non configurato." }, 500);
  }

  try {
    const [da, a] = await Promise.all([geocode(partenza, apiKey), geocode(destinazione, apiKey)]);
    if (!da) return json({ errore: `Partenza non trovata: "${partenza}". Prova ad aggiungere la provincia.` }, 404);
    if (!a) return json({ errore: `Destinazione non trovata: "${destinazione}". Prova ad aggiungere la provincia.` }, 404);

    const percorso = await route(da, a, apiKey);
    if (!percorso) return json({ errore: "Nessun percorso stradale trovato tra i due luoghi." }, 404);

    return json({
      ok: true,
      partenza: da.label,
      destinazione: a.label,
      km_andata: Math.round(percorso.metri / 100) / 10, // 1 decimale
      durata_min: Math.round(percorso.secondi / 60),
      pedaggio: percorso.caselli.length > 0,
      caselli: percorso.caselli,
    }, 200);
  } catch (e) {
    console.error("travel-route: errore HERE:", (e as Error)?.message ?? e);
    return json({ errore: "Servizio percorsi momentaneamente non disponibile." }, 502);
  }
});

async function geocode(q: string, apiKey: string): Promise<Luogo | null> {
  const url = new URL("https://geocode.search.hereapi.com/v1/geocode");
  url.searchParams.set("q", q);
  url.searchParams.set("in", "countryCode:ITA");
  url.searchParams.set("lang", "it-IT");
  url.searchParams.set("limit", "1");
  url.searchParams.set("apiKey", apiKey);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`geocode ${res.status}: ${await res.text()}`);
  const d = await res.json();
  const it = d?.items?.[0];
  if (!it?.position) return null;
  return { lat: it.position.lat, lng: it.position.lng, label: it.title ?? q };
}

async function route(da: Luogo, a: Luogo, apiKey: string) {
  const url = new URL("https://router.hereapi.com/v8/routes");
  url.searchParams.set("transportMode", "car");
  url.searchParams.set("origin", `${da.lat},${da.lng}`);
  url.searchParams.set("destination", `${a.lat},${a.lng}`);
  url.searchParams.set("return", "summary,tolls");
  url.searchParams.set("currency", "EUR");
  // percorso SENZA traffico in tempo reale: con il traffico la strada cambia da
  // una richiesta all'altra (visto su Monza → Busto Garolfo: A4 o A8 a seconda
  // dell'ora), mentre una scheda cliente deve descrivere il percorso abituale
  url.searchParams.set("departureTime", "any");
  url.searchParams.set("apiKey", apiKey);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`routes ${res.status}: ${await res.text()}`);
  const d = await res.json();
  const r = d?.routes?.[0];
  if (!r) return null;

  let metri = 0, secondi = 0;
  type Punto = { comune: string; lat: number; lng: number };
  const tratte: Punto[][] = [];
  for (const s of r.sections ?? []) {
    metri += s.summary?.length ?? 0;
    secondi += s.summary?.duration ?? 0;
    for (const t of s.tolls ?? []) {
      const punti: Punto[] = (t.tollCollectionLocations ?? [])
        .filter((l: { location?: unknown }) => l.location)
        .map((l: { name?: string; location: { lat: number; lng: number } }) => ({
          // "Melegnano (Rural)" → "Melegnano": il suffisso è un tag interno di HERE
          comune: (l.name ?? "").replace(/\s*\((Rural|Urban)\)\s*$/i, "").trim(),
          lat: l.location.lat,
          lng: l.location.lng,
        }));
      if (punti.length) tratte.push(punti);
    }
  }

  // HERE chiama i punti di pedaggio col nome del COMUNE (es. "Pero"), mentre
  // Moveo usa il nome del casello (es. "Barriera Milano Ghisolfa"): si cerca il
  // casello vero accanto a ogni punto. Sistema aperto (barriera) = un solo punto.
  const caselli = await Promise.all(tratte.map(async (punti) => {
    const primo = punti[0], ultimo = punti[punti.length - 1];
    const [entrata, uscita] = await Promise.all([
      nomeCasello(primo, apiKey),
      punti.length > 1 ? nomeCasello(ultimo, apiKey) : null,
    ]);
    return { entrata, uscita: uscita ?? entrata };
  }));
  return { metri, secondi, caselli };
}

// Casello ufficiale più vicino al punto di pedaggio, entro 1 km, tra i POI HERE
// di tipo trasporto (categorie 400-4100-*) con "casello"/"barriera" nel nome.
// Provato il 2026-11-14 su 6 tratte: con 400 m si perdeva "Casello di Arluno"
// (a 935 m dal punto HERE). Se non si trova nulla di affidabile si scrive
// "zona di <comune>" invece di indovinare un nome.
const RAGGIO_CASELLO_M = 1000;
async function nomeCasello(p: { comune: string; lat: number; lng: number }, apiKey: string): Promise<string> {
  const cerca = async (q: string) => {
    const url = new URL("https://discover.search.hereapi.com/v1/discover");
    url.searchParams.set("q", q);
    url.searchParams.set("in", `circle:${p.lat},${p.lng};r=${RAGGIO_CASELLO_M}`);
    url.searchParams.set("limit", "5");
    url.searchParams.set("lang", "it-IT");
    url.searchParams.set("apiKey", apiKey);
    try {
      const res = await fetch(url);
      if (!res.ok) return [];
      return (await res.json())?.items ?? [];
    } catch {
      return []; // il nome è un di più: un errore qui non deve far fallire il percorso
    }
  };
  // deno-lint-ignore no-explicit-any
  const trovati = (await Promise.all([cerca("casello"), cerca("barriera")])).flat() as any[];
  const best = trovati
    .filter((i) =>
      (i.distance ?? Infinity) <= RAGGIO_CASELLO_M &&
      /casello|barriera|toll plaza/i.test(i.title ?? "") &&
      (i.categories ?? []).some((c: { id?: string }) => String(c.id).startsWith("400-4100-"))
    )
    .sort((a, b) => a.distance - b.distance)[0];
  if (!best) return p.comune ? `zona di ${p.comune}` : "casello non identificato";
  return pulisciNomeCasello(best.title);
}

function pulisciNomeCasello(t: string) {
  // "A1 - Milan South Toll Plaza (A1 - Barriera Milano Sud)" → "Barriera Milano Sud"
  const par = t.match(/\(([^)]*(?:casello|barriera)[^)]*)\)/i);
  if (par) t = par[1];
  // "Arluno - Casello Autostradale" → "Casello di Arluno"
  const m = t.match(/^(.+?)\s*-\s*casello autostradale$/i);
  if (m) t = "Casello di " + m[1];
  // "Barriera Roma Est - A24 Autostrada dei Parchi" → "Barriera Roma Est"
  t = t.replace(/\s*-\s*A\d+\w*\b.*$/i, "");
  return t.replace(/^A\d+\w*\s*-\s*/i, "").trim();
}

function json(payload: unknown, status: number) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
