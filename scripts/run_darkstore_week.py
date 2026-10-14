"""
Pipeline semanal do Performance Darkstore — shopper-performance-prod.darkstore

Uso:
  python scripts/run_darkstore_week.py --week 42 --year 2026
  python scripts/run_darkstore_week.py --week 42 --year 2026 --skip-abast
  python scripts/run_darkstore_week.py --week 42 --year 2026 --only mart

Variáveis de ambiente (credencial com escopo bigquery + drive):
  BQ_DRIVE_CLIENT_ID
  BQ_DRIVE_CLIENT_SECRET
  BQ_DRIVE_REFRESH_TOKEN
"""
import argparse
import os
import sys
from datetime import date, timedelta
from pathlib import Path

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from google.cloud import bigquery


PROJ = "shopper-performance-prod"
STEPS = ["03", "04", "05", "06", "07"]
JOBS_DIR = Path(__file__).parent.parent / "jobs" / "darkstore"


def semana_datas(year: int, week: int):
    """Retorna (sexta anterior, quinta da semana ISO) — semana Shopper."""
    sexta = date.fromisocalendar(year, week, 5) - timedelta(days=7)
    quinta = date.fromisocalendar(year, week, 4)
    return str(sexta), str(quinta)


def build_client():
    client_id     = os.environ.get("BQ_DRIVE_CLIENT_ID")
    client_secret = os.environ.get("BQ_DRIVE_CLIENT_SECRET")
    refresh_token = os.environ.get("BQ_DRIVE_REFRESH_TOKEN")
    if not all([client_id, client_secret, refresh_token]):
        print("ERRO: variáveis BQ_DRIVE_* não configuradas.", file=sys.stderr)
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
    return bigquery.Client(project=PROJ, credentials=creds)


def run_sql(client, sql: str, job_label: str):
    job = client.query(sql, location="southamerica-east1")
    job.result()
    print(f"  ✅ {job_label} — job_id: {job.job_id}")


def load_and_substitute(sql_file: Path, replacements: dict) -> str:
    sql = sql_file.read_text(encoding="utf-8")
    for key, val in replacements.items():
        sql = sql.replace(key, val)
    return sql


def main():
    parser = argparse.ArgumentParser(description="Pipeline semanal darkstore")
    parser.add_argument("--week", type=int, required=True)
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--skip-abast", action="store_true",
                        help="Pular passo 06 (int_abastecimento_bonus)")
    parser.add_argument("--only", choices=["pedidos", "store", "person", "abast", "mart"],
                        help="Executar apenas um passo específico")
    args = parser.parse_args()

    date_ini, date_fim = semana_datas(args.year, args.week)
    replacements = {
        "[YEAR_REF]": str(args.year),
        "[WEEK_REF]": str(args.week),
        "[DATE_INI]": date_ini,
        "[DATE_FIM]": date_fim,
    }

    print(f"\n🗓  Semana W{args.week}/{args.year}  |  {date_ini} → {date_fim}")
    print(f"   Projeto: {PROJ}.darkstore\n")

    client = build_client()

    step_map = {
        "pedidos": "03_int_pedidos_sla.sql",
        "store":   "04_int_store_metrics.sql",
        "person":  "05_int_person_metrics.sql",
        "abast":   "06_int_abastecimento_bonus.sql",
        "mart":    "07_mart_bonificacao.sql",
    }

    if args.only:
        files = [step_map[args.only]]
    else:
        files = list(step_map.values())
        if args.skip_abast:
            files.remove("06_int_abastecimento_bonus.sql")

    for fname in files:
        path = JOBS_DIR / fname
        if not path.exists():
            print(f"  ⚠️  {fname} não encontrado — pulando")
            continue
        print(f"▶ {fname}")
        sql = load_and_substitute(path, replacements)
        run_sql(client, sql, fname)

    print("\n✅ Pipeline concluído.")


if __name__ == "__main__":
    main()
