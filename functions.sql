-- ARGYR · functions.sql — ejecutar DESPUÉS de schema.sql y ANTES de policies.sql
-- Contiene: helpers de permisos, triggers y RPC transaccionales (la lógica crítica vive acá, no en el navegador).
--
-- REDONDEO (documentado): total_línea = round(cantidad × precio_unit) − descuento_línea.
-- round() de numeric redondea "mitad hacia afuera de cero" al centavo. Ej.: 0,750 × 980000 = 735000 ($ 7.350).
-- descuento_monto = round(subtotal × pct / 100). total = subtotal − descuento_monto + redondeo.
-- La suma de pagos debe ser EXACTAMENTE igual al total o la venta no se confirma.

-- ───────────── Helpers de permisos (security definer: evitan recursión de RLS) ─────────────
create or replace function public.rol_en(p_negocio uuid) returns text
language sql stable security definer set search_path = public as $$
  select rol from public.miembros where negocio_id = p_negocio and user_id = auth.uid()
$$;

create or replace function public.es_miembro(p_negocio uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.miembros where negocio_id = p_negocio and user_id = auth.uid())
$$;

create or replace function public.es_gestor(p_negocio uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.miembros
                 where negocio_id = p_negocio and user_id = auth.uid() and rol in ('dueno','encargado'))
$$;

create or replace function public.es_dueno(p_negocio uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.miembros
                 where negocio_id = p_negocio and user_id = auth.uid() and rol = 'dueno')
$$;

-- ───────────── Triggers genéricos ─────────────
create or replace function public.trg_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger productos_updated  before update on public.productos  for each row execute function public.trg_updated_at();
create trigger clientes_updated   before update on public.clientes   for each row execute function public.trg_updated_at();
create trigger precios_updated    before update on public.precios    for each row execute function public.trg_updated_at();
create trigger costos_updated     before update on public.producto_costos for each row execute function public.trg_updated_at();

-- Los campos derivados (stock_actual, saldo_cc) solo los toca el sistema, nunca el cliente
create or replace function public.trg_guard_derivados() returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('app.derivado_ok', true), '') <> 'on' then
    if tg_table_name = 'productos' then
      new.stock_actual := case when tg_op = 'INSERT' then 0 else old.stock_actual end;
    elsif tg_table_name = 'clientes' then
      new.saldo_cc := case when tg_op = 'INSERT' then 0 else old.saldo_cc end;
    end if;
  end if;
  return new;
end $$;

create trigger productos_guard before insert or update on public.productos
  for each row execute function public.trg_guard_derivados();
create trigger clientes_guard  before insert or update on public.clientes
  for each row execute function public.trg_guard_derivados();

create or replace function public.trg_stock_mov() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.derivado_ok', 'on', true);
  update public.productos set stock_actual = stock_actual + new.cantidad where id = new.producto_id;
  perform set_config('app.derivado_ok', '', true);
  return new;
end $$;
create trigger stock_mov_aplicar after insert on public.stock_movimientos
  for each row execute function public.trg_stock_mov();

create or replace function public.trg_cc_mov() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.derivado_ok', 'on', true);
  update public.clientes set saldo_cc = saldo_cc + new.monto where id = new.cliente_id;
  perform set_config('app.derivado_ok', '', true);
  return new;
end $$;
create trigger cc_mov_aplicar after insert on public.cuenta_corriente_mov
  for each row execute function public.trg_cc_mov();

-- Código de barras automático: al crear/cambiar el código del producto se genera su código 'code128'
create or replace function public.trg_producto_codigo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.codigos_barras (negocio_id, producto_id, codigo, tipo)
    values (new.negocio_id, new.id, new.codigo, 'code128');
  elsif new.codigo is distinct from old.codigo then
    update public.codigos_barras set codigo = new.codigo
    where producto_id = new.id and tipo = 'code128' and codigo = old.codigo;
  end if;
  return new;
end $$;
create trigger productos_codigo_barras after insert or update of codigo on public.productos
  for each row execute function public.trg_producto_codigo();

-- Historial de precios automático (acepta app.actualizacion_id / app.motivo_precio de una actualización masiva)
create or replace function public.trg_precios_historial() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.precio is distinct from old.precio then
    insert into public.historial_precios
      (negocio_id, producto_id, lista_id, precio_anterior, precio_nuevo, motivo, actualizacion_id, usuario)
    values
      (new.negocio_id, new.producto_id, new.lista_id,
       case when tg_op = 'UPDATE' then old.precio end, new.precio,
       nullif(current_setting('app.motivo_precio', true), ''),
       nullif(current_setting('app.actualizacion_id', true), '')::uuid,
       auth.uid());
  end if;
  return new;
end $$;
create trigger precios_historial after insert or update of precio on public.precios
  for each row execute function public.trg_precios_historial();

-- Turno cerrado = inmutable
create or replace function public.trg_turno_inmutable() returns trigger language plpgsql as $$
begin
  if old.estado = 'cerrado' then
    raise exception 'turno_cerrado: un turno cerrado no se puede modificar';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger turnos_inmutables before update or delete on public.turnos_caja
  for each row execute function public.trg_turno_inmutable();

create or replace function public.trg_mov_caja_turno_abierto() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from public.turnos_caja where id = new.turno_id and estado = 'abierto') then
    raise exception 'turno_cerrado: no se pueden agregar movimientos a un turno cerrado';
  end if;
  return new;
end $$;
create trigger mov_caja_abierto before insert on public.movimientos_caja
  for each row execute function public.trg_mov_caja_turno_abierto();

-- ───────────── RPC: alta del negocio ─────────────
create or replace function public.crear_negocio(p_nombre text default 'ARGYR') returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'sin_sesion'; end if;
  insert into public.negocios (nombre) values (coalesce(nullif(trim(p_nombre), ''), 'ARGYR')) returning id into v_id;
  insert into public.miembros (user_id, negocio_id, rol) values (auth.uid(), v_id, 'dueno');
  insert into public.cajas (negocio_id, nombre) values (v_id, 'Caja 1');
  insert into public.listas_precio (negocio_id, nombre, es_default) values (v_id, 'Mostrador', true);
  return v_id;
end $$;

-- Sugiere el próximo código de producto libre (000001, 000002…). El usuario igual puede tipear el suyo.
create or replace function public.siguiente_codigo(p_negocio uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v bigint; v_cod text;
begin
  if not public.es_gestor(p_negocio) then raise exception 'sin_permiso'; end if;
  loop
    update public.negocios set ultimo_codigo = ultimo_codigo + 1 where id = p_negocio returning ultimo_codigo into v;
    v_cod := lpad(v::text, 6, '0');
    exit when not exists (select 1 from public.productos where negocio_id = p_negocio and codigo = v_cod)
          and not exists (select 1 from public.codigos_barras where negocio_id = p_negocio and codigo = v_cod);
  end loop;
  return v_cod;
end $$;

-- ───────────── RPC: turnos ─────────────
create or replace function public.abrir_turno(p_caja uuid, p_fondo bigint default 0) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_caja public.cajas%rowtype; v_id uuid;
begin
  select * into v_caja from public.cajas where id = p_caja and activa;
  if not found then raise exception 'caja_invalida'; end if;
  if public.rol_en(v_caja.negocio_id) is null then raise exception 'sin_permiso'; end if;
  if p_fondo < 0 then raise exception 'fondo_invalido'; end if;
  if exists (select 1 from public.turnos_caja where caja_id = p_caja and estado = 'abierto') then
    raise exception 'turno_ya_abierto';
  end if;
  insert into public.turnos_caja (negocio_id, caja_id, cajero_id, fondo_inicial)
  values (v_caja.negocio_id, p_caja, auth.uid(), p_fondo) returning id into v_id;
  insert into public.auditoria (negocio_id, usuario, accion, entidad, entidad_id, despues)
  values (v_caja.negocio_id, auth.uid(), 'abrir_turno', 'turno', v_id, jsonb_build_object('fondo', p_fondo));
  return v_id;
end $$;

create or replace function public.cerrar_turno(p_turno uuid, p_conteo bigint, p_obs text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t public.turnos_caja%rowtype;
  v_efectivo bigint; v_ing bigint; v_egr bigint; v_esperado bigint; v_dif bigint; v_resumen jsonb;
begin
  select * into t from public.turnos_caja where id = p_turno for update;
  if not found then raise exception 'turno_invalido'; end if;
  if t.estado <> 'abierto' then raise exception 'turno_cerrado'; end if;
  if not (public.es_gestor(t.negocio_id) or (public.rol_en(t.negocio_id) = 'cajero' and t.cajero_id = auth.uid())) then
    raise exception 'sin_permiso';
  end if;
  if p_conteo is null or p_conteo < 0 then raise exception 'conteo_invalido'; end if;

  select coalesce(sum(p.monto), 0) into v_efectivo
    from public.pagos p join public.ventas v on v.id = p.venta_id
   where v.turno_id = p_turno and v.estado = 'cobrada' and p.medio = 'efectivo';
  select coalesce(sum(monto) filter (where tipo = 'ingreso'), 0),
         coalesce(sum(monto) filter (where tipo in ('egreso','retiro','gasto')), 0)
    into v_ing, v_egr from public.movimientos_caja where turno_id = p_turno;

  v_esperado := t.fondo_inicial + v_efectivo + v_ing - v_egr;
  v_dif := p_conteo - v_esperado;

  select jsonb_build_object(
    'tickets',        count(*) filter (where v.estado = 'cobrada'),
    'anulados',       count(*) filter (where v.estado = 'cancelada'),
    'total_vendido',  coalesce(sum(v.total) filter (where v.estado = 'cobrada'), 0),
    'descuentos',     coalesce(sum(v.descuento_monto) filter (where v.estado = 'cobrada'), 0),
    'por_medio', (select coalesce(jsonb_object_agg(medio, m), '{}'::jsonb) from (
                    select p.medio, sum(p.monto) m
                      from public.pagos p join public.ventas v2 on v2.id = p.venta_id
                     where v2.turno_id = p_turno and v2.estado = 'cobrada' group by p.medio) x),
    'fondo_inicial', t.fondo_inicial, 'efectivo_cobrado', v_efectivo, 'ingresos', v_ing, 'egresos', v_egr
  ) into v_resumen from public.ventas v where v.turno_id = p_turno;

  update public.turnos_caja
     set estado = 'cerrado', cierre_ts = now(), conteo_efectivo = p_conteo,
         esperado_efectivo = v_esperado, diferencia = v_dif, resumen = v_resumen, observaciones = p_obs
   where id = p_turno;

  insert into public.auditoria (negocio_id, usuario, accion, entidad, entidad_id, despues)
  values (t.negocio_id, auth.uid(), 'cerrar_turno', 'turno', p_turno,
          jsonb_build_object('esperado', v_esperado, 'conteo', p_conteo, 'diferencia', v_dif));

  return jsonb_build_object('esperado', v_esperado, 'conteo', p_conteo, 'diferencia', v_dif, 'resumen', v_resumen);
end $$;

-- ───────────── RPC: registrar_venta (atómica e idempotente) ─────────────
-- p_items: [{"producto_id": "...", "cantidad": 0.75, "precio_unit": 980000 (opcional, solo encargado/dueño),
--            "descuento_linea": 0}]
-- p_pagos: [{"medio": "efectivo", "monto": 735000, "entregado": 1000000}, {"medio": "transferencia", "monto": ...}]
create or replace function public.registrar_venta(
  p_negocio uuid, p_client_uuid uuid, p_turno uuid, p_cliente uuid,
  p_items jsonb, p_pagos jsonb,
  p_descuento_pct numeric default 0, p_redondeo bigint default 0,
  p_notas text default null, p_origen text default 'online'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol text := public.rol_en(p_negocio);
  v_cfg jsonb; v_max_desc numeric; v_stock_neg boolean;
  v_turno public.turnos_caja%rowtype;
  v_ex public.ventas%rowtype;
  v_cliente public.clientes%rowtype;
  v_lista uuid; v_venta uuid := gen_random_uuid(); v_numero int;
  v_item jsonb; v_prod public.productos%rowtype; v_item_id uuid;
  v_cant numeric(12,3); v_precio bigint; v_bruto bigint; v_dl bigint; v_linea bigint; v_costo bigint;
  v_subtotal bigint := 0; v_desc bigint; v_total bigint; v_orden int := 0;
  v_pago jsonb; v_medio text; v_monto bigint; v_entregado bigint; v_vuelto bigint;
  v_pagado bigint := 0; v_fiado bigint := 0; v_vuelto_total bigint := 0; v_override boolean := false;
begin
  if v_rol is null then raise exception 'sin_permiso'; end if;

  -- Idempotencia: si ya existe, devolver la misma venta
  select * into v_ex from public.ventas where negocio_id = p_negocio and client_uuid = p_client_uuid;
  if found then
    return jsonb_build_object('id', v_ex.id, 'numero', v_ex.numero, 'total', v_ex.total, 'duplicada', true);
  end if;

  select config into v_cfg from public.negocios where id = p_negocio;
  v_max_desc  := coalesce((v_cfg->>'descuento_max_cajero')::numeric, 10);
  v_stock_neg := coalesce((v_cfg->>'stock_negativo')::boolean, true);

  select * into v_turno from public.turnos_caja where id = p_turno and negocio_id = p_negocio and estado = 'abierto';
  if not found then raise exception 'turno_no_abierto'; end if;
  if v_rol = 'cajero' and v_turno.cajero_id <> auth.uid() then raise exception 'turno_ajeno'; end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'venta_sin_items';
  end if;
  if p_pagos is null or jsonb_typeof(p_pagos) <> 'array' or jsonb_array_length(p_pagos) = 0 then
    raise exception 'venta_sin_pagos';
  end if;
  if p_descuento_pct < 0 or p_descuento_pct > 100 then raise exception 'descuento_invalido'; end if;
  if v_rol = 'cajero' and p_descuento_pct > v_max_desc then raise exception 'descuento_no_autorizado'; end if;
  if abs(p_redondeo) > 10000 then raise exception 'redondeo_invalido'; end if;

  if p_cliente is not null then
    select * into v_cliente from public.clientes
     where id = p_cliente and negocio_id = p_negocio and activo for update;
    if not found then raise exception 'cliente_invalido'; end if;
  end if;
  v_lista := coalesce(v_cliente.lista_id,
                      (select id from public.listas_precio where negocio_id = p_negocio and es_default));

  -- Número correlativo por caja (el UPDATE bloquea la fila y serializa)
  update public.cajas set ultimo_numero = ultimo_numero + 1 where id = v_turno.caja_id
  returning ultimo_numero into v_numero;

  insert into public.ventas (id, negocio_id, caja_id, turno_id, numero, cajero_id, cliente_id, lista_id,
                             client_uuid, origen, notas, estado)
  values (v_venta, p_negocio, v_turno.caja_id, p_turno, v_numero, auth.uid(), p_cliente, v_lista,
          p_client_uuid, case when p_origen = 'offline' then 'offline' else 'online' end, p_notas, 'pendiente');

  -- Líneas: el PRECIO sale de la base (el cliente no manda precios salvo override autorizado)
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_orden := v_orden + 1;
    select * into v_prod from public.productos
     where id = (v_item->>'producto_id')::uuid and negocio_id = p_negocio and activo for update;
    if not found then raise exception 'producto_invalido'; end if;

    v_cant := round((v_item->>'cantidad')::numeric, 3);
    if v_cant is null or v_cant <= 0 then raise exception 'cantidad_invalida'; end if;

    select precio into v_precio from public.precios where producto_id = v_prod.id and lista_id = v_lista;
    if v_precio is null then
      select p.precio into v_precio from public.precios p
        join public.listas_precio l on l.id = p.lista_id
       where p.producto_id = v_prod.id and l.es_default;
    end if;
    if v_precio is null then raise exception 'producto_sin_precio: %', v_prod.nombre; end if;

    if v_item ? 'precio_unit' and (v_item->>'precio_unit')::bigint <> v_precio then
      if v_rol not in ('dueno','encargado') then raise exception 'precio_no_autorizado'; end if;
      v_precio := (v_item->>'precio_unit')::bigint;
      v_override := true;
    end if;
    if v_precio < 0 then raise exception 'precio_invalido'; end if;

    v_bruto := round(v_cant * v_precio)::bigint;
    v_dl := coalesce((v_item->>'descuento_linea')::bigint, 0);
    if v_dl < 0 or v_dl > v_bruto then raise exception 'descuento_linea_invalido'; end if;
    if v_dl > 0 and v_rol = 'cajero' and v_dl * 100 > v_bruto * v_max_desc then
      raise exception 'descuento_no_autorizado';
    end if;
    v_linea := v_bruto - v_dl;

    select coalesce(nullif(c.costo_promedio, 0), c.costo_ultimo, 0) into v_costo
      from public.producto_costos c where c.producto_id = v_prod.id;
    v_costo := coalesce(v_costo, 0);

    insert into public.venta_items (negocio_id, venta_id, producto_id, orden, nombre, unidad, cantidad,
                                    precio_unit, iva_pct, descuento_linea, total)
    values (p_negocio, v_venta, v_prod.id, v_orden, v_prod.nombre, v_prod.unidad, v_cant,
            v_precio, v_prod.iva_pct, v_dl, v_linea)
    returning id into v_item_id;
    insert into public.venta_item_costos (venta_item_id, negocio_id, costo_unit)
    values (v_item_id, p_negocio, v_costo);

    if v_prod.controla_stock then
      if not v_stock_neg and v_prod.stock_actual < v_cant then
        raise exception 'stock_insuficiente: %', v_prod.nombre;
      end if;
      insert into public.stock_movimientos (negocio_id, producto_id, tipo, cantidad, costo_unit,
                                            ref_tipo, ref_id, usuario)
      values (p_negocio, v_prod.id, 'venta', -v_cant, v_costo, 'venta', v_venta, auth.uid());
    end if;

    v_subtotal := v_subtotal + v_linea;
  end loop;

  v_desc  := round(v_subtotal * p_descuento_pct / 100)::bigint;
  v_total := v_subtotal - v_desc + p_redondeo;
  if v_total < 0 then raise exception 'total_invalido'; end if;

  -- Pagos: la suma debe ser exactamente el total
  for v_pago in select * from jsonb_array_elements(p_pagos) loop
    v_medio := v_pago->>'medio';
    v_monto := (v_pago->>'monto')::bigint;
    if v_monto is null or v_monto <= 0 then raise exception 'pago_invalido'; end if;
    if v_medio not in ('efectivo','transferencia','cuenta_corriente') then
      raise exception 'medio_no_habilitado: %', v_medio;
    end if;
    if not coalesce((v_cfg->'medios_activos') ? v_medio, false) then
      raise exception 'medio_no_habilitado: %', v_medio;
    end if;
    v_entregado := null; v_vuelto := 0;
    if v_medio = 'efectivo' and v_pago ? 'entregado' then
      v_entregado := (v_pago->>'entregado')::bigint;
      if v_entregado < v_monto then raise exception 'efectivo_insuficiente'; end if;
      v_vuelto := v_entregado - v_monto;
    end if;
    if v_medio = 'cuenta_corriente' then v_fiado := v_fiado + v_monto; end if;
    insert into public.pagos (negocio_id, venta_id, medio, monto, entregado, vuelto, referencia)
    values (p_negocio, v_venta, v_medio, v_monto, v_entregado, v_vuelto, v_pago->>'referencia');
    v_pagado := v_pagado + v_monto;
    v_vuelto_total := v_vuelto_total + v_vuelto;
  end loop;

  if v_pagado <> v_total then
    raise exception 'pagos_no_coinciden: total % vs pagos %', v_total, v_pagado;
  end if;

  if v_fiado > 0 then
    if p_cliente is null then raise exception 'fiado_requiere_cliente'; end if;
    if v_cliente.saldo_cc + v_fiado > v_cliente.limite_cc then raise exception 'limite_cc_excedido'; end if;
    insert into public.cuenta_corriente_mov (negocio_id, cliente_id, tipo, monto, venta_id, usuario)
    values (p_negocio, p_cliente, 'venta_fiada', v_fiado, v_venta, auth.uid());
  end if;

  update public.ventas
     set subtotal = v_subtotal, descuento_pct = p_descuento_pct, descuento_monto = v_desc,
         redondeo = p_redondeo, total = v_total, estado = 'cobrada'
   where id = v_venta;

  if v_desc > 0 or v_override or p_redondeo <> 0 then
    insert into public.auditoria (negocio_id, usuario, accion, entidad, entidad_id, despues)
    values (p_negocio, auth.uid(), 'venta_con_ajustes', 'venta', v_venta,
            jsonb_build_object('descuento_pct', p_descuento_pct, 'descuento_monto', v_desc,
                               'precio_modificado', v_override, 'redondeo', p_redondeo));
  end if;

  return jsonb_build_object('id', v_venta, 'numero', v_numero, 'total', v_total,
                            'vuelto', v_vuelto_total, 'duplicada', false);

exception when unique_violation then
  -- Reintento concurrente con el mismo client_uuid: devolver la venta ya registrada
  select * into v_ex from public.ventas where negocio_id = p_negocio and client_uuid = p_client_uuid;
  if found then
    return jsonb_build_object('id', v_ex.id, 'numero', v_ex.numero, 'total', v_ex.total, 'duplicada', true);
  end if;
  raise;
end $$;

-- ───────────── RPC: anular venta (Fase 1: solo dentro del turno abierto) ─────────────
create or replace function public.anular_venta(p_venta uuid, p_motivo text, p_reintegrar_stock boolean default true)
returns void
language plpgsql security definer set search_path = public as $$
declare v public.ventas%rowtype; r record; v_fiado bigint;
begin
  select * into v from public.ventas where id = p_venta for update;
  if not found then raise exception 'venta_invalida'; end if;
  if not public.es_gestor(v.negocio_id) then raise exception 'sin_permiso'; end if;
  if v.estado <> 'cobrada' then raise exception 'venta_no_anulable'; end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then raise exception 'motivo_obligatorio'; end if;
  if not exists (select 1 from public.turnos_caja where id = v.turno_id and estado = 'abierto') then
    raise exception 'turno_cerrado: la anulación fuera de turno se habilita en la Fase 2 (devoluciones)';
  end if;

  update public.ventas set estado = 'cancelada', anulada_por = auth.uid(), anulada_ts = now(),
         anulada_motivo = p_motivo where id = p_venta;

  if p_reintegrar_stock then
    for r in select i.producto_id, i.cantidad, p.controla_stock
               from public.venta_items i join public.productos p on p.id = i.producto_id
              where i.venta_id = p_venta loop
      if r.controla_stock then
        insert into public.stock_movimientos (negocio_id, producto_id, tipo, cantidad, ref_tipo, ref_id, usuario, nota)
        values (v.negocio_id, r.producto_id, 'devolucion', r.cantidad, 'venta', p_venta, auth.uid(),
                'Anulación venta #' || v.numero);
      end if;
    end loop;
  end if;

  select coalesce(sum(monto), 0) into v_fiado from public.pagos where venta_id = p_venta and medio = 'cuenta_corriente';
  if v_fiado > 0 then
    insert into public.cuenta_corriente_mov (negocio_id, cliente_id, tipo, monto, venta_id, usuario, nota)
    values (v.negocio_id, v.cliente_id, 'anulacion', -v_fiado, p_venta, auth.uid(), 'Anulación venta #' || v.numero);
  end if;

  insert into public.auditoria (negocio_id, usuario, accion, entidad, entidad_id, despues)
  values (v.negocio_id, auth.uid(), 'anular_venta', 'venta', p_venta,
          jsonb_build_object('motivo', p_motivo, 'reintegra_stock', p_reintegrar_stock, 'total', v.total));
end $$;

-- ───────────── Permisos de ejecución ─────────────
revoke execute on all functions in schema public from public, anon;
grant execute on function public.rol_en(uuid), public.es_miembro(uuid), public.es_gestor(uuid), public.es_dueno(uuid),
  public.crear_negocio(text), public.siguiente_codigo(uuid), public.abrir_turno(uuid, bigint),
  public.cerrar_turno(uuid, bigint, text),
  public.registrar_venta(uuid, uuid, uuid, uuid, jsonb, jsonb, numeric, bigint, text, text),
  public.anular_venta(uuid, text, boolean)
  to authenticated;
