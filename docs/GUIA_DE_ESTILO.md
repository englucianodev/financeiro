# Duo · guia de estilo

Duo é a identidade do app de finanças do casal. O símbolo são dois círculos que se cruzam: cada pessoa com o seu dinheiro e, no meio, o que é dos dois.

Tudo vem dos tokens definidos no topo de `app/globals.css`. Não use cores, tamanhos ou fontes soltos em componentes.

## Marca

| Item | Uso |
|---|---|
| Nome | **Duo** (assinatura: "Duo · finanças a dois") |
| Símbolo | `components/duo-logo.tsx` (no app) e `app/icon.svg` (ícone do navegador) |
| Fundo do símbolo | `--brand-deep` com círculos claro e coral |

Os e-mails de notificação não usam a marca e não devem ser alterados por mudanças visuais.

## Cores

| Token | Claro | Escuro | Uso |
|---|---|---|---|
| `--bg` | #f5f4fa | #121326 | Fundo da página |
| `--panel` | #ffffff | #1b1d36 | Cartões, diálogos, campos |
| `--ink` | #1d1e3a | #eceefe | Texto principal |
| `--muted` | #62637f | #a6a8c8 | Texto de apoio, rótulos |
| `--line` | #e3e2ee | #2e3150 | Bordas e divisórias |
| `--accent` | #4146b8 | #8e93f2 | Botão principal, links, seleção |
| `--accent-soft` | #ecebf8 | #262a52 | Fundos de seleção e destaque leve |
| `--brand-deep` | #2b2d6e | #2b2d6e | Cabeçalho, saldo disponível, investimentos |
| `--coral` | #ef8a5a | #f29a70 | Botão "+", detalhes da marca (nunca para texto pequeno) |

Cores de situação (iguais em todas as telas, separadas da cor da marca):

| Token | Significado |
|---|---|
| `--ok` / `--ok-soft` | Pago, recebido, entradas, crédito |
| `--warn` / `--warn-soft` | Fechada, a vencer, precisa de atenção |
| `--late` / `--late-soft` | Atrasado, saídas, erro |

## Tipografia

| Papel | Fonte | Onde |
|---|---|---|
| Títulos e números grandes | **Sora** (600–700) | `h1`–`h4`, totais, saldos |
| Texto e interface | **Inter** (400–600) | Todo o resto |

As fontes ficam em `app/fonts` (licença SIL OFL) e carregam sem depender da internet.

Escala fixa, sem tamanhos fora dela:

| Token | Tamanho | Uso |
|---|---|---|
| `--t-12` | 12px | Datas, rótulos, legendas, chips |
| `--t-13` | 13px | Texto de apoio, botões compactos |
| `--t-14` | 14px | Texto padrão, botões |
| `--t-16` | 16px | Subtítulos (`h3`), valores em listas |
| `--t-20` | 20px | Títulos de seção (`h2`) |
| `--t-26` | 26px | Título da página (`h1`), indicadores |
| `--t-30` | 30px | Total da fatura |

Números sempre com `font-variant-numeric: tabular-nums` para alinharem.

## Componentes

**Botões** (dois tamanhos, sempre):

- Padrão: 40px de altura (`--h-btn`), texto 14px.
- Compacto: 34px (`--h-btn-sm`), texto 13px, para ações dentro de listas.
- Principal: fundo `--accent`. É o padrão de `<button>` e de `.btn`.
- Secundário: fundo `--panel` com borda. Automático em `<button type="button">` e em `.btn.ghost`.
- Link: `.btn.link` ou `.link-button`.
- Uma ação principal por bloco. Cancelar, voltar e fechar são secundários.

**Raios:** 8px (`--r-sm`, chips e detalhes), 12px (`--r-md`, botões e campos), 16px (`--r-lg`, cartões e diálogos).

**Cartões:** `.card` com borda `--line`, fundo `--panel` e sombra leve. Só em blocos que precisam se separar.

**Chips de situação:** `.chip.ok`, `.chip.warn`, `.chip.late`, `.chip.neutral`.

**Linhas de lançamento** (fatura do cartão): data · descrição com categoria abaixo · parcela (`3/10`) · valor à direita. Tocar abre a edição.

**Diálogos:** `<dialog class="account-dialog">`, título `h2`, ações no fim, a principal primeiro.

## Textos

- Rótulos curtos e diretos ("Pagar fatura", "Importar", "Salvar categoria").
- Dicas só onde evitam erro; nada de slogans ou frases decorativas.
- Ações destrutivas sempre pedem confirmação e dizem o que vai acontecer.
- Mensagens de erro explicam o que fazer.

## Celular

Abaixo de 760px: grades viram 1 ou 2 colunas, a navegação fica na barra inferior e nada pode rolar para o lado. As telas são testadas em 390px.
