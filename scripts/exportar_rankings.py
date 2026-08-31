"""
Exporta os 4 rankings do BQ para Google Sheets no Drive.
Cria automaticamente a pasta da semana em "Performance" e uma planilha por ranking.

Uso:
  python exportar_rankings.py                        # período atual calculado
  python exportar_rankings.py --inicio 2026-05-08    # período específico
"""
import argparse
import logging
import os
import sys
import time
from datetime import date, timedelta

from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
load_dotenv()

BASE_DIR    = os.path.dirname(os.path.abspath(__file__))
TOKEN_PATH  = os.getenv("SHEETS_TOKEN_PATH") or os.getenv("TOKEN_PATH") or os.path.join(BASE_DIR, "sheets_token.json")
PROJECT_ID  = os.getenv("PROJECT_ID", "shopper-datalakehouse-qa")
CREDENTIALS = os.getenv("CREDENTIALS")

# Pasta raiz "Performance" no Drive
DRIVE_PERFORMANCE_FOLDER_ID = "16-DR4Yo_yNujhMzXWyDxwJ68s4f352cB"


def periodo_atual() -> tuple[date, date]:
    from datetime import datetime
    hoje = date.today()
    dow = hoje.weekday()  # 0=seg … 6=dom
    dias_ate_sexta = (dow - 4) % 7
    sexta = hoje - timedelta(days=dias_ate_sexta)
    quinta = sexta + timedelta(days=6)
    return sexta, quinta


def get_clients():
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    from googleapiclient.discovery import build
    import gspread

    creds = Credentials.from_authorized_user_file(TOKEN_PATH, scopes=[
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.readonly",
    ])
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())

    drive  = build("drive", "v3", credentials=creds)
    sheets = build("sheets", "v4", credentials=creds)
    gc     = gspread.authorize(creds)
    return drive, sheets, gc, creds


def criar_ou_buscar_pasta(drive, nome: str, parent_id: str) -> str:
    """Cria pasta no Drive (ou retorna ID se já existir)."""
    res = drive.files().list(
        q=f"name='{nome}' and '{parent_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false",
        fields="files(id,name)"
    ).execute()
    if res["files"]:
        fid = res["files"][0]["id"]
        logging.info(f"Pasta já existe: '{nome}' ({fid})")
        return fid
    meta = {
        "name": nome,
        "mimeType": "application/vnd.google-apps.folder",
        "parents": [parent_id],
    }
    f = drive.files().create(body=meta, fields="id").execute()
    logging.info(f"Pasta criada: '{nome}' ({f['id']})")
    return f["id"]


def criar_planilha(drive, gc, nome: str, folder_id: str) -> object:
    """Cria Google Sheet na pasta e retorna o worksheet."""
    # Verifica se já existe
    res = drive.files().list(
        q=f"name='{nome}' and '{folder_id}' in parents and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false",
        fields="files(id,name)"
    ).execute()
    if res["files"]:
        sid = res["files"][0]["id"]
        logging.info(f"Planilha já existe: '{nome}' ({sid}) — sobrescrevendo")
        sh = gc.open_by_key(sid)
        ws = sh.worksheets()[0]
        ws.clear()
        return ws

    meta = {
        "name": nome,
        "mimeType": "application/vnd.google-apps.spreadsheet",
        "parents": [folder_id],
    }
    f = drive.files().create(body=meta, fields="id").execute()
    logging.info(f"Planilha criada: '{nome}' ({f['id']})")
    sh = gc.open_by_key(f["id"])
    return sh.worksheets()[0]


def _fmt(v):
    """Converte valor do BQ para tipo adequado ao Sheets.
    Números ficam como números (float arredondado a 2 casas ou int),
    datas viram string DD/MM/YYYY, o resto vira str.
    """
    import datetime
    from decimal import Decimal
    if v is None:
        return ""
    if isinstance(v, bool):
        return str(v)
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return round(v, 2)
    if isinstance(v, Decimal):
        return float(round(v, 2))
    if isinstance(v, datetime.datetime):
        return v.strftime("%d/%m/%Y %H:%M:%S")
    if isinstance(v, datetime.date):
        return v.strftime("%d/%m/%Y")
    return str(v)


def query_bq(data_inicio: date, query: str) -> tuple[list, list]:
    """Executa query no BQ e retorna (header, rows)."""
    from google.oauth2 import service_account
    from google.cloud import bigquery

    creds_bq = service_account.Credentials.from_service_account_file(CREDENTIALS)
    bq = bigquery.Client(project=PROJECT_ID, credentials=creds_bq)
    result = bq.query(query).result()
    header = [f.name for f in result.schema]
    rows = []
    for row in result:
        rows.append([_fmt(v) for v in row.values()])
    logging.info(f"Query retornou {len(rows)} linhas")
    return header, rows


def escrever_sheet(ws, header: list, rows: list):
    """Escreve header + dados na planilha em lotes."""
    todas = [header] + rows
    lote = 5000
    if len(todas) <= lote:
        ws.update(todas, value_input_option="RAW")
    else:
        ws.update(todas[:lote], value_input_option="RAW")
        time.sleep(1)
        for i in range(lote, len(todas), lote):
            ws.append_rows(todas[i:i + lote], value_input_option="RAW")
            time.sleep(1)
    logging.info(f"Planilha preenchida: {len(rows)} linhas de dados")


def exportar(data_inicio: date, data_fim: date, sufixo: str = ""):
    drive, sheets_svc, gc, _ = get_clients()

    nome_pasta = f"Performance {data_inicio.day:02d}/{data_inicio.month:02d} a {data_fim.day:02d}/{data_fim.month:02d}{sufixo}"
    folder_id  = criar_ou_buscar_pasta(drive, nome_pasta, DRIVE_PERFORMANCE_FOLDER_ID)

    di = data_inicio.isoformat()
    df = data_fim.isoformat()
    ini_fmt = f"{data_inicio.day:02d}/{data_inicio.month:02d}"
    fim_fmt = f"{data_fim.day:02d}/{data_fim.month:02d}"

    rankings = [
        {
            "nome": f"Ranking {ini_fmt}",
            "query": f"""
                SELECT * FROM `{PROJECT_ID}.Ranking_Performance.Ranking Semanal`
                WHERE data_inicio_periodo = '{di}'
                ORDER BY fc, turno, posicao_ranking_fc
            """,
        },
        {
            "nome": f"Fiscais {ini_fmt} a {fim_fmt}",
            "query": f"""
                SELECT * FROM `{PROJECT_ID}.Ranking_Performance.Performance Fiscais`
                WHERE data_inicio_periodo = '{di}'
                ORDER BY fc, turno, nome_fiscal
            """,
        },
        {
            "nome": f"Não Mensuráveis {ini_fmt} a {fim_fmt}",
            "query": f"""
                SELECT * FROM `{PROJECT_ID}.Ranking_Performance.Performance Colaboradores Nao Mediveis`
                WHERE data_inicio_periodo = '{di}'
                ORDER BY fc, turno, nome
            """,
        },
        {
            "nome": f"Supervisores {ini_fmt} a {fim_fmt}",
            "query": f"""
                SELECT * FROM `{PROJECT_ID}.Ranking_Performance.Performance Supervisores`
                WHERE data_inicio_periodo = '{di}'
                ORDER BY FC, turno, nome_supervisor
            """,
        },
    ]

    links = []
    for r in rankings:
        logging.info(f"Exportando: {r['nome']}")
        header, rows = query_bq(data_inicio, r["query"])
        ws = criar_planilha(drive, gc, r["nome"], folder_id)
        escrever_sheet(ws, header, rows)
        link = f"https://docs.google.com/spreadsheets/d/{ws.spreadsheet.id}"
        links.append((r["nome"], link))
        logging.info(f"  ✅ {r['nome']}: {link}")
        time.sleep(2)

    logging.info(f"\n✅ Exportação concluída — pasta: {nome_pasta}")
    for nome, link in links:
        print(f"SHEET_LINK={nome}|{link}")

    folder_link = f"https://drive.google.com/drive/folders/{folder_id}"
    print(f"FOLDER_LINK={folder_link}")
    return folder_id


def main():
    parser = argparse.ArgumentParser(description="Exporta rankings BQ → Google Sheets")
    parser.add_argument("--inicio", help="Data de início (YYYY-MM-DD)", default=None)
    parser.add_argument("--sufixo", help="Sufixo para o nome da pasta (ex: ' [TESTE]')", default="")
    args = parser.parse_args()

    if args.inicio:
        data_inicio = date.fromisoformat(args.inicio)
        data_fim    = data_inicio + timedelta(days=6)
    else:
        data_inicio, data_fim = periodo_atual()

    logging.info(f"Período: {data_inicio} → {data_fim}")
    exportar(data_inicio, data_fim, sufixo=args.sufixo)


if __name__ == "__main__":
    main()
