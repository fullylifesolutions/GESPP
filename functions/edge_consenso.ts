// ============================================================================
//  SISTEMA SPP — EDGE FUNCTION "consenso" (v3)
//  Non accede più alle tabelle direttamente per persons/health_consents:
//  chiama le funzioni del database consenso_leggi / consenso_firma
//  (SECURITY DEFINER), che fanno il lavoro con i propri privilegi. Così non
//  serve bypassare la RLS con chiavi speciali per quella parte.
//  Il testo dell'informativa e le checkbox di consenso non sono più
//  hardcoded qui: vengono letti a runtime da public.consent_config, così
//  un aggiornamento del testo legale non richiede più ridistribuire questa
//  funzione — basta aggiornare la riga (dalla schermata admin "Consenso
//  sanitario" in GESPP).
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
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

    // Passa da una RPC security-definer (consent_config_leggi), non da una
    // select diretta sulla tabella: stesso motivo di consenso_leggi/
    // consenso_firma sotto, non serve dare grant specifici al ruolo con
    // cui gira questa funzione.
    const { data: configRows, error: cfgError } = await supabase.rpc("consent_config_leggi");
    const config = configRows && configRows[0];
    if (cfgError || !config) {
      console.error("consent_config_leggi failed:", cfgError);
      return json({ errore: "Configurazione del consenso non disponibile. Contatta l'amministratore." }, 500);
    }
    const punti: { chiave: string; etichetta: string }[] = Array.isArray(config.punti) ? config.punti : [];

    if (azione === "leggi") {
      const { data, error } = await supabase.rpc("consenso_leggi", { p_token: token });
      if (error) return json({ errore: "Errore: " + error.message }, 500);
      if (!data || data.length === 0) {
        return json({ errore: "Link non valido, scaduto o già utilizzato." }, 404);
      }
      const nomePersona = `${data[0].nome} ${data[0].cognome}`;
      return json({
        persona: nomePersona,
        informativa: {
          versione: config.versione,
          punti,
          informativaPdfUrl: config.informativa_pdf_url || null,
          consensoPdfUrl: config.consenso_pdf_url || null,
        },
      }, 200);
    }

    if (azione === "firma") {
      const tutteAccettate = punti.length > 0 && punti.every((p) => spunte && spunte[p.chiave] === true);
      if (!tutteAccettate) return json({ errore: "Devi accettare tutti i punti per procedere." }, 400);
      if (!firma) return json({ errore: "La firma è obbligatoria." }, 400);

      const { data, error } = await supabase.rpc("consenso_firma", {
        p_token: token,
        p_spunte: spunte,
        p_firma: firma,
        p_canale: canale === "presenza" ? "presenza" : "remoto",
        p_versione: config.versione,
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
