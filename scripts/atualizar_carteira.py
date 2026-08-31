"""
Atualiza a tabela carteira_operação no BigQuery combinando:
  - Saldo anterior: saldo_pos_bonificacao da semana anterior em carteira_operação (BQ)
  - Bonificação:    tabelas BQ de performance (Ranking Semanal + Fiscais + Supervisores + Não Mensuráveis)
  - Recompensas:    R$50 por critério lido do PDF de bônus (--recompensas-pdf)

Uso:
  python atualizar_carteira.py                                         # período atual
  python atualizar_carteira.py --inicio 2026-05-01                    # período específico
  python atualizar_carteira.py --dry-run                               # sem gravar no BQ
  python atualizar_carteira.py --recompensas-pdf relatorio.pdf        # com bônus de recompensa
  python atualizar_carteira.py --recompensas-pdf <drive_file_id>      # baixa do Drive
"""
import argparse
import logging
import os
import sys
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation

from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
load_dotenv()

BASE_DIR      = os.path.dirname(os.path.abspath(__file__))
TOKEN_PATH    = os.getenv("SHEETS_TOKEN_PATH") or os.getenv("TOKEN_PATH") or os.path.join(BASE_DIR, "sheets_token.json")
PROJECT_ID    = os.getenv("PROJECT_ID", "shopper-datalakehouse-qa")
CREDENTIALS   = os.getenv("CREDENTIALS")

BQ_TABLE            = f"{PROJECT_ID}.Ranking_Performance.carteira_operação"
DRIVE_PAGAMENTO_ID  = os.getenv("DRIVE_PAGAMENTO_FOLDER_ID", "1wz6cDH-WFbhb9Icf0NHG5gnGhDu_W2lM")


# ---------------------------------------------------------------------------
# Utilitários de data
# ---------------------------------------------------------------------------

def periodo_atual() -> tuple[date, date]:
    """
    Retorna o período sexta-quinta da semana de performance mais recente.
    Regra: se hoje é sex/sáb/dom/seg/ter, usa a semana anterior (sex→qui).
            se hoje é qua/qui, usa o período atual (ainda aberto).
    """
    hoje = date.today()
    dow = hoje.weekday()   # 0=seg … 6=dom
    # sexta = 4
    dias_ate_sexta = (dow - 4) % 7
    sexta = hoje - timedelta(days=dias_ate_sexta)
    quinta = sexta + timedelta(days=6)
    # sex(4)/sáb(5)/dom(6)/seg(0)/ter(1) → período anterior (já fechado)
    if dow in (0, 1, 4, 5, 6):
        sexta -= timedelta(days=7)
        quinta -= timedelta(days=7)
    return sexta, quinta


# ---------------------------------------------------------------------------
# Leitura do saldo da semana anterior no BigQuery
# ---------------------------------------------------------------------------

def ler_saldos_bq(data_inicio: date) -> dict:
    """
    Lê saldo_pos_bonificacao do período imediatamente anterior em carteira_operação.
    Retorna {matricula_str: Decimal(saldo)}.
    """
    from google.oauth2 import service_account
    from google.cloud import bigquery

    creds_bq = service_account.Credentials.from_service_account_file(CREDENTIALS)
    bq = bigquery.Client(project=PROJECT_ID, credentials=creds_bq)

    query = f"""
    SELECT matricula, CAST(saldo_pos_bonificacao AS NUMERIC) AS saldo
    FROM `{BQ_TABLE}`
    WHERE data_inicio_ranking = (
      SELECT MAX(data_inicio_ranking)
      FROM `{BQ_TABLE}`
      WHERE data_inicio_ranking < '{data_inicio}'
    )
    """

    rows = list(bq.query(query).result())
    saldos = {}
    for r in rows:
        try:
            saldos[str(r.matricula)] = Decimal(str(r.saldo or "0"))
        except InvalidOperation:
            saldos[str(r.matricula)] = Decimal("0")

    logging.info(f"Saldos carregados: {len(saldos)} matrículas do BQ (período anterior a {data_inicio})")
    return saldos


# ---------------------------------------------------------------------------
# Leitura das recompensas (R$50/critério) a partir do PDF de bônus
# ---------------------------------------------------------------------------

def _normalizar(texto: str) -> str:
    import unicodedata
    return unicodedata.normalize("NFD", texto).encode("ascii", "ignore").decode().lower()


def _baixar_pdf_drive(file_id: str) -> str:
    """Baixa PDF do Google Drive para arquivo temporário; retorna caminho local."""
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaIoBaseDownload
    import tempfile

    creds = Credentials.from_authorized_user_file(TOKEN_PATH, scopes=[
        "https://www.googleapis.com/auth/drive.readonly",
    ])
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())

    drive = build("drive", "v3", credentials=creds)
    request = drive.files().get_media(fileId=file_id)

    tmp = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
    downloader = MediaIoBaseDownload(tmp, request)
    done = False
    while not done:
        _, done = downloader.next_chunk()
    tmp.close()

    logging.info(f"PDF baixado do Drive ({file_id}) → {tmp.name}")
    return tmp.name


def ler_recompensas_pdf(pdf_source: str) -> dict:
    """
    Lê o PDF de bônus e retorna {matricula_str: Decimal(bonus_recompensa)}.
    R$50 por critério por colaborador (uma matrícula pode aparecer em múltiplos critérios).
    pdf_source: caminho local ou file_id do Google Drive.
    """
    import re
    import pdfplumber

    if not os.path.exists(pdf_source):
        pdf_source = _baixar_pdf_drive(pdf_source)

    CRITERIOS = ["Boa Evolucao", "Top 1 Setor", "Bom Comeco", "Reforco Operacao"]
    BONUS = Decimal("50")

    texto = ""
    with pdfplumber.open(pdf_source) as pdf:
        for page in pdf.pages:
            texto += (page.extract_text() or "") + "\n"

    recompensas: dict = {}
    criterio_atual = None

    for linha in texto.splitlines():
        linha = linha.strip()
        if not linha:
            continue

        linha_norm = _normalizar(linha)

        # Detecta cabeçalho de seção — dois formatos suportados:
        #   Antigo: "<criterio> [...] - N colaboradores"
        #   Novo:   "N. <criterio>" (ex: "1. Boa Evolucao", "2. Top 1 Setor")
        novo_criterio = None
        for crit in CRITERIOS:
            crit_norm = _normalizar(crit)
            if crit_norm in linha_norm and ("colaboradores" in linha_norm or re.match(r"^\d+\.", linha)):
                novo_criterio = crit
                break
        if novo_criterio:
            criterio_atual = novo_criterio
            continue

        # Linha de matrícula — dois formatos:
        #   Antigo: "<matricula(3-6)> NOME ..."
        #   Novo:   "<pos(1-3)> <matricula(3-6)> NOME ..."
        if criterio_atual:
            # Novo formato: posição + matrícula + nome em maiúsculas
            m = re.match(r"^\d{1,3}\s+(\d{3,6})\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ]", linha)
            if not m:
                # Formato antigo
                m2 = re.match(r"^(\d{3,6})\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ]", linha)
                if m2:
                    m = type('M', (), {'group': lambda self, n: m2.group(n)})()
                    m.group = m2.group
            if m:
                mat = m.group(1)
                recompensas[mat] = recompensas.get(mat, Decimal("0")) + BONUS

    total = sum(recompensas.values())
    logging.info(f"Recompensas: {len(recompensas)} matrículas, R$ {total} total")
    return recompensas


# ---------------------------------------------------------------------------
# Leitura das bonificações nas tabelas BQ
# ---------------------------------------------------------------------------

def ler_bonificacoes_bq(data_inicio: date) -> list[dict]:
    """
    Consulta os 4 rankings no BQ e retorna lista de:
      {matricula: str, nome: str, bonificacao: Decimal}
    Matrículas duplicadas (pessoa em mais de um ranking) têm bonificação somada.
    """
    from google.oauth2 import service_account
    from google.cloud import bigquery

    creds_bq = service_account.Credentials.from_service_account_file(CREDENTIALS)
    bq = bigquery.Client(project=PROJECT_ID, credentials=creds_bq)

    query = f"""
    WITH todas AS (

      -- Colaboradores mensuráveis
      SELECT
        CAST(rs.MATRICULA AS STRING) AS matricula,
        du.nome,
        COALESCE(rs.valor_bonificacao, 0) AS bonificacao
      FROM `{PROJECT_ID}.Ranking_Performance.Ranking Semanal` rs
      LEFT JOIN `{PROJECT_ID}.Ranking_Performance.Dados Usuários` du
        ON CAST(du.matricula AS STRING) = CAST(rs.MATRICULA AS STRING)
      WHERE rs.data_inicio_periodo = '{data_inicio}'

      UNION ALL

      -- Fiscais
      SELECT
        CAST(matricula_fiscal AS STRING),
        nome_fiscal,
        COALESCE(valor_bonificacao_fiscal, 0)
      FROM `{PROJECT_ID}.Ranking_Performance.Performance Fiscais`
      WHERE data_inicio_periodo = '{data_inicio}'

      UNION ALL

      -- Supervisores
      SELECT
        CAST(matricula_supervisor AS STRING),
        nome_supervisor,
        COALESCE(valor_bonificacao_supervisor, 0)
      FROM `{PROJECT_ID}.Ranking_Performance.Performance Supervisores`
      WHERE data_inicio_periodo = '{data_inicio}'

      UNION ALL

      -- Não mensuráveis
      SELECT
        CAST(matricula AS STRING),
        nome,
        COALESCE(valor_bonificacao, 0)
      FROM `{PROJECT_ID}.Ranking_Performance.Performance Colaboradores Nao Mediveis`
      WHERE data_inicio_periodo = '{data_inicio}'

    )
    SELECT
      matricula,
      MAX(nome) AS nome,
      SUM(bonificacao) AS bonificacao
    FROM todas
    GROUP BY matricula
    ORDER BY matricula
    """

    rows = list(bq.query(query).result())
    resultado = [
        {
            "matricula": str(r.matricula),
            "nome":      r.nome or "",
            "bonificacao": Decimal(str(round(float(r.bonificacao or 0), 2))),
        }
        for r in rows
    ]
    logging.info(f"Bonificações carregadas: {len(resultado)} matrículas dos rankings BQ")
    return resultado


# ---------------------------------------------------------------------------
# Gravação no BigQuery
# ---------------------------------------------------------------------------

def gravar_bq(registros: list[dict], data_inicio: date) -> None:
    from google.oauth2 import service_account
    from google.cloud import bigquery

    creds_bq = service_account.Credentials.from_service_account_file(CREDENTIALS)
    bq = bigquery.Client(project=PROJECT_ID, credentials=creds_bq)

    # Remove registros do mesmo período para evitar duplicatas
    delete_sql = f"""
    DELETE FROM `{BQ_TABLE}`
    WHERE data_inicio_ranking = '{data_inicio}'
    """
    bq.query(delete_sql).result()
    logging.info(f"Registros anteriores do período {data_inicio} removidos")

    # Load job (evita o problema do streaming buffer que bloqueia UPDATE/DELETE por 90 min)
    import json, tempfile
    schema = [
        bigquery.SchemaField("matricula",            "STRING"),
        bigquery.SchemaField("nome",                 "STRING"),
        bigquery.SchemaField("cpf",                  "STRING"),
        bigquery.SchemaField("saldo",                "NUMERIC"),
        bigquery.SchemaField("bonificacao_atual",    "NUMERIC"),
        bigquery.SchemaField("saldo_pos_bonificacao","NUMERIC"),
        bigquery.SchemaField("valor_a_pagar",        "NUMERIC"),
        bigquery.SchemaField("data_inicio_ranking",  "DATE"),
        bigquery.SchemaField("report_at",            "TIMESTAMP"),
        bigquery.SchemaField("update_at",            "TIMESTAMP"),
        bigquery.SchemaField("bonus_recompensa",     "NUMERIC"),
    ]
    job_config = bigquery.LoadJobConfig(
        schema=schema,
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
    )
    with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False, encoding="utf-8") as f:
        for r in registros:
            f.write(json.dumps(r) + "\n")
        tmp_path = f.name

    with open(tmp_path, "rb") as f:
        job = bq.load_table_from_file(f, BQ_TABLE, job_config=job_config)
    job.result()

    if job.errors:
        logging.error(f"Erros no load job: {job.errors}")
        sys.exit(1)

    logging.info(f"✅ {len(registros)} registros gravados em {BQ_TABLE}")

    # Preenche CPF a partir de Dados Usuários
    bq.query(f"""
        UPDATE `{BQ_TABLE}` c
        SET c.cpf = du.dados, c.update_at = CURRENT_TIMESTAMP()
        FROM `{PROJECT_ID}.Ranking_Performance.Dados Usuários` du
        WHERE c.matricula = CAST(du.matricula AS STRING)
          AND c.data_inicio_ranking = '{data_inicio}'
    """).result()
    logging.info("CPF preenchido a partir de Dados Usuários")


# ---------------------------------------------------------------------------
# Upload planilha de pagamento de performance no Drive
# ---------------------------------------------------------------------------

def upload_planilha_pagamento(data_inicio: date, excluir_setores: list[str] | None = None) -> str | None:
    """
    Lê cpf + valor_a_pagar direto do BQ (após CPF já ter sido preenchido)
    e preenche a planilha [Performance][Operação] no Drive.
    Retorna o link da planilha ou None se não encontrar.
    excluir_setores: lista de setor_principal (case-insensitive) a excluir do pagamento.
    """
    from google.oauth2 import service_account
    from google.cloud import bigquery
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    from googleapiclient.discovery import build
    import gspread

    # Lê do BQ — CPF já preenchido pelo UPDATE feito em gravar_bq
    creds_bq = service_account.Credentials.from_service_account_file(CREDENTIALS)
    bq = bigquery.Client(project=PROJECT_ID, credentials=creds_bq)

    if excluir_setores:
        setores_upper = [s.upper() for s in excluir_setores]
        setores_list  = ", ".join(f"'{s}'" for s in setores_upper)
        query_pgto = f"""
            SELECT c.cpf, CAST(c.valor_a_pagar AS FLOAT64) AS valor
            FROM `{BQ_TABLE}` c
            LEFT JOIN `{PROJECT_ID}.Ranking_Performance.Ranking Semanal` rs
              ON CAST(rs.MATRICULA AS STRING) = c.matricula
              AND rs.data_inicio_periodo = '{data_inicio}'
            WHERE c.data_inicio_ranking = '{data_inicio}'
              AND CAST(c.valor_a_pagar AS FLOAT64) > 0
              AND c.cpf IS NOT NULL
              AND NOT (UPPER(COALESCE(rs.setor_principal, '')) IN ({setores_list}))
            ORDER BY c.cpf
        """
    else:
        query_pgto = f"""
            SELECT cpf, CAST(valor_a_pagar AS FLOAT64) AS valor
            FROM `{BQ_TABLE}`
            WHERE data_inicio_ranking = '{data_inicio}'
              AND CAST(valor_a_pagar AS FLOAT64) > 0
              AND cpf IS NOT NULL
            ORDER BY cpf
        """

    rows_bq = list(bq.query(query_pgto).result())

    linhas = []
    for r in rows_bq:
        cpf_fmt   = str(r.cpf).strip().zfill(11)
        valor_fmt = f"{float(r.valor):.2f}".replace(".", ",")
        linhas.append([cpf_fmt, valor_fmt])

    if not linhas:
        logging.warning("Nenhum colaborador com valor_a_pagar > 0 e CPF no BQ")
        return None

    logging.info(f"{len(linhas)} linhas lidas do BQ para planilha de pagamento")

    # Autenticação OAuth
    creds = Credentials.from_authorized_user_file(TOKEN_PATH, scopes=[
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.readonly",
    ])
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())

    drive = build("drive", "v3", credentials=creds)
    gc    = gspread.authorize(creds)

    # Encontra subpasta da semana pelo número ISO
    semana_num = data_inicio.isocalendar()[1]
    prefixo    = f"Semana {semana_num:02d}"

    res = drive.files().list(
        q=f"'{DRIVE_PAGAMENTO_ID}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false",
        fields="files(id,name)"
    ).execute()

    pasta = next((f for f in res["files"] if f["name"].startswith(prefixo) or f"Semana {semana_num}" in f["name"]), None)
    if not pasta:
        logging.warning(f"Pasta '{prefixo}' não encontrada em Planilhas de Pagamento")
        return None

    # Encontra planilha [Performance][Operação] — exclui Assiduidade, Correção, Coordenadores
    res2 = drive.files().list(
        q=f"'{pasta['id']}' in parents and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false",
        fields="files(id,name)"
    ).execute()

    sheet_file = None
    for f in res2["files"]:
        n = f["name"].lower()
        # Precisa ter "opera" E não pode ter "assid", "corre", "coord"
        if ("opera" in n or "operação" in n) and not any(x in n for x in ["assid", "corre", "coord"]):
            sheet_file = f
            break

    if not sheet_file:
        logging.warning(f"Planilha [Performance][Operação] não encontrada em '{pasta['name']}'. Arquivos: {[f['name'] for f in res2['files']]}")
        return None

    logging.info(f"Planilha encontrada: {sheet_file['name']}")

    sh = gc.open_by_key(sheet_file["id"])
    ws = sh.worksheets()[0]
    ws.clear()
    ws.format("A:A", {"numberFormat": {"type": "TEXT"}})
    ws.update(linhas, "A1", value_input_option="USER_ENTERED")

    link = f"https://docs.google.com/spreadsheets/d/{sheet_file['id']}"
    logging.info(f"✅ Planilha de pagamento preenchida: {len(linhas)} linhas → {link}")
    return link


# ---------------------------------------------------------------------------
# Fluxo principal
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Atualiza carteira_operação com dados de performance")
    parser.add_argument("--inicio",         help="Data de início do período (YYYY-MM-DD)", default=None)
    parser.add_argument("--dry-run",        action="store_true", help="Mostra registros sem gravar no BQ")
    parser.add_argument("--recompensas-pdf", dest="recompensas_pdf",
                        help="Caminho local ou file_id do Drive para o PDF de bônus (R$50/critério)", default=None)
    parser.add_argument("--extra-bonif", dest="extra_bonif",
                        help="Bonificações extras: 'mat1:val1,mat2:val2' (ex: 11007:25,12854:107.9)", default=None)
    parser.add_argument("--excluir-setor", dest="excluir_setor",
                        help="Setores a excluir da planilha de pagamento (separados por vírgula)", default=None)
    args = parser.parse_args()

    if args.inicio:
        data_inicio = date.fromisoformat(args.inicio)
        data_fim    = data_inicio + timedelta(days=6)
    else:
        data_inicio, data_fim = periodo_atual()

    logging.info(f"Período: {data_inicio} → {data_fim}")

    # Pede o PDF de recompensas se não fornecido via argumento (apenas em terminal interativo)
    if not args.recompensas_pdf and sys.stdin.isatty():
        print(f"\n{'='*60}")
        print(f"Período de performance: {data_inicio} → {data_fim}")
        print(f"{'='*60}")
        print("Informe o caminho local do PDF de recompensas (ou pressione Enter para pular):")
        try:
            pdf_input = input("  PDF recompensas: ").strip()
        except EOFError:
            pdf_input = ""
        if pdf_input:
            args.recompensas_pdf = pdf_input
            logging.info(f"PDF informado: {args.recompensas_pdf}")
        else:
            logging.info("Nenhum PDF de recompensas informado — seguindo sem recompensas")
    elif not args.recompensas_pdf:
        logging.info("Modo não-interativo — seguindo sem PDF de recompensas (passe --recompensas-pdf se necessário)")

    # 1. Saldos do BQ (semana anterior)
    saldos = ler_saldos_bq(data_inicio)

    # 2. Bonificações do BQ
    colaboradores = ler_bonificacoes_bq(data_inicio)

    if not colaboradores:
        logging.warning(f"Nenhum colaborador encontrado nos rankings para {data_inicio}")
        sys.exit(0)

    # 3. Recompensas do PDF (R$50/critério), opcional
    recompensas: dict = {}
    if args.recompensas_pdf:
        recompensas = ler_recompensas_pdf(args.recompensas_pdf)

        # Inclui colaboradores que estão na recompensa mas ausentes no ranking
        matriculas_ranking = {str(c["matricula"]) for c in colaboradores}
        ausentes = [mat for mat in recompensas if mat not in matriculas_ranking]
        if ausentes:
            logging.info(f"{len(ausentes)} matrícula(s) nas recompensas sem linha no ranking — buscando nomes em Dados Usuários")
            from google.oauth2 import service_account
            from google.cloud import bigquery as _bq
            _creds = service_account.Credentials.from_service_account_file(CREDENTIALS)
            _client = _bq.Client(project=PROJECT_ID, credentials=_creds)
            lista_mats = ", ".join(f"'{m}'" for m in ausentes)
            _rows = list(_client.query(f"""
                SELECT CAST(matricula AS STRING) AS matricula, nome
                FROM `{PROJECT_ID}.Ranking_Performance.Dados Usuários`
                WHERE CAST(matricula AS STRING) IN ({lista_mats})
            """).result())
            nomes_ausentes = {r.matricula: r.nome or "" for r in _rows}
            for mat in ausentes:
                colaboradores.append({
                    "matricula": mat,
                    "nome":      nomes_ausentes.get(mat, ""),
                    "bonificacao": Decimal("0"),
                })
                logging.info(f"  + {mat} ({nomes_ausentes.get(mat, 'nome não encontrado')}) adicionado com bonificação 0")

    # 3b. Bonificações extras avulsas (--extra-bonif)
    if args.extra_bonif:
        from google.oauth2 import service_account
        from google.cloud import bigquery as _bq
        _creds = service_account.Credentials.from_service_account_file(CREDENTIALS)
        _client = _bq.Client(project=PROJECT_ID, credentials=_creds)
        extras: dict[str, Decimal] = {}
        for par in args.extra_bonif.split(","):
            mat, val = par.strip().split(":")
            extras[mat.strip()] = Decimal(val.strip().replace(",", "."))

        matriculas_existentes = {str(c["matricula"]) for c in colaboradores}
        mats_novos = [m for m in extras if m not in matriculas_existentes]
        if mats_novos:
            lista_mats = ", ".join(f"'{m}'" for m in mats_novos)
            _rows = list(_client.query(f"""
                SELECT CAST(matricula AS STRING) AS matricula, nome
                FROM `{PROJECT_ID}.Ranking_Performance.Dados Usuários`
                WHERE CAST(matricula AS STRING) IN ({lista_mats})
            """).result())
            nomes_extras = {r.matricula: r.nome or "" for r in _rows}
            for mat in mats_novos:
                colaboradores.append({"matricula": mat, "nome": nomes_extras.get(mat, ""), "bonificacao": Decimal("0")})

        for col in colaboradores:
            mat = str(col["matricula"])
            if mat in extras:
                col["bonificacao"] += extras[mat]
                logging.info(f"  Extra-bonif {mat}: +{extras[mat]}")

    # 4. Montar registros finais
    agora = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S")
    registros = []

    for col in colaboradores:
        mat        = str(col["matricula"])
        saldo      = saldos.get(mat, Decimal("0"))
        bonif      = col["bonificacao"]
        recompensa = recompensas.get(mat, Decimal("0"))

        # Só cria linha se tiver bonificação, recompensa ou saldo anterior a carregar
        if bonif == Decimal("0") and recompensa == Decimal("0") and saldo == Decimal("0"):
            continue

        liquido     = saldo + bonif + recompensa
        valor_pagar = max(Decimal("0"), liquido)
        saldo_pos   = min(Decimal("0"), liquido)

        registros.append({
            "matricula":            mat,
            "nome":                 col["nome"],
            "cpf":                  None,
            "saldo":                str(saldo),
            "bonificacao_atual":    str(bonif),
            "saldo_pos_bonificacao":str(saldo_pos),
            "valor_a_pagar":        str(valor_pagar),
            "data_inicio_ranking":  data_inicio.isoformat(),
            "report_at":            agora,
            "update_at":            agora,
            "bonus_recompensa":     str(recompensa),
        })

    logging.info(f"Registros prontos: {len(registros)}")
    logging.info(f"  Com saldo anterior:    {sum(1 for r in registros if str(r['saldo']) != '0')}")
    logging.info(f"  Com bonificação > 0:   {sum(1 for r in registros if Decimal(r['bonificacao_atual']) > 0)}")
    logging.info(f"  Com recompensa > 0:    {sum(1 for r in registros if Decimal(r['bonus_recompensa']) > 0)}")
    logging.info(f"  Receberão pagamento:   {sum(1 for r in registros if Decimal(r['valor_a_pagar']) > 0)}")

    if args.dry_run:
        print("\n=== DRY RUN — primeiros 10 registros ===")
        for r in registros[:10]:
            print(
                f"  {r['matricula']:>6} | {r['nome'][:35]:<35} | "
                f"saldo={r['saldo']:>10} | bonif={r['bonificacao_atual']:>10} | "
                f"pós={r['saldo_pos_bonificacao']:>10} | pagar={r['valor_a_pagar']:>10}"
            )
        print(f"\nTotal: {len(registros)} registros (não gravado)")
        return

    # 4. Gravar no BQ
    gravar_bq(registros, data_inicio)

    total_pagamento = sum(1 for r in registros if Decimal(r["valor_a_pagar"]) > 0)
    print(f"\nCARTEIRA_UPDATE_OK={len(registros)}")
    print(f"CARTEIRA_PERIODO={data_inicio}")
    print(f"CARTEIRA_PAGAMENTO={total_pagamento}")

    # Preenche planilha de pagamento no Drive (lê CPF do BQ após gravar_bq)
    excluir_setores = [s.strip() for s in args.excluir_setor.split(",")] if args.excluir_setor else None
    if excluir_setores:
        logging.info(f"Setores excluídos da planilha de pagamento: {excluir_setores}")
    drive_link = upload_planilha_pagamento(data_inicio, excluir_setores=excluir_setores)
    if drive_link:
        print(f"PERFORMANCE_PGTO_LINK={drive_link}")


if __name__ == "__main__":
    main()
