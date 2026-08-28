"""
Lê os dados de bônus recompensa do BQ e cria/atualiza a planilha
"Bonus Recompensa DD/MM a DD/MM" na pasta Performance do Drive.

Uso:
  python subir_bonus_planilha.py                      # período atual automático
  python subir_bonus_planilha.py --inicio 2026-05-08  # período específico
"""
import argparse
import logging
import os
import sys
import io
import time
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

PROJECT_ID   = os.getenv("PROJECT_ID", "shopper-datalakehouse-qa")
CREDENTIALS  = os.getenv("CREDENTIALS")
TOKEN_PATH   = os.getenv("SHEETS_TOKEN_PATH") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "sheets_token.json")
DRIVE_PERFORMANCE_FOLDER_ID = "1wz6cDH-WFbhb9Icf0NHG5gnGhDu_W2lM"

DATASET = "Ranking_Performance"
TABLE_OP  = f"{PROJECT_ID}.{DATASET}.Tabela_Base_Feedback_Operacional"
TABLE_FIS = f"{PROJECT_ID}.{DATASET}.Tabela_Base_Feedback_Fiscais"
TABLE_SUP = f"{PROJECT_ID}.{DATASET}.Tabela_Base_Feedback_Supervisores"


def periodo_atual() -> tuple:
    hoje = date.today()
    dow = hoje.weekday()
    sexta = hoje - timedelta(days=(dow - 4) % 7)
    quinta = sexta + timedelta(days=6)
    return sexta, quinta


def get_drive_clients():
    creds = Credentials.from_authorized_user_file(TOKEN_PATH, scopes=[
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.readonly",
    ])
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
    drive = build("drive", "v3", credentials=creds)
    gc    = gspread.authorize(creds)
    return drive, gc


def get_bq_client():
    key_file = CREDENTIALS or os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
    if key_file:
        creds, _ = load_credentials_from_file(
            key_file, scopes=["https://www.googleapis.com/auth/bigquery"]
        )
        return bigquery.Client(project=PROJECT_ID, credentials=creds)
    return bigquery.Client(project=PROJECT_ID)


def buscar_pasta_semana(drive, data_inicio: date, data_fim: date) -> str:
    """Localiza a pasta da semana no Drive.

    Tenta vários padrões de nome:
      - 'Performance DD/MM a DD/MM'  (formato antigo)
      - 'Semana NN'                  (formato com número ISO)
      - dia do início e dia do fim presentes no nome (ex: 'Semana 32 - 07-13/ago')
    """
    semana_iso = data_inicio.isocalendar()[1]
    ini_fmt = f"{data_inicio.day:02d}/{data_inicio.month:02d}"
    fim_fmt = f"{data_fim.day:02d}/{data_fim.month:02d}"
    ini_dia = f"{data_inicio.day:02d}"
    fim_dia = f"{data_fim.day:02d}"

    res = drive.files().list(
        q=(
            f"'{DRIVE_PERFORMANCE_FOLDER_ID}' in parents "
            f"and mimeType='application/vnd.google-apps.folder' "
            f"and trashed=false"
        ),
        fields="files(id,name)"
    ).execute()

    candidatos = res.get("files", [])

    # 1) formato exato DD/MM
    for f in candidatos:
        if ini_fmt in f["name"] and fim_fmt in f["name"]:
            logging.info(f"Pasta encontrada (DD/MM): {f['name']} ({f['id']})")
            return f["id"]

    # 2) número da semana ISO
    for f in candidatos:
        nome = f["name"]
        if f"Semana {semana_iso}" in nome or f"Semana {semana_iso:02d}" in nome:
            logging.info(f"Pasta encontrada (semana ISO {semana_iso}): {nome} ({f['id']})")
            return f["id"]

    # 3) dia de início e dia de fim presentes no nome (ex: '07-13/ago')
    for f in candidatos:
        nome = f["name"]
        if ini_dia in nome and fim_dia in nome:
            logging.info(f"Pasta encontrada (dias {ini_dia}/{fim_dia}): {nome} ({f['id']})")
            return f["id"]

    logging.error(
        f"Pasta da semana {semana_iso} ({data_inicio} a {data_fim}) não encontrada. "
        f"Pastas disponíveis: {[f['name'] for f in candidatos]}"
    )
    sys.exit(1)


def criar_ou_abrir_planilha(drive, gc, nome: str, folder_id: str):
    res = drive.files().list(
        q=(
            f"name='{nome}' and '{folder_id}' in parents "
            f"and mimeType='application/vnd.google-apps.spreadsheet' "
            f"and trashed=false"
        ),
        fields="files(id,name)"
    ).execute()

    if res["files"]:
        sid = res["files"][0]["id"]
        logging.info(f"Planilha já existe: '{nome}' ({sid}) — sobrescrevendo")
        sh = gc.open_by_key(sid)
        ws = sh.worksheets()[0]
        ws.clear()
        return ws, sid

    meta = {
        "name": nome,
        "mimeType": "application/vnd.google-apps.spreadsheet",
        "parents": [folder_id],
    }
    f = drive.files().create(body=meta, fields="id").execute()
    logging.info(f"Planilha criada: '{nome}' ({f['id']})")
    sh = gc.open_by_key(f["id"])
    return sh.worksheets()[0], f["id"]


def buscar_bonus(bq, data_inicio: date) -> list:
    """Retorna lista de dicts com dados de bônus por matrícula e critério."""
    di = data_inicio.isoformat()

    sql = f"""
    WITH bonus AS (
      SELECT
        CAST(MATRICULA AS STRING) AS MATRICULA,
        NOME,
        TURNO,
        setor,
        atribuicao,
        'Boa Evolucao'   AS CRITERIO,
        50               AS VALOR_BONUS
      FROM `{TABLE_OP}`
      WHERE boa_evolucao = TRUE AND data_inicio = '{di}'

      UNION ALL

      SELECT CAST(MATRICULA AS STRING), NOME, TURNO, setor, atribuicao,
             'Top 1 Setor', 50
      FROM `{TABLE_OP}`
      WHERE top_1_setor = TRUE AND data_inicio = '{di}'

      UNION ALL

      SELECT CAST(MATRICULA AS STRING), NOME, TURNO, setor, atribuicao,
             'Bom Comeco', 50
      FROM `{TABLE_OP}`
      WHERE bom_comeco = TRUE AND data_inicio = '{di}'

      UNION ALL

      SELECT CAST(MATRICULA AS STRING), NOME, TURNO, setor, atribuicao,
             'Reforco Operacao - Operacional', 50
      FROM `{TABLE_OP}`
      WHERE reforco_operacao = TRUE AND data_inicio = '{di}'

      UNION ALL

      SELECT CAST(MATRICULA AS STRING), NOME, TURNO, setor, atribuicao,
             'Reforco Operacao - Fiscal', 50
      FROM `{TABLE_FIS}`
      WHERE reforco_operacao = TRUE AND data_inicio = '{di}'

      UNION ALL

      SELECT CAST(MATRICULA AS STRING), NOME, TURNO, setor, atribuicao,
             'Reforco Operacao - Supervisor', 50
      FROM `{TABLE_SUP}`
      WHERE reforco_operacao = TRUE AND data_inicio = '{di}'
    )
    SELECT
      MATRICULA,
      COALESCE(NOME, '') AS NOME,
      COALESCE(TURNO, '') AS TURNO,
      COALESCE(setor, '') AS SETOR,
      COALESCE(atribuicao, '') AS CARGO,
      CRITERIO,
      VALOR_BONUS
    FROM bonus
    ORDER BY CRITERIO, NOME
    """

    rows = list(bq.query(sql).result())
    logging.info(f"Registros de bônus: {len(rows)}")
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inicio", default=None)
    args = parser.parse_args()

    if args.inicio:
        data_inicio = date.fromisoformat(args.inicio)
        data_fim    = data_inicio + timedelta(days=6)
    else:
        data_inicio, data_fim = periodo_atual()

    semana_iso = data_inicio.isocalendar()[1]
    ano = data_inicio.year
    logging.info(f"Período: {data_inicio} a {data_fim} | Semana {semana_iso}/{ano}")

    bq          = get_bq_client()
    drive, gc   = get_drive_clients()

    folder_id = buscar_pasta_semana(drive, data_inicio, data_fim)

    rows = buscar_bonus(bq, data_inicio)
    if not rows:
        logging.warning("Nenhum bônus encontrado para o período. Encerrando.")
        sys.exit(0)

    nome_planilha = f"[Bonus Recompensa][{ano}][Semana {semana_iso}]"
    ws, sheet_id = criar_ou_abrir_planilha(drive, gc, nome_planilha, folder_id)

    header = ["MATRICULA", "NOME", "TURNO", "SETOR", "CARGO", "CRITERIO", "VALOR_BONUS"]
    dados  = [
        [r.MATRICULA, r.NOME, r.TURNO, r.SETOR, r.CARGO, r.CRITERIO, r.VALOR_BONUS]
        for r in rows
    ]

    todas = [header] + dados
    lote  = 5000
    if len(todas) <= lote:
        ws.update(todas, value_input_option="RAW")
    else:
        ws.update(todas[:lote], value_input_option="RAW")
        for i in range(lote, len(todas), lote):
            time.sleep(1)
            ws.append_rows(todas[i:i + lote], value_input_option="RAW")

    link = f"https://docs.google.com/spreadsheets/d/{sheet_id}"
    logging.info(f"✅ Planilha de bônus preenchida: {len(dados)} linhas")
    print(f"BONUS_PLANILHA_LINK={link}")


if __name__ == "__main__":
    main()
