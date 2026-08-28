"""
Lê carteira_operação do BQ (já com CPF) e preenche
a planilha [Performance][Operação] no Drive para a semana do período.

Uso:
  python preencher_planilha_performance.py                      # período atual automático
  python preencher_planilha_performance.py --inicio 2026-05-08  # período específico
"""
import argparse
import logging
import os
import sys
import io
from datetime import date, timedelta

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

from google.cloud import bigquery
from google.auth import load_credentials_from_file
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
import gspread

PROJECT_ID  = os.getenv("PROJECT_ID", "shopper-datalakehouse-qa")
CREDENTIALS = os.getenv("CREDENTIALS")
TOKEN_PATH  = os.getenv("SHEETS_TOKEN_PATH") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "sheets_token.json")
FOLDER_ID   = os.getenv("DRIVE_PAGAMENTO_FOLDER_ID", "1wz6cDH-WFbhb9Icf0NHG5gnGhDu_W2lM")
BQ_TABLE    = f"{PROJECT_ID}.Ranking_Performance.carteira_operação"


def periodo_atual() -> tuple:
    hoje = date.today()
    dow = hoje.weekday()  # 0=seg … 6=dom
    dias_ate_sexta = (dow - 4) % 7
    sexta = hoje - timedelta(days=dias_ate_sexta)
    return sexta


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inicio", help="Data de início do período (YYYY-MM-DD)", default=None)
    args = parser.parse_args()

    if args.inicio:
        data_inicio = date.fromisoformat(args.inicio)
    else:
        data_inicio = periodo_atual()

    semana_num = data_inicio.isocalendar()[1]
    logging.info(f"Período: {data_inicio} | Semana ISO: {semana_num}")

    # 1. Lê do BQ
    key_file = CREDENTIALS or os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
    creds_bq, _ = load_credentials_from_file(
        key_file, scopes=["https://www.googleapis.com/auth/bigquery"]
    )
    client = bigquery.Client(project=PROJECT_ID, credentials=creds_bq)

    rows = list(client.query(f"""
        SELECT cpf, CAST(valor_a_pagar AS FLOAT64) AS valor
        FROM `{BQ_TABLE}`
        WHERE data_inicio_ranking = '{data_inicio}'
          AND CAST(valor_a_pagar AS FLOAT64) > 0
          AND cpf IS NOT NULL
        ORDER BY cpf
    """).result())

    logging.info(f"Registros com pagamento e CPF: {len(rows)}")

    linhas = [["cpf", "valor"]]
    for r in rows:
        valor_fmt = f"{float(r.valor):.2f}".replace(".", ",")
        linhas.append([str(r.cpf).strip().zfill(11), valor_fmt])

    if not linhas:
        logging.error("Nenhuma linha para inserir. Verifique se o BQ tem CPF preenchido.")
        sys.exit(1)

    # 2. Localiza planilha no Drive
    creds_oauth = Credentials.from_authorized_user_file(TOKEN_PATH, scopes=[
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.readonly",
    ])
    if creds_oauth.expired and creds_oauth.refresh_token:
        creds_oauth.refresh(Request())

    drive_svc = build("drive", "v3", credentials=creds_oauth)
    gc        = gspread.authorize(creds_oauth)

    # Busca subpasta Semana XX (aceita "Semana 19" ou "Semana 19 - ...")
    res = drive_svc.files().list(
        q=f"'{FOLDER_ID}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false",
        fields="files(id,name)"
    ).execute()

    pasta = None
    for f in res.get("files", []):
        nome = f["name"]
        if f"Semana {semana_num:02d}" in nome or f"Semana {semana_num}" in nome:
            pasta = f
            break

    if not pasta:
        logging.error(f"Pasta Semana {semana_num} não encontrada em {FOLDER_ID}")
        logging.info(f"Pastas disponíveis: {[f['name'] for f in res.get('files', [])]}")
        sys.exit(1)

    logging.info(f"Pasta encontrada: {pasta['name']}")

    # Busca planilha [Performance][Operação] — exclui Assiduidade, Correção, Coordenadores
    res2 = drive_svc.files().list(
        q=f"'{pasta['id']}' in parents and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false",
        fields="files(id,name)"
    ).execute()

    sheet_file = None
    for f in res2.get("files", []):
        n = f["name"].lower()
        if ("opera" in n or "operação" in n) and not any(x in n for x in ["assid", "corre", "coord"]):
            sheet_file = f
            break

    if not sheet_file:
        logging.error(f"Planilha [Performance][Operação] não encontrada em '{pasta['name']}'")
        logging.info(f"Arquivos na pasta: {[f['name'] for f in res2.get('files', [])]}")
        sys.exit(1)

    logging.info(f"Planilha: {sheet_file['name']}")

    # 3. Preenche
    sh = gc.open_by_key(sheet_file["id"])
    ws = sh.worksheets()[0]
    ws.clear()
    # Formata coluna A como texto para CPF não receber apóstrofo
    ws.format("A:A", {"numberFormat": {"type": "TEXT"}})
    ws.update(linhas, "A1", value_input_option="USER_ENTERED")

    link = f"https://docs.google.com/spreadsheets/d/{sheet_file['id']}"
    logging.info(f"✅ Planilha preenchida: {len(linhas)} linhas")
    print(f"PERFORMANCE_PGTO_LINK={link}")


if __name__ == "__main__":
    main()
