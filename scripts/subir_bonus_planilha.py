"""
Sobe planilha [Bonus Recompensa][YYYY][Semana XX] no Drive com CPF + valor.
Uso:
  python subir_bonus_planilha.py --inicio 2026-08-21
"""
import argparse
import os
import sys
from datetime import date, timedelta

from dotenv import load_dotenv

load_dotenv()

PROJECT_ID  = os.environ["PROJECT_ID"]
CREDENTIALS = os.environ.get("CREDENTIALS") or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
TOKEN_PATH  = os.environ.get("SHEETS_TOKEN_PATH") or os.environ.get("TOKEN_PATH")
FOLDER_ID   = os.environ.get("DRIVE_PAGAMENTO_FOLDER_ID", "1wz6cDH-WFbhb9Icf0NHG5gnGhDu_W2lM")


def _ultima_semana_fechada():
    hoje = date.today()
    dias_ate_sexta = (hoje.weekday() - 4) % 7
    ultima_sexta = hoje - timedelta(days=dias_ate_sexta)
    inicio = ultima_sexta - timedelta(weeks=1)
    return inicio


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inicio", help="Data de início (YYYY-MM-DD)", default=None)
    args = parser.parse_args()

    if args.inicio:
        data_inicio = date.fromisoformat(args.inicio)
    else:
        data_inicio = _ultima_semana_fechada()

    semana_iso = data_inicio.isocalendar()[1]
    ano = data_inicio.year
    data_inicio_str = data_inicio.isoformat()

    print(f"Período: {data_inicio_str} | Semana ISO: {semana_iso}")

    from google.oauth2 import service_account
    from google.cloud import bigquery
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    from googleapiclient.discovery import build
    import gspread

    creds_bq = service_account.Credentials.from_service_account_file(
        CREDENTIALS, scopes=["https://www.googleapis.com/auth/bigquery"])
    client = bigquery.Client(project=PROJECT_ID, credentials=creds_bq)

    rows = list(client.query(f"""
        SELECT cpf, CAST(bonus_recompensa AS FLOAT64) AS valor
        FROM `{PROJECT_ID}.Ranking_Performance.carteira_operação`
        WHERE data_inicio_ranking = '{data_inicio_str}'
          AND CAST(bonus_recompensa AS FLOAT64) > 0
          AND cpf IS NOT NULL
        ORDER BY cpf
    """).result())

    print(f"Registros com bônus: {len(rows)}")
    if not rows:
        print("Nenhum registro encontrado — abortando")
        sys.exit(1)

    linhas = [["cpf", "valor"]]
    for r in rows:
        linhas.append([str(r.cpf).strip().zfill(11), f"{float(r.valor):.2f}".replace(".", ",")])

    creds_oauth = Credentials.from_authorized_user_file(TOKEN_PATH, scopes=[
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.readonly",
    ])
    if creds_oauth.expired and creds_oauth.refresh_token:
        creds_oauth.refresh(Request())

    drive = build("drive", "v3", credentials=creds_oauth)
    gc = gspread.authorize(creds_oauth)

    # Buscar pasta da semana com paginação
    candidatos = []
    page_token = None
    while True:
        res = drive.files().list(
            q=f"'{FOLDER_ID}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false",
            fields="nextPageToken, files(id,name)",
            pageToken=page_token
        ).execute()
        candidatos.extend(res.get("files", []))
        page_token = res.get("nextPageToken")
        if not page_token:
            break

    pasta = next((f for f in candidatos if f"Semana {semana_iso}" in f["name"]), None)
    if not pasta:
        print(f"Pasta Semana {semana_iso} não encontrada em {len(candidatos)} subpastas")
        sys.exit(1)
    print(f"Pasta: {pasta['name']}")

    nome = f"[Bonus Recompensa][{ano}][Semana {semana_iso}]"
    res2 = drive.files().list(
        q=f"name='{nome}' and '{pasta['id']}' in parents and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false",
        fields="files(id,name)"
    ).execute()

    if res2["files"]:
        sid = res2["files"][0]["id"]
        sh = gc.open_by_key(sid)
        print("Planilha já existe — sobrescrevendo")
    else:
        f = drive.files().create(
            body={"name": nome, "mimeType": "application/vnd.google-apps.spreadsheet", "parents": [pasta["id"]]},
            fields="id"
        ).execute()
        sid = f["id"]
        sh = gc.open_by_key(sid)
        print(f"Planilha criada: {nome}")

    ws = sh.worksheets()[0]
    ws.clear()
    ws.format("A:A", {"numberFormat": {"type": "TEXT"}})
    ws.update(linhas, "A1", value_input_option="USER_ENTERED")
    print(f"OK: {len(linhas) - 1} linhas escritas")
    print(f"LINK=https://docs.google.com/spreadsheets/d/{sid}")


if __name__ == "__main__":
    main()
