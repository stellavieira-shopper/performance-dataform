"""
Calcula bônus de recompensa (R$50 por flag) lendo das tabelas BQ:
  - Tabela_Base_Feedback_Operacional : boa_evolucao, top_1_setor, bom_comeco, reforco_operacao
  - Tabela_Base_Feedback_Fiscais     : reforco_operacao
  - Tabela_Base_Feedback_Supervisores: reforco_operacao

Atualiza carteira_operação: bonificacao_atual += bonus, bonus_recompensa = bonus,
recalcula saldo_pos_bonificacao e valor_a_pagar.

Uso:
  python adicionar_bonus_pdf.py                      # período atual automático
  python adicionar_bonus_pdf.py --inicio 2026-05-08  # período específico
"""
import argparse
import os
import sys
import io
from datetime import date, timedelta
from decimal import Decimal

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

from google.cloud import bigquery
from google.oauth2 import service_account

PROJECT_ID  = os.getenv("PROJECT_ID", "shopper-datalakehouse-qa")
CREDENTIALS = os.getenv("CREDENTIALS")
BQ_TABLE    = "Ranking_Performance.carteira_operação"


def periodo_atual() -> date:
    hoje = date.today()
    dow = hoje.weekday()
    return hoje - timedelta(days=(dow - 4) % 7)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inicio", default=None)
    args = parser.parse_args()

    data_inicio = date.fromisoformat(args.inicio) if args.inicio else periodo_atual()
    print(f"Período: {data_inicio}")

    creds  = service_account.Credentials.from_service_account_file(
        CREDENTIALS, scopes=["https://www.googleapis.com/auth/bigquery"]
    )
    client = bigquery.Client(project=PROJECT_ID, credentials=creds)

    # --- Calcula bonus por matrícula somando todas as flags ---
    query_bonus = f"""
    WITH bonus_raw AS (

      -- Operacionais: 4 flags possíveis
      SELECT
        CAST(MATRICULA AS STRING) AS matricula,
        (CASE WHEN boa_evolucao    THEN 50 ELSE 0 END +
         CASE WHEN top_1_setor     THEN 50 ELSE 0 END +
         CASE WHEN bom_comeco      THEN 50 ELSE 0 END +
         CASE WHEN reforco_operacao THEN 50 ELSE 0 END) AS bonus
      FROM `{PROJECT_ID}.Ranking_Performance.Tabela_Base_Feedback_Operacional`
      WHERE data_inicio = '{data_inicio}'

      UNION ALL

      -- Fiscais: reforco_operacao
      SELECT
        CAST(MATRICULA AS STRING),
        CASE WHEN reforco_operacao THEN 50 ELSE 0 END
      FROM `{PROJECT_ID}.Ranking_Performance.Tabela_Base_Feedback_Fiscais`
      WHERE data_inicio = '{data_inicio}'

      UNION ALL

      -- Supervisores: reforco_operacao
      SELECT
        CAST(MATRICULA AS STRING),
        CASE WHEN reforco_operacao THEN 50 ELSE 0 END
      FROM `{PROJECT_ID}.Ranking_Performance.Tabela_Base_Feedback_Supervisores`
      WHERE data_inicio = '{data_inicio}'
    )
    SELECT matricula, SUM(bonus) AS bonus_total
    FROM bonus_raw
    WHERE bonus > 0
    GROUP BY matricula
    ORDER BY bonus_total DESC, matricula
    """

    bonus_rows = list(client.query(query_bonus).result())
    bonus_por_mat = {str(r.matricula): int(r.bonus_total) for r in bonus_rows}

    print(f"Matrículas com bônus: {len(bonus_por_mat)}")
    multi = {m: v for m, v in bonus_por_mat.items() if v > 50}
    if multi:
        print(f"Em mais de uma lista (bonus > 50): {multi}")
    print(f"Total bônus recompensa: R$ {sum(bonus_por_mat.values()):,.2f}")

    if not bonus_por_mat:
        print("Nenhum bônus encontrado para o período. Encerrando.")
        sys.exit(0)

    # --- Busca registros atuais da carteira ---
    mats_quoted = ", ".join(f"'{m}'" for m in bonus_por_mat)
    rows_cart = list(client.query(f"""
        SELECT matricula, bonificacao_atual, saldo
        FROM `{PROJECT_ID}.{BQ_TABLE}`
        WHERE data_inicio_ranking = '{data_inicio}'
          AND matricula IN ({mats_quoted})
    """).result())

    print(f"Registros encontrados na carteira: {len(rows_cart)}")

    nao_encontrados = [m for m in bonus_por_mat if m not in {str(r.matricula) for r in rows_cart}]
    if nao_encontrados:
        print(f"Atenção — não encontrados na carteira: {nao_encontrados}")

    # --- Atualiza cada matrícula ---
    atualizados = 0
    for row in rows_cart:
        mat        = str(row.matricula)
        bonus      = Decimal(str(bonus_por_mat[mat]))
        nova_bonif = Decimal(str(row.bonificacao_atual)) + bonus
        saldo      = Decimal(str(row.saldo))
        liquido    = saldo + nova_bonif
        novo_valor = max(Decimal("0"), liquido)
        novo_saldo = min(Decimal("0"), liquido)

        client.query(f"""
            UPDATE `{PROJECT_ID}.{BQ_TABLE}`
            SET bonificacao_atual      = NUMERIC '{nova_bonif - bonus}',
                bonus_recompensa       = NUMERIC '{bonus}',
                saldo_pos_bonificacao  = NUMERIC '{novo_saldo}',
                valor_a_pagar          = NUMERIC '{novo_valor}',
                update_at              = CURRENT_TIMESTAMP()
            WHERE data_inicio_ranking = '{data_inicio}'
              AND matricula = '{mat}'
        """).result()
        atualizados += 1

    print(f"\nAtualizados: {atualizados} registros")

    # --- Resumo final ---
    r = list(client.query(f"""
        SELECT
          COUNT(*) AS total,
          SUM(CAST(valor_a_pagar AS FLOAT64)) AS total_a_pagar
        FROM `{PROJECT_ID}.{BQ_TABLE}`
        WHERE data_inicio_ranking = '{data_inicio}'
    """).result())[0]

    print(f"\nResumo final:")
    print(f"  Total registros: {r.total}")
    print(f"  Total a pagar:   R$ {r.total_a_pagar:,.2f}")


if __name__ == "__main__":
    main()
