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
from google.auth import load_credentials_from_file

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

    key_file = CREDENTIALS or os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
    creds, _ = load_credentials_from_file(
        key_file, scopes=["https://www.googleapis.com/auth/bigquery"]
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

    # --- Busca registros existentes na carteira para esse período ---
    mats_quoted = ", ".join(f"'{m}'" for m in bonus_por_mat)
    rows_cart = list(client.query(f"""
        SELECT matricula, bonificacao_atual, saldo_pos_bonificacao
        FROM `{PROJECT_ID}.{BQ_TABLE}`
        WHERE data_inicio_ranking = '{data_inicio}'
          AND matricula IN ({mats_quoted})
    """).result())

    encontrados = {str(r.matricula) for r in rows_cart}
    nao_encontrados = [m for m in bonus_por_mat if m not in encontrados]

    print(f"Registros encontrados na carteira: {len(rows_cart)}")
    if nao_encontrados:
        print(f"Não encontrados — serão criados: {len(nao_encontrados)}")

    # --- Busca saldo anterior para quem não tem registro no período atual ---
    saldos_anteriores: dict = {}
    if nao_encontrados:
        mats_novos = ", ".join(f"'{m}'" for m in nao_encontrados)
        rows_saldo = list(client.query(f"""
            SELECT matricula, CAST(saldo_pos_bonificacao AS NUMERIC) AS saldo
            FROM `{PROJECT_ID}.{BQ_TABLE}`
            WHERE data_inicio_ranking = (
                SELECT MAX(data_inicio_ranking)
                FROM `{PROJECT_ID}.{BQ_TABLE}`
                WHERE data_inicio_ranking < '{data_inicio}'
            )
              AND matricula IN ({mats_novos})
        """).result())
        for r in rows_saldo:
            saldos_anteriores[str(r.matricula)] = Decimal(str(r.saldo or "0"))

    # --- Atualiza existentes ---
    atualizados = 0
    for row in rows_cart:
        mat         = str(row.matricula)
        bonus       = Decimal(str(bonus_por_mat[mat]))
        bonif_atual = Decimal(str(row.bonificacao_atual or "0"))
        saldo       = Decimal(str(row.saldo_pos_bonificacao or "0"))
        liquido     = saldo + bonif_atual + bonus
        novo_valor  = max(Decimal("0"), liquido)
        novo_saldo  = min(Decimal("0"), liquido)

        client.query(f"""
            UPDATE `{PROJECT_ID}.{BQ_TABLE}`
            SET bonus_recompensa       = NUMERIC '{bonus}',
                saldo_pos_bonificacao  = NUMERIC '{novo_saldo}',
                valor_a_pagar          = NUMERIC '{novo_valor}',
                update_at              = CURRENT_TIMESTAMP()
            WHERE data_inicio_ranking = '{data_inicio}'
              AND matricula = '{mat}'
        """).result()
        atualizados += 1

    # --- Insere novos ---
    inseridos = 0
    for mat in nao_encontrados:
        bonus  = Decimal(str(bonus_por_mat[mat]))
        saldo  = saldos_anteriores.get(mat, Decimal("0"))
        liquido    = saldo + bonus
        novo_valor = max(Decimal("0"), liquido)
        novo_saldo = min(Decimal("0"), liquido)

        client.query(f"""
            INSERT INTO `{PROJECT_ID}.{BQ_TABLE}`
              (matricula, bonificacao_atual, bonus_recompensa,
               saldo_pos_bonificacao, valor_a_pagar,
               data_inicio_ranking, report_at, update_at)
            VALUES
              ('{mat}', NUMERIC '0', NUMERIC '{bonus}',
               NUMERIC '{novo_saldo}', NUMERIC '{novo_valor}',
               '{data_inicio}', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP())
        """).result()
        inseridos += 1

    print(f"Atualizados: {atualizados} | Inseridos: {inseridos}")

    # Preenche CPF para registros novos (sem CPF)
    if inseridos > 0:
        client.query(f"""
            UPDATE `{PROJECT_ID}.{BQ_TABLE}` c
            SET c.cpf = du.dados, c.update_at = CURRENT_TIMESTAMP()
            FROM `{PROJECT_ID}.Ranking_Performance.Dados Usuários` du
            WHERE c.matricula = CAST(du.matricula AS STRING)
              AND c.data_inicio_ranking = '{data_inicio}'
              AND c.cpf IS NULL
        """).result()
        print("CPF preenchido a partir de Dados Usuários")

    # --- Resumo final ---
    r = list(client.query(f"""
        SELECT
          COUNT(*) AS total,
          SUM(CAST(valor_a_pagar AS FLOAT64)) AS total_a_pagar
        FROM `{PROJECT_ID}.{BQ_TABLE}`
        WHERE data_inicio_ranking = '{data_inicio}'
    """).result())[0]

    total_a_pagar = r.total_a_pagar or 0.0
    print(f"\nResumo final:")
    print(f"  Total registros: {r.total}")
    print(f"  Total a pagar:   R$ {total_a_pagar:,.2f}")


if __name__ == "__main__":
    main()
