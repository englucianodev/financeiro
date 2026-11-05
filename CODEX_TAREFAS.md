# Continuidade — modernização visual e funcional

## Entregue no código local

- Dashboard mobile, nome dinâmico, cartões, cores, gráficos, animações leves e navegação inferior.
- Salários, recorrências por intervalos, categorias editáveis e desativáveis, valores variáveis, edição de futuros pendentes.
- Projeções acumuladas em seis períodos de 30 dias; simulador até uma data com o mesmo motor.
- Calendário com valores/descrições e painel diário; transferências agendadas na projeção e calendário.
- Convites personalizados, expiração, hash, uso único, revogação e limite de tentativas; grupos com mais de duas pessoas.
- Migrations aditivas `008_modernization.sql` e `009_scheduled_transfers.sql`; `setup.sql` atualizado para instalações novas.

## Validação

TypeScript, testes financeiros e de nomes, testes de banco (migrations 001–009, RLS/RPCs), instalador e dez testes Playwright passaram. Build de produção passou. Captura mobile em 390px inspecionada, sem rolagem horizontal.

## Implantação pendente

Nenhuma alteração em dados reais ou deploy foi realizada. Aplicar somente migrations pendentes em Supabase de homologação, testar com autenticação real e depois publicar o frontend na Vercel. Confira se o projeto Supabase das variáveis da Vercel é o correto: o diagnóstico anterior de `nossascoisinhas.vercel.app` retornou PGRST205 para `household_members`.

Consulte o README para procedimentos e limites: recorrências finitas (um ano sem término), sem renovação automática em background, relatórios por competência, sem conciliação/paginação/exportação/reserva mínima e investimentos informativos.
