-- ARGYR · policies.sql — ejecutar DESPUÉS de schema.sql y functions.sql
-- Roles: dueno (todo) · encargado (stock, precios, anulaciones, cierres) · cajero (vender y su propio turno).
-- Las escrituras sensibles (ventas, pagos, turnos, stock por venta) NO tienen política de escritura directa:
-- solo se hacen por las funciones RPC (security definer), que validan permisos en el servidor.

-- Cerrar la puerta a usuarios anónimos
revoke all on all tables in schema public from anon;

-- Activar RLS en TODAS las tablas
do $$
declare t text;
begin
  for t in select unnest(array[
    'negocios','miembros','categorias','proveedores','productos','producto_costos','codigos_barras',
    'listas_precio','precios','actualizaciones_precios','historial_precios','clientes','cuenta_corriente_mov',
    'cajas','turnos_caja','movimientos_dinero','ventas','venta_items','venta_item_costos','pagos',
    'stock_movimientos','compras','compra_items','pagos_proveedor',
    'comprobantes_fiscales','auditoria'])
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ───────────── Negocio y miembros ─────────────
create policy negocios_select on public.negocios for select using (public.es_miembro(id));
create policy negocios_update on public.negocios for update using (public.es_dueno(id)) with check (public.es_dueno(id));

create policy miembros_select on public.miembros for select
  using (user_id = auth.uid() or public.es_dueno(negocio_id));
create policy miembros_write on public.miembros for all
  using (public.es_dueno(negocio_id)) with check (public.es_dueno(negocio_id));

-- ───────────── Grupo A: todos los miembros leen; dueño/encargado escriben ─────────────
do $$
declare t text;
begin
  for t in select unnest(array['categorias','productos','codigos_barras','listas_precio','precios','cajas'])
  loop
    execute format('create policy %I on public.%I for select using (public.es_miembro(negocio_id))', t||'_select', t);
    execute format('create policy %I on public.%I for insert with check (public.es_gestor(negocio_id))', t||'_insert', t);
    execute format('create policy %I on public.%I for update using (public.es_gestor(negocio_id)) with check (public.es_gestor(negocio_id))', t||'_update', t);
    execute format('create policy %I on public.%I for delete using (public.es_dueno(negocio_id))', t||'_delete', t);
  end loop;
end $$;

-- ───────────── Grupo B: solo dueño/encargado (el cajero NO ve costos, compras, gastos, etc.) ─────────────
do $$
declare t text;
begin
  for t in select unnest(array[
    'producto_costos','venta_item_costos','historial_precios','actualizaciones_precios','proveedores',
    'compras','compra_items','pagos_proveedor','comprobantes_fiscales'])
  loop
    execute format('create policy %I on public.%I for all using (public.es_gestor(negocio_id)) with check (public.es_gestor(negocio_id))', t||'_gestor', t);
  end loop;
end $$;

-- ───────────── Libros append-only (sin update ni delete) ─────────────
create policy stock_mov_select on public.stock_movimientos for select using (public.es_gestor(negocio_id));
create policy stock_mov_insert on public.stock_movimientos for insert
  with check (public.es_gestor(negocio_id) and tipo <> 'venta');           -- las ventas solo por registrar_venta

create policy cc_mov_select on public.cuenta_corriente_mov for select using (public.es_gestor(negocio_id));
create policy cc_mov_insert on public.cuenta_corriente_mov for insert
  with check (public.es_gestor(negocio_id) and tipo in ('pago','ajuste'));  -- fiado/anulación solo por RPC

-- ───────────── Clientes: el cajero puede dar de alta rápido, no editar ni ver ajenos de otros negocios ─────────────
create policy clientes_select on public.clientes for select using (public.es_miembro(negocio_id));
create policy clientes_insert on public.clientes for insert with check (public.es_miembro(negocio_id));
create policy clientes_update on public.clientes for update
  using (public.es_gestor(negocio_id)) with check (public.es_gestor(negocio_id));
create policy clientes_delete on public.clientes for delete using (public.es_dueno(negocio_id));

-- ───────────── Turnos, movimientos de caja y ventas ─────────────
create policy turnos_select on public.turnos_caja for select
  using (public.es_gestor(negocio_id) or cajero_id = auth.uid());

-- movimientos_dinero: solo lectura directa para dueño/encargado; se escribe únicamente por RPC
create policy mov_dinero_select on public.movimientos_dinero for select using (public.es_gestor(negocio_id));

create policy ventas_select on public.ventas for select
  using (public.es_gestor(negocio_id) or cajero_id = auth.uid());

create policy venta_items_select on public.venta_items for select
  using (public.es_gestor(negocio_id)
         or exists (select 1 from public.ventas v where v.id = venta_id and v.cajero_id = auth.uid()));

create policy pagos_select on public.pagos for select
  using (public.es_gestor(negocio_id)
         or exists (select 1 from public.ventas v where v.id = venta_id and v.cajero_id = auth.uid()));

-- ───────────── Auditoría: solo el dueño la lee; nadie escribe directo (la llenan las RPC) ─────────────
create policy auditoria_select on public.auditoria for select using (public.es_dueno(negocio_id));

-- ───────────── Prueba rápida sugerida (SQL Editor, simulando a un cajero) ─────────────
-- begin;
--   select set_config('request.jwt.claims', '{"sub":"<UUID_DEL_CAJERO>","role":"authenticated"}', true);
--   set local role authenticated;
--   select * from public.producto_costos;          -- debe devolver 0 filas
--   update public.precios set precio = 1;          -- debe afectar 0 filas
--   select public.anular_venta('<UUID_VENTA>', 'prueba');   -- debe fallar: sin_permiso
-- rollback;
