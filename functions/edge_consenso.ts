// ============================================================================
//  SISTEMA SPP — EDGE FUNCTION "consenso" (v2)
//  Non accede più alle tabelle direttamente: chiama le funzioni del database
//  consenso_leggi / consenso_firma (SECURITY DEFINER), che fanno il lavoro
//  con i propri privilegi. Così non serve bypassare la RLS con chiavi speciali.
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const INFORMATIVA = {
  versione: "v1.0-bozza",
  testo: "BOZZA NON VALIDA — inserire qui il testo dell'informativa fornito dal legale. Segnaposto a soli fini di test tecnico.",
  punti: [
    { chiave: "informativa", etichetta: "Ho letto e compreso l'informativa." },
    { chiave: "trattamento", etichetta: "Acconsento al trattamento dei miei dati relativi alla salute." },
    { chiave: "revoca",      etichetta: "So di poter revocare il consenso in qualsiasi momento, senza conseguenze." },
  ],
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { azione, token, spunte, firma, canale } = await req.json();
    if (!token || typeof token !== "string") {
      return json({ errore: "Token mancante." }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SERVICE_KEY")!
    );

    if (azione === "leggi") {
      const { data, error } = await supabase.rpc("consenso_leggi", { p_token: token });
      if (error) return json({ errore: "Errore: " + error.message }, 500);
      if (!data || data.length === 0) {
        return json({ errore: "Link non valido, scaduto o già utilizzato." }, 404);
      }
      const nomePersona = `${data[0].nome} ${data[0].cognome}`;
      return json({ persona: nomePersona, informativa: INFORMATIVA }, 200);
    }

    if (azione === "firma") {
      const tutteAccettate = INFORMATIVA.punti.every((p) => spunte && spunte[p.chiave] === true);
      if (!tutteAccettate) return json({ errore: "Devi accettare tutti i punti per procedere." }, 400);
      if (!firma) return json({ errore: "La firma è obbligatoria." }, 400);

      const { data, error } = await supabase.rpc("consenso_firma", {
        p_token: token,
        p_spunte: spunte,
        p_firma: firma,
        p_canale: canale === "presenza" ? "presenza" : "remoto",
        p_versione: INFORMATIVA.versione,
      });
      if (error) {
        const msg = (error.message || "").includes("TOKEN_NON_VALIDO")
          ? "Link non valido, scaduto o già utilizzato."
          : "Errore nella registrazione: " + error.message;
        return json({ errore: msg }, 400);
      }
      return json({ ok: true, persona: data }, 200);
    }

    return json({ errore: "Azione non riconosciuta." }, 400);
  } catch (e) {
    return json({ errore: "Richiesta non valida: " + ((e as Error)?.message ?? String(e)) }, 400);
  }
});

function json(payload: unknown, status: number) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
