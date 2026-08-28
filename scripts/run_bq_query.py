"""
Helper para rodar um arquivo SQL no BigQuery usando credenciais OAuth do ambiente.

Uso:
  python scripts/run_bq_query.py jobs/qa/00_kpis_operacao.sql
  python scripts/run_bq_query.py jobs/qa/07_feedback_operacional.sql --project shopper-datalakehouse-qa

Variáveis de ambiente necessárias (credenciais com escopo bigquery + drive):
  BQ_DRIVE_CLIENT_ID
  BQ_DRIVE_CLIENT_SECRET
  BQ_DRIVE_REFRESH_TOKEN
"""
import argparse
import os
import sys

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from google.cloud import bigquery


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sql_file", help="Caminho para o arquivo .sql")
    parser.add_argument("--project", default=os.getenv("BQ_PROJECT", "shopper-datalakehouse-qa"))
    parser.add_argument("--location", default="southamerica-east1")
    args = parser.parse_args()

    # Preferir BQ_DRIVE_* (escopo bigquery+drive, necessário para tabelas externas).
    # Cair em BQ_OAUTH_* se BQ_DRIVE_* não estiver configurado.
    client_id = os.environ.get("BQ_DRIVE_CLIENT_ID") or os.environ.get("BQ_OAUTH_CLIENT_ID")
    client_secret = os.environ.get("BQ_DRIVE_CLIENT_SECRET") or os.environ.get("BQ_OAUTH_CLIENT_SECRET")
    refresh_token = os.environ.get("BQ_DRIVE_REFRESH_TOKEN") or os.environ.get("BQ_OAUTH_REFRESH_TOKEN")

    if not client_id or not client_secret or not refresh_token:
        print("ERRO: nenhuma credencial BQ_DRIVE_* ou BQ_OAUTH_* encontrada no ambiente.", file=sys.stderr)
        sys.exit(1)

    creds = Credentials(
        token=None,
        client_id=client_id,
        client_secret=client_secret,
        refresh_token=refresh_token,
        token_uri="https://oauth2.googleapis.com/token",
        scopes=["https://www.googleapis.com/auth/bigquery"],
    )
    creds.refresh(Request())

    client = bigquery.Client(project=args.project, credentials=creds)

    with open(args.sql_file, encoding="utf-8") as f:
        sql = f.read()

    job = client.query(sql, location=args.location)
    job.result()
    print(f"✅ {args.sql_file} — job_id: {job.job_id}")


if __name__ == "__main__":
    main()
