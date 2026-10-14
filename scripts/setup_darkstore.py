"""
Cria todas as tabelas DDL do darkstore em shopper-performance-prod e executa o backfill.

Uso:
  cd performance-dataform
  python scripts/setup_darkstore.py             # só DDL
  python scripts/setup_darkstore.py --backfill  # DDL + backfill histórico

Lê credenciais de scripts/.env (BQ_DRIVE_*)
"""
import argparse
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from google.cloud import bigquery

BASE = Path(__file__).parent.parent
DDL_DIRS = [
    BASE / "ddl" / "darkstore" / "raw",
    BASE / "ddl" / "darkstore" / "int",
    BASE / "ddl" / "darkstore" / "mart",
]
BACKFILL = BASE / "jobs" / "darkstore" / "backfill_historico.sql"
PROJ = "shopper-performance-prod"


def build_client():
    load_dotenv(Path(__file__).parent / ".env")
    client_id     = os.environ.get("BQ_DRIVE_CLIENT_ID")
    client_secret = os.environ.get("BQ_DRIVE_CLIENT_SECRET")
    refresh_token = os.environ.get("BQ_DRIVE_REFRESH_TOKEN")
    if not all([client_id, client_secret, refresh_token]):
        print("ERRO: BQ_DRIVE_* não encontrados no .env", file=sys.stderr)
        sys.exit(1)
    creds = Credentials(
        token=None,
        client_id=client_id, client_secret=client_secret, refresh_token=refresh_token,
        token_uri="https://oauth2.googleapis.com/token",
        scopes=["https://www.googleapis.com/auth/bigquery", "https://www.googleapis.com/auth/drive"],
    )
    creds.refresh(Request())
    return bigquery.Client(project=PROJ, credentials=creds)


def run_sql(client, sql, label):
    try:
        job = client.query(sql, location="southamerica-east1")
        job.result()
        print(f"  ✅ {label}")
    except Exception as e:
        print(f"  ❌ {label}: {e}")


def run_ddl(client):
    # DDL de cada tabela — separadas por ";" no arquivo de setup ou arquivos individuais
    skip = {"raw_erros_clientes.sql", "organograma_bonificacao.sql"}  # Drive-linked, criar manualmente
    for d in DDL_DIRS:
        if not d.exists():
            continue
        for f in sorted(d.glob("*.sql")):
            if f.name in skip:
                print(f"  ⏭  {f.name} — Drive-linked, pular")
                continue
            sql = f.read_text(encoding="utf-8").strip()
            if not sql:
                continue
            # Arquivos DDL podem ter múltiplos statements; executar um a um
            for stmt in [s.strip() for s in sql.split(";") if s.strip()]:
                run_sql(client, stmt, f.name)


def run_backfill(client):
    print("\n── Backfill histórico ──")
    sql = BACKFILL.read_text(encoding="utf-8")
    # Separa por ";" e executa statement a statement
    stmts = [s.strip() for s in sql.split(";") if s.strip() and not s.strip().startswith("--")]
    for i, stmt in enumerate(stmts, 1):
        label = f"backfill stmt {i}"
        # Tenta extrair um label do comentário acima
        lines = stmt.split("\n")
        for ln in lines:
            if ln.strip().startswith("-- ──"):
                label = ln.strip().lstrip("-- ──").strip()
                break
        run_sql(client, stmt, label)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backfill", action="store_true", help="Executar backfill após DDL")
    parser.add_argument("--only-backfill", action="store_true", help="Só backfill, pular DDL")
    args = parser.parse_args()

    client = build_client()
    print(f"✔  Conectado: {PROJ}\n")

    if not args.only_backfill:
        print("── DDL — criando tabelas ──")
        run_ddl(client)

    if args.backfill or args.only_backfill:
        run_backfill(client)

    print("\n✅ Concluído.")


if __name__ == "__main__":
    main()
