"""
Alertas Intraday — Performance Ranking

Modo de operação:
  --detectar   → detecta alertas e grava no BQ (sem enviar Slack)
  --consolidar → lê alertas do dia no BQ e envia resumo único no Slack

Workflow:
  07h e 15h  → python alertas_intraday.py --detectar
  23h        → python alertas_intraday.py --detectar --consolidar

Alerta 1 — Queda de qty em promotora:
  Compara os dois snapshots mais recentes. Se qty de promotora reduziu, alerta.

Alerta 2 — Score suspeito para o dia do ciclo (sexta=1 … quinta=7):
  Dia 2-3 (sáb/dom)  → acima de 1.000.000 pts
  Dia 4-5 (seg/ter)  → acima de 2.000.000 pts
  Dia 6-7 (qua/qui)  → acima de 3.000.000 pts

Variáveis de ambiente:
  BQ_DRIVE_CLIENT_ID / BQ_DRIVE_CLIENT_SECRET / BQ_DRIVE_REFRESH_TOKEN
  BQ_PROJECT      (default: shopper-datalakehouse-qa)
  SLACK_BOT_TOKEN
  SLACK_CHANNEL   (default: D093C1WN0ET)
"""

import argparse
import os
import sys
from datetime import date, datetime

import requests
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from google.cloud import bigquery


# ─── Config ────────────────────────────────────────────────────────────────

PROJECT    = os.getenv("BQ_PROJECT", "shopper-datalakehouse-qa")
DATASET    = "Ranking_Performance"
TABLE_HIST = "Tabela_Intraday_Performance_Historico"
TABLE_LOG  = "alertas_intraday_log"
SLACK_CHAN = os.getenv("SLACK_CHANNEL", "D093C1WN0ET")
SLACK_TOK  = os.getenv("SLACK_BOT_TOKEN", "")

THRESHOLD_BY_CYCLE_DAY = {
    2: 1_000_000,
    3: 1_000_000,
    4: 2_000_000,
    5: 2_000_000,
    6: 3_000_000,
    7: 3_000_000,
}

LOG_SCHEMA = [
    bigquery.SchemaField("data",           "DATE"),
    bigquery.SchemaField("snapshot_horario","STRING"),
    bigquery.SchemaField("tipo_alerta",    "STRING"),
    bigquery.SchemaField("matricula",      "STRING"),
    bigquery.SchemaField("nome",           "STRING"),
    bigquery.SchemaField("fc",             "STRING"),
    bigquery.SchemaField("setor_principal","STRING"),
    bigquery.SchemaField("metrica",        "STRING"),
    bigquery.SchemaField("qty_antes",      "FLOAT64"),
    bigquery.SchemaField("qty_agora",      "FLOAT64"),
    bigquery.SchemaField("delta_qty",      "FLOAT64"),
    bigquery.SchemaField("pontos_liquidos","FLOAT64"),
    bigquery.SchemaField("threshold",      "INT64"),
    bigquery.SchemaField("snap_anterior",  "STRING"),
    bigquery.SchemaField("snap_atual",     "STRING"),
    bigquery.SchemaField("created_at",     "DATETIME"),
]


# ─── BQ Client ─────────────────────────────────────────────────────────────

def bq_client():
    client_id     = os.environ.get("BQ_DRIVE_CLIENT_ID") or os.environ.get("BQ_OAUTH_CLIENT_ID")
    client_secret = os.environ.get("BQ_DRIVE_CLIENT_SECRET") or os.environ.get("BQ_OAUTH_CLIENT_SECRET")
    refresh_token = os.environ.get("BQ_DRIVE_REFRESH_TOKEN") or os.environ.get("BQ_OAUTH_REFRESH_TOKEN")

    if not (client_id and client_secret and refresh_token):
        print("ERRO: credenciais BQ não encontradas.", file=sys.stderr)
        sys.exit(1)

    creds = Credentials(
        token=None,
        client_id=client_id,
        client_secret=client_secret,
        refresh_token=refresh_token,
        token_uri="https://oauth2.googleapis.com/token",
        scopes=[
            "https://www.googleapis.com/auth/bigquery",
            "https://www.googleapis.com/auth/drive",
        ],
    )
    creds.refresh(Request())
    return bigquery.Client(project=PROJECT, credentials=creds)


def ensure_log_table(client):
    table_ref = f"{PROJECT}.{DATASET}.{TABLE_LOG}"
    try:
        client.get_table(table_ref)
    except Exception:
        table = bigquery.Table(table_ref, schema=LOG_SCHEMA)
        table.time_partitioning = bigquery.TimePartitioning(field="data")
        client.create_table(table)
        print(f"Tabela {TABLE_LOG} criada.")


# ─── Ciclo ─────────────────────────────────────────────────────────────────

def cycle_day(today: date) -> int | None:
    mapping = {4: 1, 5: 2, 6: 3, 0: 4, 1: 5, 2: 6, 3: 7}
    return mapping.get(today.weekday())


# ─── Detecção ──────────────────────────────────────────────────────────────

def detectar_alerta1(client) -> list[dict]:
    sql = f"""
    WITH snapshots AS (
      SELECT matricula,
        snapshot_at,
        ROW_NUMBER() OVER (PARTITION BY matricula ORDER BY snapshot_at DESC) AS rn
      FROM `{PROJECT}.{DATASET}.{TABLE_HIST}`
      WHERE snapshot_at >= DATETIME_SUB(CURRENT_DATETIME('America/Sao_Paulo'), INTERVAL 3 DAY)
    ),
    snap_atual AS (
      SELECT h.matricula, h.nome, h.fc, h.setor_principal, h.snapshot_at,
        d.metric_description, d.qty, d.pontos_ponderados
      FROM `{PROJECT}.{DATASET}.{TABLE_HIST}` h, UNNEST(details) AS d
      JOIN (SELECT matricula, snapshot_at FROM snapshots WHERE rn = 1) s
        USING (matricula, snapshot_at)
      WHERE d.pontos_ponderados > 0
    ),
    snap_anterior AS (
      SELECT h.matricula, h.snapshot_at AS snap_ant_at,
        d.metric_description, d.qty AS qty_ant
      FROM `{PROJECT}.{DATASET}.{TABLE_HIST}` h, UNNEST(details) AS d
      JOIN (SELECT matricula, snapshot_at FROM snapshots WHERE rn = 2) s
        USING (matricula, snapshot_at)
      WHERE d.pontos_ponderados > 0
    )
    SELECT
      a.matricula, a.nome, a.fc, a.setor_principal,
      FORMAT_DATETIME('%d/%m %H:%M', a.snapshot_at)  AS snap_atual,
      FORMAT_DATETIME('%d/%m %H:%M', b.snap_ant_at)  AS snap_anterior,
      a.metric_description AS metrica,
      ROUND(b.qty_ant, 2) AS qty_antes,
      ROUND(a.qty, 2)     AS qty_agora,
      ROUND(a.qty - b.qty_ant, 2) AS delta_qty
    FROM snap_atual a
    JOIN snap_anterior b USING (matricula, metric_description)
    WHERE a.qty < b.qty_ant AND b.qty_ant > 0
    ORDER BY delta_qty ASC
    LIMIT 50
    """
    rows = list(client.query(sql, location="southamerica-east1").result())
    now = datetime.utcnow().strftime("%H:%M")
    today = date.today().isoformat()
    return [
        {
            "data": today,
            "snapshot_horario": now,
            "tipo_alerta": "qty_queda",
            "matricula": r.matricula,
            "nome": r.nome,
            "fc": r.fc,
            "setor_principal": r.setor_principal,
            "metrica": r.metrica,
            "qty_antes": r.qty_antes,
            "qty_agora": r.qty_agora,
            "delta_qty": r.delta_qty,
            "pontos_liquidos": None,
            "threshold": None,
            "snap_anterior": r.snap_anterior,
            "snap_atual": r.snap_atual,
            "created_at": datetime.utcnow().isoformat(),
        }
        for r in rows
    ]


def detectar_alerta2(client, threshold: int) -> list[dict]:
    sql = f"""
    SELECT
      matricula, nome, fc, setor_principal,
      ROUND(pontos_liquidos, 0) AS pontos_liquidos,
      FORMAT_DATETIME('%d/%m %H:%M', snapshot_at) AS snapshot
    FROM `{PROJECT}.{DATASET}.{TABLE_HIST}`
    WHERE snapshot_at = (SELECT MAX(snapshot_at) FROM `{PROJECT}.{DATASET}.{TABLE_HIST}`)
      AND pontos_liquidos > @threshold
    ORDER BY pontos_liquidos DESC
    LIMIT 30
    """
    job_cfg = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("threshold", "INT64", threshold)]
    )
    rows = list(client.query(sql, job_config=job_cfg, location="southamerica-east1").result())
    now = datetime.utcnow().strftime("%H:%M")
    today = date.today().isoformat()
    return [
        {
            "data": today,
            "snapshot_horario": now,
            "tipo_alerta": "score_suspeito",
            "matricula": r.matricula,
            "nome": r.nome,
            "fc": r.fc,
            "setor_principal": r.setor_principal,
            "metrica": None,
            "qty_antes": None,
            "qty_agora": None,
            "delta_qty": None,
            "pontos_liquidos": float(r.pontos_liquidos),
            "threshold": threshold,
            "snap_anterior": None,
            "snap_atual": r.snapshot,
            "created_at": datetime.utcnow().isoformat(),
        }
        for r in rows
    ]


def gravar_log(client, alertas: list[dict]):
    if not alertas:
        return
    table_ref = f"{PROJECT}.{DATASET}.{TABLE_LOG}"
    errors = client.insert_rows_json(table_ref, alertas)
    if errors:
        print(f"Erro ao gravar log: {errors}", file=sys.stderr)
    else:
        print(f"{len(alertas)} alerta(s) gravado(s) no BQ.")


# ─── Consolidação e envio ──────────────────────────────────────────────────

def consolidar_e_enviar(client, today: date):
    sql = f"""
    SELECT tipo_alerta, snapshot_horario, matricula, nome, fc, setor_principal,
           metrica, qty_antes, qty_agora, delta_qty, pontos_liquidos, threshold, snap_anterior, snap_atual
    FROM `{PROJECT}.{DATASET}.{TABLE_LOG}`
    WHERE data = '{today.isoformat()}'
    ORDER BY tipo_alerta, snapshot_horario, delta_qty ASC
    """
    rows = list(client.query(sql, location="southamerica-east1").result())

    if not rows:
        print("Nenhum alerta registrado hoje — nada a enviar.")
        return

    # Agrupa por tipo
    qty_rows   = [r for r in rows if r.tipo_alerta == "qty_queda"]
    score_rows = [r for r in rows if r.tipo_alerta == "score_suspeito"]

    blocks = []
    text_header = f":bar_chart: *Resumo de Alertas Intraday — {today.strftime('%d/%m/%Y')}*"
    blocks.append({"type": "header", "text": {"type": "plain_text", "text": f"Alertas Intraday — {today.strftime('%d/%m/%Y')}"}})

    if qty_rows:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": ":warning: *Alerta 1 — Queda de qty em promotoras*"}})
        # Agrupa por colaborador (pode aparecer em múltiplos snapshots)
        seen = {}
        for r in qty_rows:
            key = (r.matricula, r.metrica)
            if key not in seen:
                seen[key] = r
        for r in seen.values():
            txt = (
                f"• *{r.nome}* ({r.matricula}) | {r.fc} {r.setor_principal}\n"
                f"  `{r.metrica}`: {r.qty_antes} → {r.qty_agora} ({r.delta_qty:+.2f})\n"
                f"  {r.snap_anterior} → {r.snap_atual}"
            )
            blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": txt}})

    if score_rows:
        blocks.append({"type": "divider"})
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": ":rocket: *Alerta 2 — Score acima do esperado para o dia do ciclo*"}})
        seen2 = {}
        for r in score_rows:
            if r.matricula not in seen2 or r.pontos_liquidos > seen2[r.matricula].pontos_liquidos:
                seen2[r.matricula] = r
        for r in seen2.values():
            txt = (
                f"• *{r.nome}* ({r.matricula}) | {r.fc} {r.setor_principal}\n"
                f"  Pontos: *{int(r.pontos_liquidos):,}* (limite: {r.threshold:,}) — {r.snap_atual}"
            )
            blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": txt}})

    slack_send(blocks, text_header)
    print(f"Resumo enviado: {len(qty_rows)} queda(s) de qty, {len(score_rows)} score(s) suspeito(s).")


# ─── Slack ─────────────────────────────────────────────────────────────────

def slack_send(blocks: list, text: str):
    if not SLACK_TOK:
        print("SLACK_BOT_TOKEN não configurado — pulando envio.", file=sys.stderr)
        return
    resp = requests.post(
        "https://slack.com/api/chat.postMessage",
        headers={"Authorization": f"Bearer {SLACK_TOK}", "Content-Type": "application/json"},
        json={"channel": SLACK_CHAN, "text": text, "blocks": blocks},
        timeout=15,
    )
    data = resp.json()
    if not data.get("ok"):
        print(f"Slack erro: {data.get('error')}", file=sys.stderr)


# ─── Main ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--detectar",   action="store_true", help="Detecta e grava alertas no BQ")
    parser.add_argument("--consolidar", action="store_true", help="Consolida alertas do dia e envia Slack")
    args = parser.parse_args()

    if not args.detectar and not args.consolidar:
        parser.print_help()
        sys.exit(1)

    client = bq_client()
    today  = date.today()
    cday   = cycle_day(today)

    if args.detectar:
        ensure_log_table(client)
        alertas = []

        # Alerta 1 — queda de qty
        a1 = detectar_alerta1(client)
        print(f"Alerta 1: {len(a1)} caso(s) de queda de qty.")
        alertas.extend(a1)

        # Alerta 2 — score suspeito
        threshold = THRESHOLD_BY_CYCLE_DAY.get(cday)
        if threshold:
            a2 = detectar_alerta2(client, threshold)
            print(f"Alerta 2: {len(a2)} colaborador(es) acima de {threshold:,} pts (dia {cday} do ciclo).")
            alertas.extend(a2)
        else:
            print(f"Alerta 2: dia {cday} do ciclo — sem threshold (sexta = fechamento).")

        gravar_log(client, alertas)

    if args.consolidar:
        consolidar_e_enviar(client, today)


if __name__ == "__main__":
    main()
