#!/usr/bin/env python3
"""
Test di scripts/check_updates.py — solo libreria standard, nessuna dipendenza
da installare e nessuna rete: le chiamate HTTP sono sostituite da risposte
finte, così la suite gira identica su un laptop e in CI.

    python3 -m unittest discover -s tests -v
    make test

Il valore di questi test non è la copertura: è che il modo in cui questo
script sbaglia è SILENZIOSO. Se la selezione della release scarta per errore
un rilascio valido, il checker non segnala un errore — dice "nessun
aggiornamento", ed è indistinguibile dal caso in cui davvero non ce ne sono.
Un homelab può restare mesi su una versione vulnerabile senza che nulla lo
faccia notare. Ogni test qui sotto blocca un modo concreto di fallire così.
"""

import importlib.util
import json
import os
import unittest
from unittest import mock

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_spec = importlib.util.spec_from_file_location(
    "check_updates", os.path.join(BASE, "scripts", "check_updates.py"))
cu = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cu)


def fake_response(payload, text=None):
    """Risposta HTTP finta con la sola superficie che il modulo usa."""
    resp = mock.Mock()
    resp.json.return_value = payload
    resp.text = text if text is not None else json.dumps(payload)
    resp.raise_for_status.return_value = None
    return resp


def gh_release(tag, prerelease=False, name=None, draft=False):
    return {"tag_name": tag, "prerelease": prerelease,
            "name": name if name is not None else tag, "draft": draft}


# ──────────────────────────────────────────────────────────────────────────
class TestExtractSemver(unittest.TestCase):
    """Da stringa di versione a tupla confrontabile."""

    def test_formati_comuni(self):
        casi = {
            "v15.0.3":     (15, 0, 3),
            "2.15.0":      (2, 15, 0),
            "1.37.3":      (1, 37, 3),
            "v2.28.0":     (2, 28, 0),
            "n8n@2.39.10": (2, 39, 10),   # tag di monorepo
            "15.0":        (15, 0, 0),    # patch implicita
            "10":          (10, 0, 0),    # tag Docker a numero singolo
            "v8":          (8, 0, 0),
        }
        for testo, atteso in casi.items():
            with self.subTest(testo=testo):
                self.assertEqual(cu.extract_semver(testo), atteso)

    def test_non_versioni_danno_zero(self):
        # (0,0,0) è il valore sentinella: determine_bump lo tratta come
        # "non confrontabile" invece di fingere un confronto.
        for testo in ("latest", "", "stable", "edge"):
            with self.subTest(testo=testo):
                self.assertEqual(cu.extract_semver(testo), (0, 0, 0))

    def test_2_39_10_e_maggiore_di_2_39_9(self):
        # Il confronto è fra interi, non fra stringhe: "2.39.9" > "2.39.10"
        # lessicograficamente, ed è l'errore che si vuole escludere.
        self.assertGreater(cu.extract_semver("2.39.10"),
                           cu.extract_semver("2.39.9"))


# ──────────────────────────────────────────────────────────────────────────
class TestDetermineBump(unittest.TestCase):

    def test_classificazione(self):
        casi = [
            ((1, 0, 0), (2, 0, 0), "major", True),
            ((2, 33, 6), (2, 39, 10), "minor", False),
            ((1, 37, 1), (1, 37, 3), "patch", False),
            ((1, 37, 3), (1, 37, 3), "none", False),
            ((1, 37, 3), (1, 37, 1), "none", False),   # a ritroso: nessun update
        ]
        for corrente, ultima, bump, major in casi:
            with self.subTest(corrente=corrente, ultima=ultima):
                self.assertEqual(cu.determine_bump(corrente, ultima), (bump, major))

    def test_versione_non_confrontabile(self):
        self.assertEqual(cu.determine_bump((0, 0, 0), (1, 2, 3)), ("unknown", False))
        self.assertEqual(cu.determine_bump((1, 2, 3), (0, 0, 0)), ("unknown", False))


# ──────────────────────────────────────────────────────────────────────────
class TestIsStableRelease(unittest.TestCase):
    """
    Il filtro pre-release lavora sul TITOLO della release, che su diverse
    forge è una frase e non un numero. Un match per sottostringa nuda su
    "rc" o "dev" colpisce parole normali e fa sparire rilasci veri.
    """

    def test_scarta_le_prerelease(self):
        for titolo in ("v1.2.3-rc.1", "v1.2.3-RC2", "v2.0.0-beta", "v2.0.0-beta.3",
                       "1.0-alpha", "nightly", "v3.0-preview", "v1.0.0rc1",
                       "2.0.0-dev", "v4.0-TEST"):
            with self.subTest(titolo=titolo):
                self.assertFalse(cu.is_stable_release(titolo),
                                 f"{titolo!r} doveva essere scartata")

    def test_non_scarta_titoli_descrittivi_legittimi(self):
        # Ognuna di queste contiene una keyword come sottostringa di una
        # parola comune: architectu(rc)e, sou(rc)e, sea(rc)h, fo(rc)e,
        # (dev)ice, la(test).
        for titolo in ("v2.0.0 architecture rewrite",
                       "Release 3.1 — source cleanup",
                       "v1.0 search improvements",
                       "v9.9 force push fix",
                       "v4.0 device support",
                       "v5.0 developer experience",
                       "latest",
                       "v6.0 greatest hits",
                       "v7.0 performance"):
            with self.subTest(titolo=titolo):
                self.assertTrue(cu.is_stable_release(titolo),
                                f"{titolo!r} è un rilascio stabile e non doveva "
                                f"essere scartato")


# ──────────────────────────────────────────────────────────────────────────
class TestParseImage(unittest.TestCase):

    def test_separazione_immagine_tag(self):
        casi = {
            "postgres:18-alpine":
                ("postgres", "18-alpine", "18"),
            "codeberg.org/forgejo/forgejo:15.0.9":
                ("codeberg.org/forgejo/forgejo", "15.0.9", "15.0.9"),
            "ghcr.io/gethomepage/homepage:v1.13.2":
                ("ghcr.io/gethomepage/homepage", "v1.13.2", "v1.13.2"),
            "cloudflare/cloudflared:latest":
                ("cloudflare/cloudflared", "latest", "latest"),
            "redis:8-alpine":
                ("redis", "8-alpine", "8"),
        }
        for immagine, atteso in casi.items():
            with self.subTest(immagine=immagine):
                self.assertEqual(cu.parse_image(immagine), atteso)

    def test_tag_assente_diventa_latest(self):
        self.assertEqual(cu.parse_image("nginx"), ("nginx", "latest", "latest"))

    def test_suffisso_numerico_non_viene_tagliato(self):
        # "2025.01.20" non ha suffisso di build: va lasciato intero.
        self.assertEqual(cu.parse_image("app:2025.01.20")[2], "2025.01.20")


# ──────────────────────────────────────────────────────────────────────────
class TestSelezioneReleaseForgeAPI(unittest.TestCase):
    """
    La scelta deve dipendere dai numeri di versione, non dall'ordine in cui
    la forge elenca i rilasci.
    """

    def _chiama(self, releases, current="2.33.6",
                repo_url="https://github.com/n8n-io/n8n"):
        with mock.patch.object(cu.requests, "get",
                               return_value=fake_response(releases)):
            return cu.get_latest_from_forge_api(repo_url, "n8n-io", "n8n", current)

    def test_ignora_l_ordine_dell_api(self):
        # Caso reale del 2026-09-21: l'API di GitHub elencava 2.39.9 prima di
        # 2.39.10, e prendere il primo elemento proponeva una versione già
        # superata lo stesso giorno.
        releases = [gh_release("n8n@2.39.9"), gh_release("n8n@2.39.10")]
        self.assertEqual(self._chiama(releases)["version"], "n8n@2.39.10")

    def test_stesso_risultato_a_ordine_invertito(self):
        releases = [gh_release("n8n@2.39.10"), gh_release("n8n@2.39.9")]
        self.assertEqual(self._chiama(releases)["version"], "n8n@2.39.10")

    def test_scarta_le_prerelease_anche_se_piu_alte(self):
        # n8n marca l'intera linea 2.40.x come prerelease (canale `next`):
        # il massimo per semver non deve saltarci sopra.
        releases = [gh_release("n8n@2.40.5", prerelease=True),
                    gh_release("n8n@2.40.4", prerelease=True),
                    gh_release("n8n@2.39.10"),
                    gh_release("n8n@2.39.9")]
        self.assertEqual(self._chiama(releases)["version"], "n8n@2.39.10")

    def test_resta_sulla_major_corrente(self):
        # Forgejo pubblica 15.x e 16.x lo stesso giorno: chi è su 15 non deve
        # essere spinto sulla major successiva.
        releases = [gh_release("v16.0.5"), gh_release("v15.0.9"),
                    gh_release("v16.0.4"), gh_release("v15.0.8")]
        got = self._chiama(releases, current="15.0.6",
                           repo_url="https://codeberg.org/forgejo/forgejo")
        self.assertEqual(got["version"], "v15.0.9")

    def test_ignora_le_bozze(self):
        releases = [gh_release("n8n@2.99.0", draft=True), gh_release("n8n@2.39.10")]
        self.assertEqual(self._chiama(releases)["version"], "n8n@2.39.10")

    def test_i_tag_mobili_non_vincono_sui_numeri(self):
        # n8n pubblica anche release chiamate "stable" e "latest". Si
        # estraggono come (0,0,0) e non devono mai essere restituite come
        # se fossero un numero di versione.
        releases = [gh_release("stable"), gh_release("latest"),
                    gh_release("n8n@2.39.10")]
        self.assertEqual(self._chiama(releases)["version"], "n8n@2.39.10")

    def test_errore_esplicito_se_non_c_e_nulla_di_stabile(self):
        releases = [gh_release("v1.0.0-rc.1", prerelease=True)]
        with self.assertRaises(ValueError):
            self._chiama(releases, current="1.0.0")


# ──────────────────────────────────────────────────────────────────────────
ATOM = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>{a}</title></entry>
  <entry><title>{b}</title></entry>
  <entry><title>{c}</title></entry>
</feed>"""


class TestSelezioneReleaseRSS(unittest.TestCase):
    """Il fallback RSS deve seguire la stessa regola del percorso API."""

    def _chiama(self, a, b, c, current="2.33.6"):
        xml = ATOM.format(a=a, b=b, c=c)
        with mock.patch.object(cu.requests, "get",
                               return_value=fake_response(None, text=xml)):
            return cu.get_latest_from_rss("https://esempio/releases.atom", current)

    def test_prende_la_versione_piu_alta_non_la_prima(self):
        # L'ordine di un feed Atom riflette la data, non la versione.
        self.assertEqual(self._chiama("2.39.9", "2.39.10", "2.38.0"), "2.39.10")

    def test_scarta_le_prerelease(self):
        self.assertEqual(self._chiama("2.40.0-rc.1", "2.39.10", "2.39.9"), "2.39.10")

    def test_resta_sulla_major_corrente(self):
        self.assertEqual(self._chiama("3.0.0", "2.39.10", "2.39.9"), "2.39.10")

    def test_errore_se_il_feed_non_ha_nulla_di_utile(self):
        with self.assertRaises(ValueError):
            self._chiama("nightly", "v1.0-beta", "alpha-2")


# ──────────────────────────────────────────────────────────────────────────
class TestCoerenzaMetadata(unittest.TestCase):
    """
    services_metadata.json è la sorgente da cui il checker capisce cosa
    tracciare: se si corrompe o perde un campo, il servizio smette di essere
    controllato senza che nulla lo segnali.
    """

    def setUp(self):
        with open(os.path.join(BASE, "services_metadata.json")) as f:
            self.meta = json.load(f)

    def test_ogni_servizio_ha_criticality_e_stack(self):
        for nome, voce in self.meta.items():
            with self.subTest(servizio=nome):
                self.assertIn("criticality", voce)
                self.assertIn("stack", voce)

    def test_criticality_fra_i_valori_previsti(self):
        ammessi = {"critical", "medium", "low", "stateless", "dependency"}
        for nome, voce in self.meta.items():
            with self.subTest(servizio=nome):
                self.assertIn(voce["criticality"], ammessi)

    def test_chi_ha_un_repo_ha_di_che_interrogarlo(self):
        # Senza `repo` né la coppia owner/name il servizio risulta tracciato
        # ma non controllabile: è il caso che passa inosservato.
        for nome, voce in self.meta.items():
            if voce.get("criticality") in ("stateless", "dependency"):
                continue
            with self.subTest(servizio=nome):
                ha_repo = bool(voce.get("repo"))
                ha_coppia = bool(voce.get("github_owner")) and \
                            bool(voce.get("github_repo_name"))
                self.assertTrue(ha_repo or ha_coppia,
                                f"{nome} è tracciato ma non ha un repository "
                                f"da interrogare")


if __name__ == "__main__":
    unittest.main(verbosity=2)
