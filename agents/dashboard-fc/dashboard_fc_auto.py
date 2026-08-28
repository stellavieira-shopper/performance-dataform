"""
Dashboard FC — Geração automática de mensagens de performance semanal.

Uso:
  python dashboard_fc_auto.py --data DD/MM/AAAA

Variáveis de ambiente obrigatórias:
  SHEETS_TOKEN_PATH  — caminho para o sheets_token.json (OAuth2 pessoal)
                       Em Actions: gravado de SHEETS_TOKEN_JSON secret.
  ANTHROPIC_API_KEY  — chave da API Anthropic
"""

import argparse
import base64
import io
import json
import os
import re
import sys
from datetime import datetime

import anthropic
import gspread
import openpyxl
import requests
from dotenv import load_dotenv
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import cm
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
)

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

# ── IDs das planilhas ────────────────────────────────────────────────────────
SPREADSHEET_ID_FC   = "1j-mRJN2IHR3LjHaFtVgHtg2pH1XS3becphjBVjD02Ug"
SPREADSHEET_ID_GE   = "1E9ZXe2LtYySON6YYZYpn3BFEk-RiU-NsBJzmg6FUqrw"
EXPORT_MIME         = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

TOKEN_PATH = os.getenv("SHEETS_TOKEN_PATH") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "sheets_token.json"
)

# Cores
COR_VERDE_ESCURO    = "#274e13"
COR_LARANJA         = "#b45309"

# ── Auth ─────────────────────────────────────────────────────────────────────

SCOPES = [
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/drive",
]


def get_credentials():
    creds = Credentials.from_authorized_user_file(TOKEN_PATH, scopes=SCOPES)
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
    return creds


def download_xlsx(file_id: str, creds) -> openpyxl.Workbook:
    token = creds.token
    if not token:
        import google.auth.transport.requests
        creds.refresh(google.auth.transport.requests.Request())
        token = creds.token
    url = (
        f"https://www.googleapis.com/drive/v3/files/{file_id}/export"
        f"?mimeType={EXPORT_MIME}"
    )
    resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=60)
    resp.raise_for_status()
    return openpyxl.load_workbook(io.BytesIO(resp.content))


# ── Parsing ───────────────────────────────────────────────────────────────────

def extract_val(cell_val):
    """Extrai valor real de células com fórmula DUMMYFUNCTION do IMPORTRANGE."""
    if cell_val is None:
        return None
    s = str(cell_val)
    m = re.search(r'DUMMYFUNCTION\("""COMPUTED_VALUE"""\),(.+)\)$', s)
    if m:
        v = m.group(1).strip()
        if v.startswith('"') and v.endswith('"'):
            v = v[1:-1]
        try:
            return float(v)
        except ValueError:
            return v
    return cell_val


def ler_resumo_fc(wb, fc: str) -> list[dict]:
    ws = wb[f"Resumo {fc}"]
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        return []
    header = rows[0]
    return [dict(zip(header, row)) for row in rows[1:] if any(v is not None for v in row)]


def ler_visao_fc(wb, fc: str) -> list[dict]:
    ws = wb[f"Visão {fc}"]
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        return []
    header = rows[0]
    return [
        dict(zip(header, row))
        for row in rows[1:]
        if row[0]  # SETOR preenchido
    ]


def ler_vistoria_semana(wb) -> list[dict]:
    ws = wb["Vistoria Semana"]
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        return []
    header = rows[0]
    result = []
    for row in rows[1:]:
        if not any(v is not None for v in row):
            continue
        d = dict(zip(header, row))
        if d.get("MATRÍCULA") is None:
            continue
        result.append(d)
    return result


def ler_ge(wb_ge) -> list[dict]:
    """Lê abas FC1/FC2/FC3 da planilha GE, retorna linhas com JUSTIFICATIVA."""
    result = []
    for fc_nome in ["FC1", "FC2", "FC3"]:
        if fc_nome not in wb_ge.sheetnames:
            continue
        ws = wb_ge[fc_nome]
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            continue
        for row in rows[1:]:
            if not any(v is not None for v in row):
                continue
            matricula = row[0]
            justificativa = row[8] if len(row) > 8 else None
            if not justificativa:
                continue
            mat_str = None
            if matricula is not None:
                try:
                    mat_str = str(int(float(matricula)))
                except (ValueError, TypeError):
                    mat_str = str(matricula)
            result.append({
                "matricula": mat_str,
                "fc": fc_nome,
                "justificativa": str(justificativa),
            })
    return result


# ── Geração de mensagens com Anthropic ───────────────────────────────────────

def gerar_mensagem_setor(client, fc: str, config: dict, resumo: list[dict]) -> str:
    setor = config.get("SETOR", "")
    atribuicao = config.get("ATRIBUIÇÃO", "") or ""
    turno = config.get("TURNO", "") or ""
    desconto = config.get("DESCONTO", "") or ""
    ideia_central = config.get("IDEIA CENTRAL", "") or ""

    kpis_str = json.dumps(resumo, ensure_ascii=False, default=str)

    prompt = f"""Você é um assistente que gera mensagens de performance para colaboradores de um centro de distribuição (FC).

FC: {fc}
Setor: {setor}
Atribuição: {atribuicao or "TODAS"}
Turno: {turno or "TODOS"}
Desconto: {desconto or "sem desconto"}
Ideia central: {ideia_central}

KPIs da semana (Resumo {fc}):
{kpis_str}

Gere uma mensagem de performance seguindo EXATAMENTE estas regras:
1. Máximo 3 frases. Sem saudação. Sem assinatura. Sem emoji. Sem markdown.
2. Se há desconto (ex: -25%): primeira frase SEMPRE "{desconto} na Bonificação."
3. Se desconto = 0% por erro/processo especial: começar com "VALOR DA BONIFICAÇÃO ZERADO." e explicar o motivo vindo da ideia central.
4. Se desconto = 0% sem situação especial: começar direto pelo resultado.
5. Citar nomes reais dos indicadores (SMD, leva A, HR, Fiorino, pedidos mapeados, completos fresh/mercearia, rupturas, divergências).
6. NUNCA mencionar números, percentuais ou valores — apenas direção (melhorou, piorou, distante da meta).
7. Tom direto e factual — sem motivacionais genéricos.
8. Se turno específico (não TODOS): mencionar o turno.
9. Use a ideia central como fio condutor — mesmo que os dados não mostrem explicitamente.

Retorne APENAS o texto da mensagem, sem aspas ou explicações."""

    msg = client.messages.create(
        model="claude-opus-5",
        max_tokens=500,
        messages=[{"role": "user", "content": prompt}],
    )
    return msg.content[0].text.strip()


def gerar_mensagem_ge(client, item: dict) -> str:
    justificativa = item["justificativa"]

    prompt = f"""Você gera mensagens para colaboradores de inventário de Gestão de Estoque (GE).

Justificativa da planilha (contexto interno, não copiar diretamente):
{justificativa}

Gere uma mensagem reformulada seguindo EXATAMENTE estas regras:
1. Tom profissional e direto. Sem saudação. Sem assinatura. Sem emoji. Sem markdown.
2. NUNCA incluir números, percentuais ou valores — apenas direção qualitativa.
3. Use os padrões abaixo conforme o caso identificado na justificativa:
   - Não atingiu mínimo de posições: "Você não atingiu o mínimo de posições necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque."
   - Não atingiu acurácia mínima: "Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque."
   - Não atingiu posições E acurácia: "Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque."
   - Detratora: "Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao baixo desempenho nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação."
4. Adapte o padrão acima se a justificativa apresentar uma situação diferente, mantendo o estilo e sem mencionar valores.

Retorne APENAS o texto da mensagem."""

    msg = client.messages.create(
        model="claude-opus-5",
        max_tokens=300,
        messages=[{"role": "user", "content": prompt}],
    )
    return msg.content[0].text.strip()


# ── Escrita na planilha ───────────────────────────────────────────────────────

def escrever_mensagens(creds, spreadsheet_id: str, data: str, mensagens: list[dict]):
    gc = gspread.authorize(creds)
    sh = gc.open_by_key(spreadsheet_id)
    ws = sh.worksheet("Mensagens")

    rows = []
    for m in mensagens:
        rows.append([
            data,
            m.get("fc", ""),
            m.get("setor", ""),
            m.get("atribuicao", ""),
            m.get("turno", ""),
            m.get("matricula", ""),
            m.get("desconto", ""),
            m.get("ideia_central", ""),
            m.get("mensagem", ""),
        ])

    ws.append_rows(rows, value_input_option="USER_ENTERED")
    url = f"https://docs.google.com/spreadsheets/d/{spreadsheet_id}/edit"
    print(f"OK: {len(rows)} mensagens escritas na aba 'Mensagens'")
    print(f"LINK={url}")
    return url


# ── PDFs ──────────────────────────────────────────────────────────────────────

def _hex_to_color(hex_str: str):
    h = hex_str.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return colors.Color(r / 255, g / 255, b / 255)


def gerar_pdf_kpi(mensagens: list[dict], data: str, output_path: str):
    doc = SimpleDocTemplate(output_path, pagesize=A4,
                            leftMargin=1.5*cm, rightMargin=1.5*cm,
                            topMargin=1.5*cm, bottomMargin=1.5*cm)
    styles = getSampleStyleSheet()
    verde = _hex_to_color(COR_VERDE_ESCURO)

    title_style = ParagraphStyle("title", parent=styles["Title"],
                                 textColor=colors.white, fontSize=14, spaceAfter=4)
    setor_style = ParagraphStyle("setor", parent=styles["Normal"],
                                 textColor=verde, fontName="Helvetica-Bold", fontSize=10)
    msg_style   = ParagraphStyle("msg", parent=styles["Normal"], fontSize=9, leading=13)
    tag_style   = ParagraphStyle("tag", parent=styles["Normal"],
                                 textColor=colors.grey, fontSize=8)

    story = []

    # Cabeçalho principal
    header_data = [[Paragraph(f"Mensagens de Performance FC — {data}", title_style)]]
    header_table = Table(header_data, colWidths=[17*cm])
    header_table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), verde),
        ("TOPPADDING", (0, 0), (-1, -1), 10),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
        ("LEFTPADDING", (0, 0), (-1, -1), 12),
    ]))
    story.append(header_table)
    story.append(Spacer(1, 0.4*cm))

    fcs = sorted(set(m["fc"] for m in mensagens))
    for fc in fcs:
        fc_msgs = [m for m in mensagens if m["fc"] == fc]

        fc_header = Table([[Paragraph(fc, title_style)]], colWidths=[17*cm])
        fc_header.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), verde),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ]))
        story.append(fc_header)
        story.append(Spacer(1, 0.2*cm))

        for m in fc_msgs:
            setor_txt = m.get("setor", "")
            tags = []
            if m.get("atribuicao") and m["atribuicao"] not in ("TODAS", ""):
                tags.append(m["atribuicao"])
            if m.get("turno") and m["turno"] not in ("TODOS", ""):
                tags.append(m["turno"])
            if m.get("desconto"):
                tags.append(m["desconto"])
            tags_txt = " | ".join(tags) if tags else ""

            card_content = [
                [Paragraph(setor_txt, setor_style)],
            ]
            if tags_txt:
                card_content.append([Paragraph(tags_txt, tag_style)])
            card_content.append([Paragraph(m.get("mensagem", ""), msg_style)])

            card = Table([[row[0]] for row in card_content], colWidths=[16*cm])
            card.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#f5f5f5")),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 10),
            ]))
            story.append(card)
            story.append(Spacer(1, 0.25*cm))

        story.append(Spacer(1, 0.3*cm))

    doc.build(story)
    print(f"PDF KPI: {output_path}")


def gerar_pdf_vistoria(vistoria: list[dict], output_path: str):
    entries = [v for v in vistoria if v.get("MATRÍCULA") is not None]
    if not entries:
        print("Vistoria: nenhuma entrada válida, PDF não gerado.")
        return

    periodo = entries[0].get("PERÍODO", "")

    doc = SimpleDocTemplate(output_path, pagesize=A4,
                            leftMargin=1.5*cm, rightMargin=1.5*cm,
                            topMargin=1.5*cm, bottomMargin=1.5*cm)
    styles = getSampleStyleSheet()
    laranja = _hex_to_color(COR_LARANJA)

    title_style = ParagraphStyle("title", parent=styles["Title"],
                                 textColor=colors.white, fontSize=13)
    mat_style   = ParagraphStyle("mat", parent=styles["Normal"],
                                 fontName="Helvetica-Bold", fontSize=10)
    msg_style   = ParagraphStyle("msg", parent=styles["Normal"], fontSize=9, leading=13)

    story = []

    header_data = [[Paragraph(f"Mensagens de Vistoria Picking — {periodo}", title_style)]]
    header_table = Table(header_data, colWidths=[17*cm])
    header_table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), laranja),
        ("TOPPADDING", (0, 0), (-1, -1), 10),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
        ("LEFTPADDING", (0, 0), (-1, -1), 12),
    ]))
    story.append(header_table)
    story.append(Spacer(1, 0.4*cm))

    fcs = sorted(set(str(v.get("FC", "")) for v in entries if v.get("FC")))
    total = 0
    for fc in fcs:
        fc_entries = [v for v in entries if str(v.get("FC", "")) == fc]
        story.append(Paragraph(f"{fc} — {len(fc_entries)} colaboradores",
                               ParagraphStyle("fch", parent=styles["Heading2"],
                                              textColor=laranja)))
        story.append(Spacer(1, 0.2*cm))

        for i, v in enumerate(fc_entries, 1):
            mat_raw = v.get("MATRÍCULA")
            try:
                mat = str(int(float(mat_raw)))
            except (ValueError, TypeError):
                mat = str(mat_raw)

            pct_raw = v.get("% DESCONTO")
            try:
                pct = int(float(pct_raw) * 100)
                pct_str = f"{pct}%"
            except (ValueError, TypeError):
                pct_str = str(pct_raw)

            mensagem = v.get("MENSAGEM", "")
            zerado = pct_str == "0%"

            bg = colors.HexColor("#fef2f2") if zerado else colors.HexColor("#f9f9f9")
            border_color = colors.red if zerado else colors.lightgrey

            card_rows = [
                [Paragraph(f"{i}. Matrícula {mat} | {pct_str}", mat_style)],
                [Paragraph(mensagem, msg_style)],
            ]
            card = Table([[r[0]] for r in card_rows], colWidths=[16*cm])
            card.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, -1), bg),
                ("BOX", (0, 0), (-1, -1), 1, border_color),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
                ("LEFTPADDING", (0, 0), (-1, -1), 8),
                ("RIGHTPADDING", (0, 0), (-1, -1), 8),
            ]))
            story.append(card)
            story.append(Spacer(1, 0.2*cm))
            total += 1

        story.append(Spacer(1, 0.3*cm))

    story.append(Paragraph(f"Total: {total} colaboradores", styles["Normal"]))
    doc.build(story)
    print(f"PDF Vistoria: {output_path}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=False, help="Data no formato DD/MM/AAAA")
    parser.add_argument("--output-dir", default=".", help="Diretório de saída dos PDFs")
    args = parser.parse_args()

    data = args.data or datetime.today().strftime("%d/%m/%Y")
    data_fmt = data.replace("/", "")  # para nome de arquivo
    output_dir = args.output_dir
    os.makedirs(output_dir, exist_ok=True)

    print(f"Iniciando geração de mensagens FC — {data}")

    creds = get_credentials()
    anthropic_client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

    print("Baixando planilha Dashboard FC...")
    wb_fc = download_xlsx(SPREADSHEET_ID_FC, creds)

    print("Baixando planilha Performance inventário (GE)...")
    wb_ge = download_xlsx(SPREADSHEET_ID_GE, creds)

    mensagens_finais = []

    # ── Mensagens setoriais (Visão FC + Resumo FC) ────────────────────────────
    for fc in ["FC1", "FC2", "FC3"]:
        resumo = ler_resumo_fc(wb_fc, fc)
        visao  = ler_visao_fc(wb_fc, fc)

        for config in visao:
            setor = config.get("SETOR", "")
            if not setor:
                continue
            print(f"Gerando mensagem: {fc} / {setor}")
            mensagem = gerar_mensagem_setor(anthropic_client, fc, config, resumo)
            mensagens_finais.append({
                "fc": fc,
                "setor": setor,
                "atribuicao": config.get("ATRIBUIÇÃO", "") or "TODAS",
                "turno": config.get("TURNO", "") or "TODOS",
                "matricula": config.get("MATRÍCULA", "") or "",
                "desconto": config.get("DESCONTO", "") or "",
                "ideia_central": config.get("IDEIA CENTRAL", "") or "",
                "mensagem": mensagem,
            })

    # ── Mensagens GE ──────────────────────────────────────────────────────────
    ge_rows = ler_ge(wb_ge)
    print(f"GE: {len(ge_rows)} linhas com JUSTIFICATIVA preenchida")
    for item in ge_rows:
        print(f"Gerando mensagem GE: {item['fc']} / matrícula {item['matricula']}")
        mensagem = gerar_mensagem_ge(anthropic_client, item)
        mensagens_finais.append({
            "fc": item["fc"],
            "setor": "GESTÃO DE ESTOQUE",
            "atribuicao": "INVENTÁRIO",
            "turno": "",
            "matricula": item["matricula"] or "",
            "desconto": "",
            "ideia_central": item["justificativa"],
            "mensagem": mensagem,
        })

    # ── Escrever na planilha ──────────────────────────────────────────────────
    escrever_mensagens(creds, SPREADSHEET_ID_FC, data, mensagens_finais)

    # ── PDFs ──────────────────────────────────────────────────────────────────
    msgs_setoriais = [m for m in mensagens_finais if m["setor"] != "GESTÃO DE ESTOQUE"]
    pdf_kpi = os.path.join(output_dir, f"mensagens_kpi_fc_{data_fmt}.pdf")
    gerar_pdf_kpi(msgs_setoriais, data, pdf_kpi)

    vistoria = ler_vistoria_semana(wb_fc)
    pdf_vistoria = os.path.join(output_dir, f"vistoria_picking_{data_fmt}.pdf")
    gerar_pdf_vistoria(vistoria, pdf_vistoria)

    print(f"\nConcluído. {len(mensagens_finais)} mensagens geradas.")


if __name__ == "__main__":
    main()
