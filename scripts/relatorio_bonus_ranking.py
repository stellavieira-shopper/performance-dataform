"""
Relatorio de Bonus - Ranking de Performance
============================================
Altere apenas as duas variaveis abaixo e rode o script.
Gera PDF + CSV de pagamento na mesma pasta deste arquivo.

Instalacao (rode uma vez no terminal):
    pip install google-cloud-bigquery reportlab python-dotenv

Autenticacao: usa CREDENTIALS do .env (mesmo padrao dos outros scripts).
"""

# ============================================================
# CONFIGURACAO — so mude aqui (valores padrao; env vars têm prioridade)
# ============================================================
_DATA_INICIO_PADRAO = "2026-08-14"   # formato AAAA-MM-DD
_DATA_FIM_PADRAO    = "2026-08-20"   # formato AAAA-MM-DD
# ============================================================

import csv
import io
import os
import sys
import unicodedata
from datetime import datetime, date

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

# Período: env vars do Actions > hardcode local
def _periodo_automatico():
    from datetime import timedelta
    hoje = date.today()
    sexta = hoje - timedelta(days=(hoje.weekday() - 4) % 7)
    return sexta.isoformat(), (sexta + timedelta(days=6)).isoformat()

_ini_env = os.getenv("RELATORIO_DATA_INICIO", "").strip()
_fim_env = os.getenv("RELATORIO_DATA_FIM", "").strip()

if _ini_env and _fim_env:
    DATA_INICIO, DATA_FIM = _ini_env, _fim_env
elif not _ini_env and not _fim_env:
    # se os padrões ainda são o placeholder original, calcula automaticamente
    if _DATA_INICIO_PADRAO == "2026-08-14":
        DATA_INICIO, DATA_FIM = _periodo_automatico()
    else:
        DATA_INICIO, DATA_FIM = _DATA_INICIO_PADRAO, _DATA_FIM_PADRAO
else:
    DATA_INICIO, DATA_FIM = _DATA_INICIO_PADRAO, _DATA_FIM_PADRAO

from google.cloud import bigquery
from google.auth import load_credentials_from_file
from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import cm
from reportlab.platypus import (SimpleDocTemplate, Table, TableStyle,
                                Paragraph, Spacer, PageBreak)
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_CENTER

# ── BigQuery ────────────────────────────────────────────────
PROJECT_ID  = os.getenv("PROJECT_ID", "shopper-datalakehouse-qa")
CREDENTIALS = os.getenv("CREDENTIALS")
DATASET     = "Ranking_Performance"
TABLE_OP    = f"`{PROJECT_ID}.{DATASET}.Tabela_Base_Feedback_Operacional`"
TABLE_FIS   = f"`{PROJECT_ID}.{DATASET}.Tabela_Base_Feedback_Fiscais`"
TABLE_SUP   = f"`{PROJECT_ID}.{DATASET}.Tabela_Base_Feedback_Supervisores`"

# ── Layout ──────────────────────────────────────────────────
VALOR_BONUS     = 50.0
COR_VERDE       = colors.HexColor("#1A7A4A")
COR_VERDE_CLARO = colors.HexColor("#E8F5EE")
COR_CINZA       = colors.HexColor("#F5F5F5")


# ────────────────────────────────────────────────────────────
# Utilitarios
# ────────────────────────────────────────────────────────────

def sem_acento(texto):
    if not texto:
        return ""
    nfkd = unicodedata.normalize("NFKD", str(texto).strip())
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def make_client():
    key_file = CREDENTIALS or os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
    if key_file:
        creds, _ = load_credentials_from_file(
            key_file, scopes=["https://www.googleapis.com/auth/bigquery"]
        )
        return bigquery.Client(project=PROJECT_ID, credentials=creds)
    return bigquery.Client(project=PROJECT_ID)


# ────────────────────────────────────────────────────────────
# Coleta de dados no BigQuery
# ────────────────────────────────────────────────────────────

def query_bq(client, flag, table):
    sql = f"""
        SELECT MATRICULA, NOME, TURNO, setor, atribuicao
        FROM {table}
        WHERE {flag} = TRUE
          AND data_inicio BETWEEN '{DATA_INICIO}' AND '{DATA_FIM}'
        ORDER BY NOME
    """
    return [
        (
            str(r.MATRICULA),
            sem_acento(r.NOME),
            sem_acento(r.TURNO),
            sem_acento(r.setor),
            sem_acento(r.atribuicao),
        )
        for r in client.query(sql).result()
    ]


def buscar_dados():
    print(f"Consultando BigQuery ({DATA_INICIO} a {DATA_FIM})...")
    client = make_client()
    boa  = query_bq(client, "boa_evolucao",     TABLE_OP)
    top  = query_bq(client, "top_1_setor",      TABLE_OP)
    bom  = query_bq(client, "bom_comeco",       TABLE_OP)
    rop  = query_bq(client, "reforco_operacao",  TABLE_OP)
    rfis = query_bq(client, "reforco_operacao",  TABLE_FIS)
    rsup = query_bq(client, "reforco_operacao",  TABLE_SUP)
    print(f"  Boa Evolucao : {len(boa)}")
    print(f"  Top 1 Setor  : {len(top)}")
    print(f"  Bom Comeco   : {len(bom)}")
    print(f"  Reforco Op.  : {len(rop) + len(rfis) + len(rsup)}")
    print(f"  TOTAL        : {len(boa) + len(top) + len(bom) + len(rop) + len(rfis) + len(rsup)}")
    return boa, top, bom, rop, rfis, rsup


# ────────────────────────────────────────────────────────────
# Geracao do CSV de pagamento
# ────────────────────────────────────────────────────────────

CRITERIOS = [
    ("Boa Evolucao",                    "boa_evolucao"),
    ("Top 1 Setor",                     "top_1_setor"),
    ("Bom Comeco",                      "bom_comeco"),
    ("Reforco Operacao - Operacional",  "reforco_operacao_op"),
    ("Reforco Operacao - Fiscal",       "reforco_operacao_fis"),
    ("Reforco Operacao - Supervisor",   "reforco_operacao_sup"),
]


def gerar_csv(boa, top, bom, rop, rfis, rsup, output_base):
    nome_csv = output_base + ".csv"

    secoes = [
        ("Boa Evolucao",                    boa),
        ("Top 1 Setor",                     top),
        ("Bom Comeco",                      bom),
        ("Reforco Operacao - Operacional",  rop),
        ("Reforco Operacao - Fiscal",       rfis),
        ("Reforco Operacao - Supervisor",   rsup),
    ]

    with open(nome_csv, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f, delimiter=";")
        writer.writerow([
            "MATRICULA",
            "NOME",
            "TURNO",
            "SETOR",
            "CARGO",
            "CRITERIO",
            "VALOR_BONUS",
            "DATA_INICIO",
            "DATA_FIM",
        ])
        total_linhas = 0
        for criterio, dados in secoes:
            for (mat, nome, turno, setor, cargo) in dados:
                writer.writerow([
                    mat,
                    nome,
                    turno,
                    setor,
                    cargo,
                    criterio,
                    f"{VALOR_BONUS:.2f}".replace(".", ","),
                    DATA_INICIO,
                    DATA_FIM,
                ])
                total_linhas += 1

    print(f"CSV gerado: {nome_csv} ({total_linhas} linhas)")
    return nome_csv


# ────────────────────────────────────────────────────────────
# Geracao do PDF
# ────────────────────────────────────────────────────────────

def gerar_pdf(boa, top, bom, rop, rfis, rsup, output_base):
    d_ini = datetime.strptime(DATA_INICIO, "%Y-%m-%d")
    d_fim = datetime.strptime(DATA_FIM,    "%Y-%m-%d")

    semana   = f"{d_ini.strftime('%d/%m/%Y')} a {d_fim.strftime('%d/%m/%Y')}"
    nome_pdf = output_base + ".pdf"

    N_BOA     = len(boa)
    N_TOP     = len(top)
    N_BOM     = len(bom)
    N_REFORCO = len(rop) + len(rfis) + len(rsup)
    N_TOTAL   = N_BOA + N_TOP + N_BOM + N_REFORCO
    BONUS_TOTAL = N_TOTAL * VALOR_BONUS

    style_section = ParagraphStyle(
        "section", fontSize=13, leading=16,
        textColor=COR_VERDE, fontName="Helvetica-Bold", spaceAfter=6,
    )
    style_empty = ParagraphStyle(
        "empty", fontSize=9, leading=12,
        textColor=colors.grey, fontName="Helvetica-Oblique", alignment=TA_CENTER,
    )

    def on_page(canvas, doc):
        w, h = A4
        canvas.saveState()
        canvas.setFillColor(COR_VERDE)
        canvas.rect(0, h - 3.5*cm, w, 3.5*cm, fill=1, stroke=0)
        canvas.setFillColor(colors.white)
        canvas.setFont("Helvetica-Bold", 16)
        canvas.drawCentredString(w/2, h - 1.6*cm,
                                 "Relatorio de Bonus - Ranking de Performance")
        canvas.setFont("Helvetica", 11)
        canvas.drawCentredString(w/2, h - 2.4*cm, f"Semana: {semana}")
        canvas.setFillColor(COR_VERDE)
        canvas.rect(0, 0, w, 1.2*cm, fill=1, stroke=0)
        canvas.setFillColor(colors.white)
        canvas.setFont("Helvetica", 8)
        canvas.drawString(1.5*cm, 0.45*cm,
                          f"Gerado em: {date.today().strftime('%d/%m/%Y')}")
        canvas.drawCentredString(w/2, 0.45*cm, f"Pagina {doc.page}")
        canvas.drawRightString(w - 1.5*cm, 0.45*cm, "Shopper - Confidencial")
        canvas.restoreState()

    def make_col_table(data_list):
        if not data_list:
            return Paragraph(
                "Nenhum colaborador registrado neste criterio.", style_empty
            )
        rows = [["#", "Matricula", "Nome", "Turno", "Setor", "Cargo"]] + [
            [str(i), str(m), n, t, s, c]
            for i, (m, n, t, s, c) in enumerate(data_list, 1)
        ]
        tbl = Table(
            rows,
            colWidths=[1*cm, 2*cm, 6.5*cm, 2.5*cm, 3.5*cm, 3.5*cm],
            repeatRows=1,
        )
        tbl.setStyle(TableStyle([
            ("BACKGROUND",     (0, 0), (-1,  0), COR_VERDE),
            ("TEXTCOLOR",      (0, 0), (-1,  0), colors.white),
            ("FONTNAME",       (0, 0), (-1,  0), "Helvetica-Bold"),
            ("FONTSIZE",       (0, 0), (-1,  0), 8),
            ("FONTNAME",       (0, 1), (-1, -1), "Helvetica"),
            ("FONTSIZE",       (0, 1), (-1, -1), 8),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, COR_CINZA]),
            ("GRID",           (0, 0), (-1, -1), 0.4, colors.HexColor("#CCCCCC")),
            ("ALIGN",          (0, 0), ( 1, -1), "CENTER"),
            ("VALIGN",         (0, 0), (-1, -1), "MIDDLE"),
            ("TOPPADDING",     (0, 0), (-1, -1), 4),
            ("BOTTOMPADDING",  (0, 0), (-1, -1), 4),
        ]))
        return tbl

    doc = SimpleDocTemplate(
        nome_pdf, pagesize=A4,
        topMargin=4*cm, bottomMargin=2*cm,
        leftMargin=1.5*cm, rightMargin=1.5*cm,
    )
    story = []

    kpi_tbl = Table([[
        f"Boa Evolucao\n{N_BOA}",
        f"Top 1 Setor\n{N_TOP}",
        f"Bom Comeco\n{N_BOM}",
        f"Reforco Op.\n{N_REFORCO}",
        f"Total Colab.\n{N_TOTAL}",
        f"Bonus Total\nR$ {BONUS_TOTAL:,.0f}".replace(",", "."),
    ]], colWidths=[3.0*cm] * 6)
    kpi_tbl.setStyle(TableStyle([
        ("BACKGROUND",    (0, 0), (-1, -1), COR_VERDE),
        ("TEXTCOLOR",     (0, 0), (-1, -1), colors.white),
        ("FONTNAME",      (0, 0), (-1, -1), "Helvetica-Bold"),
        ("FONTSIZE",      (0, 0), (-1, -1), 9),
        ("ALIGN",         (0, 0), (-1, -1), "CENTER"),
        ("VALIGN",        (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING",    (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
        ("GRID",          (0, 0), (-1, -1), 0.5, colors.white),
    ]))
    story.append(kpi_tbl)
    story.append(Spacer(1, 0.5*cm))

    story.append(Paragraph("Resumo por Criterio", style_section))
    res_tbl = Table([
        ["Criterio",        "Colaboradores", "Bonus (R$)"],
        ["Boa Evolucao",     str(N_BOA),
         f"R$ {N_BOA * 50:,.0f}".replace(",", ".")],
        ["Top 1 Setor",      str(N_TOP),
         f"R$ {N_TOP * 50:,.0f}".replace(",", ".")],
        ["Bom Comeco",       str(N_BOM),
         f"R$ {N_BOM * 50:,.0f}".replace(",", ".")],
        ["Reforco Operacao", str(N_REFORCO),
         f"R$ {N_REFORCO * 50:,.0f}".replace(",", ".")],
        ["TOTAL",            str(N_TOTAL),
         f"R$ {BONUS_TOTAL:,.0f}".replace(",", ".")],
    ], colWidths=[8*cm, 5*cm, 5*cm])
    res_tbl.setStyle(TableStyle([
        ("BACKGROUND",     (0,  0), (-1,  0), COR_VERDE),
        ("TEXTCOLOR",      (0,  0), (-1,  0), colors.white),
        ("FONTNAME",       (0,  0), (-1,  0), "Helvetica-Bold"),
        ("BACKGROUND",     (0, -1), (-1, -1), COR_VERDE_CLARO),
        ("FONTNAME",       (0, -1), (-1, -1), "Helvetica-Bold"),
        ("FONTSIZE",       (0,  0), (-1, -1), 9),
        ("ALIGN",          (1,  0), (-1, -1), "CENTER"),
        ("ROWBACKGROUNDS", (0,  1), (-1, -2), [colors.white, COR_CINZA]),
        ("GRID",           (0,  0), (-1, -1), 0.4, colors.HexColor("#CCCCCC")),
        ("TOPPADDING",     (0,  0), (-1, -1), 5),
        ("BOTTOMPADDING",  (0,  0), (-1, -1), 5),
    ]))
    story.append(res_tbl)

    for title, data in [
        ("1. Boa Evolucao",                    boa),
        ("2. Top 1 Setor",                     top),
        ("3. Bom Comeco",                      bom),
        ("4. Reforco Operacao - Operacionais", rop),
        ("5. Reforco Operacao - Fiscais",      rfis),
        ("6. Reforco Operacao - Supervisores", rsup),
    ]:
        story.append(PageBreak())
        story.append(Paragraph(title, style_section))
        story.append(Spacer(1, 0.2*cm))
        story.append(make_col_table(data))

    doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
    print(f"PDF gerado: {nome_pdf}")
    return nome_pdf


# ────────────────────────────────────────────────────────────
if __name__ == "__main__":
    boa, top, bom, rop, rfis, rsup = buscar_dados()

    d_ini = datetime.strptime(DATA_INICIO, "%Y-%m-%d")
    d_fim = datetime.strptime(DATA_FIM,    "%Y-%m-%d")
    base_nome = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        f"Bonus_Ranking_{d_ini.strftime('%d')}_{d_fim.strftime('%d')}_{d_fim.strftime('%b').lower()}_{d_fim.year}",
    )

    gerar_pdf(boa, top, bom, rop, rfis, rsup, base_nome)

    total = sum(len(x) for x in [boa, top, bom, rop, rfis, rsup])
    print(f"\nTotal: {total} colaboradores | R$ {total * VALOR_BONUS:,.2f}")
