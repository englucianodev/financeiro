-- LIMPEZA DE IMPORTAÇÕES ÓRFÃS — NÃO EXECUTE SEM APROVAR A LISTA
-- Pré-requisitos: migrations 023, 024 e 025 aplicadas (026 é opcional para este script).
-- Antes: rode 00_fotografia.sql e guarde o CSV. Depois: rode de novo; lançamentos, saldos e faturas devem sair iguais.
--
-- 1) Cole abaixo os IDs aprovados (coluna "importacao" do 02_importacoes_orfas.sql marcadas como ÓRFÃ).
-- 2) Rode o script inteiro de uma vez. Ele confere de novo que cada importação NÃO tem lançamentos;
--    se alguma tiver, aborta tudo sem alterar nada.
--
-- O que faz (opção recomendada): NÃO apaga. Guarda cópia e marca a importação como 'undone',
-- que é exatamente o que libera a reimportação do arquivo. Nenhum lançamento, conta, cartão,
-- categoria, notificação ou e-mail é tocado.
--
-- Como restaurar: veja o bloco RESTAURAR no final.

begin;

create temporary table alvo(id uuid primary key) on commit drop;
insert into alvo(id) values
  -- ('00000000-0000-0000-0000-000000000000'),
  ('COLE-AQUI-O-ID-APROVADO');

-- Conferência: cada alvo existe, está ativo e não tem nenhum lançamento/compra restante.
do $$
declare r record; restantes int;
begin
  for r in select m.* from cc_imports m join alvo a on a.id=m.id loop
    select count(*) into restantes from (
      select 1 from jsonb_array_elements(case when jsonb_typeof(r.summary->'rows')='array' then r.summary->'rows' else '[]' end) x
        join cc_lines l on l.id=nullif(x->>'line_id','')::uuid where x->>'decision'='new'
      union all
      select 1 from cc_import_items m join cc_lines l on l.id=m.entity_id where m.import_id=r.id and m.created and m.table_name='cc_lines'
      union all
      select 1 from cc_import_items m join cc_purchases p on p.id=m.entity_id where m.import_id=r.id and m.created and m.table_name='cc_purchases'
    ) s;
    if restantes>0 then raise exception 'Importação % ainda tem % registro(s). Nada foi alterado.',r.id,restantes;end if;
    if r.status<>'active' then raise exception 'Importação % não está ativa. Nada foi alterado.',r.id;end if;
  end loop;
  if (select count(*) from alvo)<>(select count(*) from cc_imports m join alvo a on a.id=m.id) then raise exception 'Algum ID não existe. Nada foi alterado.';end if;
end $$;

-- Backup (fica permanente no banco, em tabelas próprias)
create table if not exists public.backup_limpeza_cc_imports as select now() as backup_em, m.* from cc_imports m where false;
create table if not exists public.backup_limpeza_cc_import_items as select now() as backup_em, i.* from cc_import_items i where false;
insert into public.backup_limpeza_cc_imports select now(), m.* from cc_imports m join alvo a on a.id=m.id;
insert into public.backup_limpeza_cc_import_items select now(), i.* from cc_import_items i join alvo a on a.id=i.import_id;
revoke all on public.backup_limpeza_cc_imports, public.backup_limpeza_cc_import_items from anon, authenticated;

-- Limpeza: marca como desfeita (libera reimportar), registrando o motivo.
update cc_imports m set status='undone', undone_at=now(),
  effects=m.effects||jsonb_build_object('force_cleared',now(),'motivo','lançamentos apagados manualmente no Supabase')
from alvo a where a.id=m.id;

-- Prévia do resultado antes de confirmar:
select m.id, m.file_name, m.status, m.undone_at from cc_imports m join alvo a on a.id=m.id;

commit;   -- troque por "rollback;" se quiser só simular

-- ===================== OPÇÃO B (só se você preferir APAGAR o registro) =====================
-- Rode depois do bloco acima, com os mesmos IDs. Apaga apenas o histórico (cc_import_items e cc_imports).
-- begin;
-- delete from cc_import_items where import_id in ('COLE-AQUI-O-ID-APROVADO');
-- delete from cc_imports where id in ('COLE-AQUI-O-ID-APROVADO') and status='undone';
-- commit;

-- ===================== RESTAURAR =====================
-- Opção recomendada (marcação):
--   update cc_imports m set status=b.status, undone_at=b.undone_at, effects=b.effects
--   from backup_limpeza_cc_imports b where b.id=m.id;
-- Se usou a opção B (apagou):
--   insert into cc_imports select id,household_id,card_id,invoice_id,file_hash,file_name,actor_id,summary,created_at,status,provenance_version,effects,undone_at,undone_by,reference_cycle,bank,statement_due,statement_closing,statement_total,adjustment_line
--   from backup_limpeza_cc_imports;   -- confira a ordem das colunas com: select * from cc_imports limit 0;
--   insert into cc_import_items select import_id,household_id,table_name,entity_id,created,snapshot from backup_limpeza_cc_import_items;
