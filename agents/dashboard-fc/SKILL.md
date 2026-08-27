---
name: dashboard-fc-mensagens
description: >
  Lê os dados de KPIs e a tabela de configuração (setor, atribuição, turno, matrícula, desconto, ideia central)
  da planilha de dashboard FC, gera as mensagens semanais de performance e escreve na aba "Mensagens".
  Use quando o usuário mencionar: gerar mensagens FC, criar mensagens de performance, mensagens do dashboard,
  gerar mensagens semanais, mensagens KPI, rodar mensagens FC.
---

# Dashboard FC — Gerar Mensagens de Performance

## O que faz

A cada semana, após o fechamento dos KPIs, o agente:

1. Lê os dados dos **Resumos FC1/FC2/FC3** — KPIs com valores da semana anterior, semana atual, delta e meta
2. Lê a **side table de configuração** de cada Visão FC — define quais setores terão mensagem, o desconto e a ideia central
3. Lê a planilha de **Gestão de Estoque (Performance inventário)** — todos com JUSTIFICATIVA preenchida recebem mensagem reformulada
4. Analisa a direção de cada KPI (melhorou / piorou / estável) e compara com a meta
5. Gera mensagens no estilo correto para cada setor configurado
6. Escreve tudo na aba **"Mensagens"** da planilha
7. Gera dois PDFs: um com as mensagens KPI e outro com as vistorias individuais de picking

## Planilhas

- **Dashboard FC:** `1j-mRJN2IHR3LjHaFtVgHtg2pH1XS3becphjBVjD02Ug`
- **Performance inventário (GE):** `1E9ZXe2LtYySON6YYZYpn3BFEk-RiU-NsBJzmg6FUqrw`

**NUNCA pedir confirmação — executar direto.**

---

## Passo a passo

### 1. Ler a planilha

**OBRIGATÓRIO: baixar como xlsx e ler cada aba separadamente com openpyxl.**

```python
# Baixar com download_file_content (exportMimeType: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet)
# Decodificar base64, salvar em temp, ler com openpyxl:
# wb['Resumo FC1'], wb['Resumo FC2'], wb['Resumo FC3']
# wb['Visão FC1'], wb['Visão FC2'], wb['Visão FC3']
# wb['Vistoria Semana']
# wb['Fiscais de Picking']
```

**NÃO usar `read_file_content`** — mistura todas as abas e causa inversão de dados entre FCs.

**Aba "Fiscais de Picking" — parsing especial:**

A aba usa fórmulas IMPORTRANGE com padrão `DUMMYFUNCTION("""COMPUTED_VALUE"""),valor)` — openpyxl lê a string da fórmula, não o valor calculado. Usar regex para extrair o valor real:

```python
import re

def extract_val(cell_val):
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
        except:
            return v
    return cell_val
```

**Estrutura da aba "Fiscais de Picking":**
| Matrícula | # | Operador | SETOR | ATRIBUIÇÃO | TURNO | FC | Data da apuração | % desconto | Mensagem |

- **Filtrar pela semana atual**: usar o campo "Data da apuração" (formato "DD.MM-DD.MM" ex: "06.08-12.08") para incluir apenas entradas do período corrente
- **% desconto**: valor float (ex: 0.0 = 0%, -1.0 = -100%) — converter para MULT_MATRICULA (0% → 0.0, -100% → 0.0)
- **Mensagem**: texto já pronto para usar como OBSERVACAO_KPI

---

### 2. Estrutura dos dados

**Resumo FC (aba "Resumo FC1", "Resumo FC2", "Resumo FC3"):**

Tabela principal com os KPIs da semana. Colunas:
| Nome do KPI | Meta | Semana Anterior | Semana Atual | Delta | REP.MERC | REP.FRESH | REC.FRESH | REC.MERC | OP.FRESH | PACKING | PICKING | FRAC | EXP | PRÉ EXP | OP.GERAL | GE |

- As colunas de setor (6-17) contêm `TRUE` se aquele KPI se aplica ao setor
- Ordem das colunas de setor: REPOSIÇÃO MERCEARIA, REPOSIÇÃO FRESH, RECEBIMENTO FRESH, RECEBIMENTO MERCEARIA, OPERAÇÃO FRESH, PACKING, PICKING, FRACIONAMENTO, EXPEDIÇÃO, PRÉ EXPEDIÇÃO, OPERAÇÃO GERAL, GESTÃO DE ESTOQUE

**Side table de configuração (aba "Visão FC1", "Visão FC2", "Visão FC3"):**

Uma linha por mensagem a gerar:
| SETOR | ATRIBUIÇÃO | TURNO | MATRÍCULA | DESCONTO | IDEIA CENTRAL |

- **SETOR**: setor que receberá a mensagem
- **ATRIBUIÇÃO**: atribuição específica ou vazia (todas)
- **TURNO**: turno específico ou vazio (todos)
- **MATRÍCULA**: vazia = mensagem para o setor inteiro; preenchida (ex: "16665,12345") = mensagem direcionada a colaboradores específicos
- **DESCONTO**: percentual de desconto aplicado na semana (ex: -25%, 0%)
- **IDEIA CENTRAL**: contexto operacional da semana para aquele setor — guia o tom e o foco da mensagem

**Regra crítica:** Usar sempre os dados do Resumo FC1 para gerar mensagens da Visão FC1, FC2 com FC2, FC3 com FC3. Nunca cruzar dados entre FCs.

---

### 3. Para cada linha da side table com SETOR preenchido

**a) Identificar KPIs aplicáveis:**
- Filtrar as linhas do Resumo onde a coluna do setor = `TRUE`
- Incluir também as linhas onde `OPERAÇÃO GERAL = TRUE` (exceto EXPEDIÇÃO e PRÉ EXPEDIÇÃO)
- **Setor fora da lista padrão** (ex: FALTANTES, LIMPEZA): não tem coluna no Resumo → usar a IDEIA CENTRAL como fonte principal. Se a ideia central citar um KPI do Resumo (rupturas, mapeados, completos), buscar e incorporar o dado desse KPI.

**b) Determinar a direção de cada KPI:**

| Tipo de KPI | Delta positivo | Delta negativo |
|---|---|---|
| KPI positivo (Completos, Mapeados, % SMD, Leva A, HR, Fiorino, Carregamento) | melhorou | piorou |
| KPI negativo (Rupturas, Erros, Divergências) | piorou | melhorou |

- Se melhorou mas ainda está abaixo da meta → **"melhorou mas distante da meta"**
- Delta zero ou sem dados → **"estável / sem registro"**

**c) Incorporar a ideia central:**
- A ideia central traz contexto que pode não aparecer nos KPIs (problemas pontuais, foco da semana)
- Ela é o fio condutor da mensagem — incorporar mesmo que os dados não mostrem explicitamente
- Se contradiz os dados: **os dados prevalecem**, mas mencionar o contexto
- Se intensifica ("MUITO distante", "precisamos melhorar bastante"): **refletir a intensidade** — não suavizar

---

### 4. Gerar a mensagem

**Formato obrigatório (máx. 3 frases):**

```
[DESCONTO] na Bonificação. [O que aconteceu com os KPIs, citando os nomes reais]. [O que precisa melhorar ou manter.]
```

**Exemplos reais desta semana (21/05/2026):**

> -25% na Bonificação. Os pedidos mapeados de mercearia e fresh registraram melhora, mas ambos seguem distantes da meta, com o mapeamento fresh ainda muito abaixo do objetivo. Precisamos acelerar a evolução para atingir as metas.

> -20% na Bonificação. A leva A e o HR registraram melhora, mas o carregamento SMD e o Fiorino pioraram e todos os indicadores seguem distantes da meta. Precisamos retomar o carregamento e conter a piora do Fiorino para evoluir na semana.

> VALOR DA BONIFICAÇÃO ZERADO. Na etapa de inclusão, um SKU foi dado como ruptura e por erro de processo a caixa foi enviada vazia ao cliente, sendo o ocorrido fechado no crachá do coordenador, impedindo a identificação dos colaboradores responsáveis. Por essa razão, o setor Faltantes Noite do FC3 terá a bonificação zerada integralmente nesta semana.

**Regras:**
1. Máximo 3 frases. Sem saudação. Sem assinatura. Sem emoji. Sem markdown.
2. Com desconto: primeira frase sempre `"[DESCONTO] na Bonificação."`
3. Desconto = 0% por erro/processo especial: começar com `"VALOR DA BONIFICAÇÃO ZERADO."` e explicar o motivo
4. Desconto = 0% ou vazio sem situação especial: começar direto pelo resultado, sem mencionar bonificação
5. Citar os nomes reais dos indicadores: SMD, leva A, HR, Fiorino, pedidos mapeados, completos fresh/mercearia, rupturas, divergências de estoque
6. **NUNCA mencionar números, percentuais ou valores** — só direção (melhorou, piorou, distante da meta)
7. Tom direto e factual — sem frases genéricas motivacionais
8. Se turno específico (não TODOS): mencionar o turno na mensagem
9. Gerar mensagem **apenas para os setores que estão na side table** — nunca adicionar setores de semanas anteriores

---

### 5. Escrever na planilha

Montar JSON e executar:

```powershell
cd "C:\Users\stella.vieira\Documents\GitHub\assiduidade-agent"
$env:PYTHONIOENCODING = "utf-8"
python gerar_mensagens_fc.py '<JSON_AQUI>'
```

**Formato do JSON:**
```json
{
  "spreadsheet_id": "1j-mRJN2IHR3LjHaFtVgHtg2pH1XS3becphjBVjD02Ug",
  "data": "DD/MM/AAAA",
  "mensagens": [
    {
      "fc": "FC1",
      "setor": "PRE EXPEDICAO",
      "atribuicao": "TODAS",
      "turno": "TODOS",
      "matricula": "",
      "desconto": "-25%",
      "ideia_central": "...",
      "mensagem": "-25% na Bonificação. ..."
    }
  ]
}
```

**Script:** `C:\Users\stella.vieira\Documents\GitHub\assiduidade-agent\gerar_mensagens_fc.py`

Escreve na aba **"Mensagens"** com as colunas: DATA | FC | SETOR | ATRIBUIÇÃO | TURNO | MATRÍCULA | DESCONTO | IDEIA CENTRAL | MENSAGEM GERADA

**Saída esperada:**
```
OK: 8 mensagens escritas na aba 'Mensagens'
LINK=https://docs.google.com/spreadsheets/d/.../edit#gid=...
```

---

### 6. Gerar PDFs e relatório final

Após escrever na planilha, gerar **dois PDFs separados** com reportlab, salvos em `C:\Users\stella.vieira\Downloads\Relatorios_FC\`.

---

**PDF 1 — Mensagens KPI** (`mensagens_kpi_fc_DDMMAAAA.pdf`):

Contém **somente as mensagens geradas nesta semana** — apenas os setores que estavam na side table.

- Cabeçalho verde escuro (#274e13) com título e data
- Seção por FC com fundo verde escuro, texto branco
- Cada mensagem em card cinza claro (#f5f5f5): SETOR em negrito verde, tags de atribuição/turno/desconto, texto da mensagem

**Não incluir** mensagens de semanas anteriores, mensagens padrão de vistoria, nem setores que não estavam na side table desta semana.

---

**PDF 2 — Vistoria Picking Individual** (`vistoria_picking_DDMMAAAA.pdf`):

Gerado a partir da aba **"Vistoria Semana"** da planilha (colunas: PERÍODO | MATRÍCULA | FC | % DESCONTO | MENSAGEM).

- Título laranja (#b45309): "Mensagens de Vistoria Picking" + período
- Agrupado por FC (cabeçalho por FC com contagem de colaboradores)
- Cada entrada numerada: **Matrícula XXXXX** + desconto + mensagem completa
- Zerados (0%) destacados com borda vermelha e fundo vermelho claro
- Rodapé com total de entradas

Formatação:
- Matrícula: `int(float(raw))` — ex: "16705.0" → "16705"; "#N/A" → "N/A"
- Desconto: float → percentual — ex: "-0.4" → "-40%"; "0.0" → "0%"

---

**6b. Exibir relatório no chat** neste formato:

```
## 📊 Relatório de Mensagens FC — DD/MM/AAAA

### FC1
**[SETOR]** | [turno/atribuição se não for TODOS/TODAS]
> [MENSAGEM GERADA]

### FC2
...

### FC3
...

---
## 🔍 Vistoria Picking — Período: [PERÍODO]
FC1: X colaboradores | FC2: Y colaboradores | FC3: Z colaboradores

---
✅ X mensagens KPI escritas na planilha
📄 PDF KPI:     C:\Users\stella.vieira\Downloads\Relatorios_FC\mensagens_kpi_fc_DDMMAAAA.pdf
📄 PDF Vistoria: C:\Users\stella.vieira\Downloads\Relatorios_FC\vistoria_picking_DDMMAAAA.pdf
🔗 Planilha: [LINK]
```

---

### 1c. Processar planilha de Gestão de Estoque (Performance inventário)

Baixar separadamente a planilha `1E9ZXe2LtYySON6YYZYpn3BFEk-RiU-NsBJzmg6FUqrw` como xlsx e ler as abas **FC1**, **FC2** e **FC3**.

**Estrutura de cada aba:**
| MATRÍCULA | NOME | PROMOTORAS (pts) | DETRATORAS (pts) | PONTUAÇÃO FINAL | POSIÇÕES TOTAIS | ERROS | % ACERTOS | JUSTIFICATIVA |

- **Incluir apenas linhas com JUSTIFICATIVA preenchida**
- O **FC** da mensagem vem do nome da aba (FC1, FC2 ou FC3)
- A **JUSTIFICATIVA** é o contexto (equivalente à ideia central) — o agente **reformula** em mensagem no padrão sem números/percentuais

**Casos típicos de JUSTIFICATIVA e como gerar a mensagem:**

| Caso | Mensagem gerada |
|---|---|
| Não atingiu mínimo de posições | "Você não atingiu o mínimo de posições necessário para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque." |
| Não atingiu acurácia mínima | "Você não atingiu a acuracidade mínima necessária para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque." |
| Não atingiu posições E acurácia | "Você não atingiu o mínimo de posições nem a acuracidade mínima necessários para pontuar pela atividade de inventário de Gestão de Estoque nesta semana. Valide junto às suas lideranças dentro de Gestão de Estoque." |
| Detratora por baixo desempenho/acurácia | "Você recebeu uma detratora pela atividade de inventário de Gestão de Estoque nesta semana devido ao baixo desempenho nas contagens. Precisamos reduzir os erros para conseguir pontuar positivamente por essa atividade e ficar mais próximo da bonificação." |

**Regras:**
- **NUNCA incluir números, percentuais ou valores** na mensagem — só direção qualitativa
- SETOR = `"GESTÃO DE ESTOQUE"`, ATRIBUIÇÃO = `"INVENTÁRIO"`, TURNO = vazio, DESCONTO = vazio
- Essas mensagens têm prioridade abaixo de KPI individuais zerados por coordenadores (seção 5 do SQL), mas acima das mensagens setoriais

```python
import openpyxl, base64, io

# Baixar planilha GE
# fileId = '1E9ZXe2LtYySON6YYZYpn3BFEk-RiU-NsBJzmg6FUqrw'
# exportMimeType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

wb_ge = openpyxl.load_workbook(io.BytesIO(base64.b64decode(content_ge)))
mensagens_ge = []
for fc_nome in ['FC1', 'FC2', 'FC3']:
    ws = wb_ge[fc_nome]
    rows = list(ws.iter_rows(values_only=True))
    header = rows[0]  # MATRÍCULA, NOME, ..., JUSTIFICATIVA
    idx_mat = 0
    idx_just = 8  # coluna JUSTIFICATIVA (índice 8)
    for row in rows[1:]:
        matricula = row[idx_mat]
        justificativa = row[idx_just]
        if not justificativa:
            continue
        mensagens_ge.append({
            'matricula': str(int(float(matricula))) if matricula else None,
            'fc': fc_nome,
            'justificativa': str(justificativa),
        })
```

---

### 1b. Processar aba "Fiscais de Picking"

Após baixar o xlsx, ler e filtrar a aba "Fiscais de Picking" para o período da semana atual:

```python
ws_fiscais = wb['Fiscais de Picking']
rows_fiscais = list(ws_fiscais.iter_rows(values_only=True))

PERIODO_ATUAL = "06.08-12.08"  # ajustar conforme semana

fiscais_semana = []
for row in rows_fiscais[1:]:  # pular cabeçalho
    parsed = [extract_val(c) for c in row]
    if not any(v for v in parsed):
        continue
    matricula, _, operador, setor, atribuicao, turno, fc, data_apur, pct_desconto, mensagem = parsed[:10]
    if data_apur and PERIODO_ATUAL in str(data_apur):
        fiscais_semana.append({
            'matricula': int(float(matricula)) if matricula else None,
            'operador': operador,
            'setor': setor,
            'atribuicao': atribuicao,
            'turno': turno,
            'fc': fc,
            'pct_desconto': pct_desconto,  # float: 0.0 = 0%, -1.0 = -100%
            'mensagem': mensagem,
        })
```

**Integração com o SQL:**
- Cada entrada com `pct_desconto = 0.0` ou `pct_desconto = -1.0` → `MULT_MATRICULA = 0.0` (bonificação zerada)
- Outras proporções (ex: -0.5) → `MULT_MATRICULA` = `1.0 + pct_desconto`
- A `mensagem` da coluna vai direto como `OBSERVACAO_KPI` para essa matrícula
- Prioridade: Fiscais de Picking têm prioridade sobre mensagens setoriais mas ficam abaixo de KPI individuais zerados por coordenadores
- Adicionar ao neutralizador: se a matrícula já tem MULT_MATRICULA zerado por outra regra, MULT_SETOR deve ser 1.0 para essa matrícula

**Exibir no relatório do chat** quantos fiscais foram encontrados para o período:
```
## 📋 Fiscais de Picking — Período: [PERIODO]
FC1: X | FC2: Y | FC3: Z
```

---

## Atualização semanal da consulta SQL (kpis_operacao_query.sql)

Após gerar as mensagens, atualizar `C:\Users\stella.vieira\Documents\GitHub\assiduidade-agent\kpis_operacao_query.sql`:

1. **MULT_SETOR** — atualizar descontos por setor/FC conforme mensagens geradas. Incluir **apenas os setores da semana atual**. Remover setores de semanas anteriores que não se repetem.
2. **OBSERVACAO_KPI** — atualizar mensagens dos setores. Incluir **apenas os setores da semana atual**. Não manter mensagens de setores que não estão na side table desta semana.
3. **MULT_MATRICULA / OBSERVACAO_KPI** — atualizar listas de matrículas reincidentes conforme picking da semana.
4. **Fiscais de Picking** — adicionar matrículas da aba "Fiscais de Picking" filtradas pela semana atual ao MULT_MATRICULA e OBSERVACAO_KPI. Remover matrículas de semanas anteriores que não constam na aba para o período atual.

A consulta é rodada no dia seguinte à geração das mensagens (skill separada).

---

---

## 7. Publicar 00_kpis_operacao.sql no repositório performance-dataform

Após atualizar `kpis_operacao_query.sql` (passo anterior), copiar o conteúdo para o repositório do workflow e fazer push:

```powershell
# 1. Copiar arquivo atualizado para o repositório do workflow
Copy-Item `
  "C:\Users\stella.vieira\Documents\GitHub\assiduidade-agent\kpis_operacao_query.sql" `
  "C:\Users\stella.vieira\Documents\GitHub\performance-dataform\jobs\qa\00_kpis_operacao.sql" `
  -Force

# 2. Commit e push
cd "C:\Users\stella.vieira\Documents\GitHub\performance-dataform"
git add jobs/qa/00_kpis_operacao.sql
git commit -m "chore: atualiza KPIs operação semana $(Get-Date -Format 'yyyy-MM-dd')"
git push
```

**Saída esperada:**
```
[main abc1234] chore: atualiza KPIs operação semana 2026-07-17
1 file changed, N insertions(+), N deletions(-)
```

Se o push falhar (ex: conflito), informar o erro exato para a Stella resolver antes de prosseguir. Não tentar force push.

---

## Restrições

- Gerar mensagem **somente para setores presentes na side table desta semana** — nunca carregar mensagens de semanas passadas para setores não configurados
- Não mencionar valores, percentuais ou números nas mensagens geradas — apenas direção
- Dados de CPF, email ou telefone de clientes não devem aparecer em nenhuma parte do fluxo
