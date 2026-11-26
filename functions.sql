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

create or replace function public.trg_mov_dinero_turno() returns trigger language plpgsql as $$
begin
  if new.turno_id is not null and not exists (select 1 from public.turnos_caja where id = new.turno_id and estado = 'abierto') then
    raise exception 'turno_cerrado: no se pueden agregar movimientos a un turno cerrado';
  end if;
  return new;
end $$;
create trigger mov_dinero_turno before insert on public.movimientos_dinero
  for each row execute function public.trg_mov_dinero_turno();

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
  insert into public.categorias (negocio_id, nombre, orden) values (v_id, 'Verdulería', 1), (v_id, 'Carnicería', 2), (v_id, 'Kiosco', 3);
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

create or replace function public.resumen_turno(p_turno uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t public.turnos_caja%rowtype; r jsonb;
begin
  select * into t from public.turnos_caja where id = p_turno;
  if not found then raise exception 'turno_invalido'; end if;
  if not (public.es_gestor(t.negocio_id) or (public.rol_en(t.negocio_id) = 'cajero' and t.cajero_id = auth.uid())) then
    raise exception 'sin_permiso';
  end if;
  select jsonb_build_object(
    'fondo', t.fondo_inicial,
    'tickets',  (select count(*) from public.ventas v where v.turno_id = p_turno and v.estado = 'cobrada'),
    'anulados', (select count(*) from public.ventas v where v.turno_id = p_turno and v.estado = 'cancelada'),
    'total',    coalesce((select sum(v.total) from public.ventas v where v.turno_id = p_turno and v.estado = 'cobrada'), 0),
    'descuentos', coalesce((select sum(v.descuento_monto) from public.ventas v where v.turno_id = p_turno and v.estado = 'cobrada'), 0),
    'por_medio', (select coalesce(jsonb_object_agg(medio, m), '{}'::jsonb) from (
                    select p.medio, sum(p.monto) m from public.pagos p join public.ventas v on v.id = p.venta_id
                     where v.turno_id = p_turno and v.estado = 'cobrada' group by p.medio) x),
    'efectivo_cobrado', coalesce((select sum(p.monto) from public.pagos p join public.ventas v on v.id = p.venta_id
                     where v.turno_id = p_turno and v.estado = 'cobrada' and p.medio = 'efectivo'), 0),
    'ingresos', coalesce((select sum(monto) from public.movimientos_dinero where turno_id = p_turno and cuenta = 'efectivo' and tipo = 'ingreso'), 0),
    'egresos',  coalesce((select sum(monto) from public.movimientos_dinero where turno_id = p_turno and cuenta = 'efectivo' and tipo in ('gasto','retiro')), 0)
  ) into r;
  return r;
end $$;

create or replace function public.cerrar_turno(p_turno uuid, p_conteo bigint, p_obs text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.turnos_caja%rowtype; r jsonb; v_esp bigint; v_dif bigint;
begin
  select * into t from public.turnos_caja where id = p_turno for update;
  if not found then raise exception 'turno_invalido'; end if;
  if t.estado <> 'abierto' then raise exception 'turno_cerrado'; end if;
  if not (public.es_gestor(t.negocio_id) or (public.rol_en(t.negocio_id) = 'cajero' and t.cajero_id = auth.uid())) then
    raise exception 'sin_permiso';
  end if;
  if p_conteo is null or p_conteo < 0 then raise exception 'conteo_invalido'; end if;
  r := public.resumen_turno(p_turno);
  v_esp := (r->>'fondo')::bigint + (r->>'efectivo_cobrado')::bigint + (r->>'ingresos')::bigint - (r->>'egresos')::bigint;
  v_dif := p_conteo - v_esp;
  update public.turnos_caja
     set estado = 'cerrado', cierre_ts = now(), conteo_efectivo = p_conteo,
         esperado_efectivo = v_esp, diferencia = v_dif, resumen = r, observaciones = p_obs
   where id = p_turno;
  insert into public.auditoria (negocio_id, usuario, accion, entidad, entidad_id, despues)
  values (t.negocio_id, auth.uid(), 'cerrar_turno', 'turno', p_turno,
          jsonb_build_object('esperado', v_esp, 'conteo', p_conteo, 'diferencia', v_dif));
  return jsonb_build_object('esperado', v_esp, 'conteo', p_conteo, 'diferencia', v_dif, 'resumen', r);
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

-- ───────────── RPC: productos (alta/edición atómica: producto + precio + costo + stock) ─────────────
create or replace function public.guardar_producto(p_negocio uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_nuevo boolean := (nullif(p->>'id', '') is null);
  v_cat uuid; v_lista uuid;
  v_unidad text := coalesce(nullif(p->>'unidad', ''), 'unidad');
  v_precio bigint := coalesce((p->>'precio')::bigint, 0);
  v_costo bigint := coalesce((p->>'costo')::bigint, 0);
  v_delta numeric := coalesce((p->>'stock_delta')::numeric, 0);
  v_min numeric := coalesce((p->>'stock_minimo')::numeric, 0);
  v_fecha date := coalesce(nullif(p->>'fecha_ingreso', '')::date, current_date);
begin
  if not public.es_gestor(p_negocio) then raise exception 'sin_permiso'; end if;
  if nullif(trim(p->>'codigo'), '') is null or nullif(trim(p->>'nombre'), '') is null then
    raise exception 'datos_incompletos';
  end if;
  if v_precio < 0 or v_costo < 0 or v_min < 0 then raise exception 'valores_invalidos'; end if;

  if nullif(trim(p->>'categoria'), '') is not null then
    select id into v_cat from public.categorias
     where negocio_id = p_negocio and lower(nombre) = lower(trim(p->>'categoria'));
    if v_cat is null then
      insert into public.categorias (negocio_id, nombre, orden)
      values (p_negocio, trim(p->>'categoria'), (select coalesce(max(orden), 0) + 1 from public.categorias where negocio_id = p_negocio))
      returning id into v_cat;
    end if;
  end if;
  select id into v_lista from public.listas_precio where negocio_id = p_negocio and es_default;

  if v_nuevo then
    insert into public.productos (negocio_id, codigo, nombre, categoria_id, unidad, se_pesa, stock_minimo, fecha_ingreso)
    values (p_negocio, trim(p->>'codigo'), trim(p->>'nombre'), v_cat, v_unidad, v_unidad = 'kg', v_min, v_fecha)
    returning id into v_id;
  else
    update public.productos
       set codigo = trim(p->>'codigo'), nombre = trim(p->>'nombre'), categoria_id = v_cat, unidad = v_unidad,
           se_pesa = (v_unidad = 'kg'), stock_minimo = v_min, fecha_ingreso = v_fecha
     where id = v_id and negocio_id = p_negocio;
    if not found then raise exception 'producto_invalido'; end if;
  end if;

  insert into public.precios (negocio_id, producto_id, lista_id, precio) values (p_negocio, v_id, v_lista, v_precio)
  on conflict (producto_id, lista_id) do update set precio = excluded.precio;
  insert into public.producto_costos (producto_id, negocio_id, costo_ultimo, costo_promedio) values (v_id, p_negocio, v_costo, v_costo)
  on conflict (producto_id) do update set costo_ultimo = excluded.costo_ultimo, costo_promedio = excluded.costo_promedio;

  if v_delta <> 0 then
    insert into public.stock_movimientos (negocio_id, producto_id, tipo, cantidad, costo_unit, ref_tipo, usuario, nota)
    values (p_negocio, v_id, case when v_nuevo then 'inventario' else 'ajuste' end, v_delta, v_costo, 'producto', auth.uid(),
            case when v_nuevo then 'Stock inicial' else 'Ajuste manual' end);
  end if;
  return v_id;
end $$;

-- ───────────── RPC: gastos, retiros y cobro de deudas ─────────────
create or replace function public.registrar_movimiento(
  p_negocio uuid, p_tipo text, p_concepto text, p_categoria text, p_clase text, p_cuenta text, p_monto bigint
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_turno uuid; v_id uuid;
begin
  if not public.es_gestor(p_negocio) then raise exception 'sin_permiso'; end if;
  if p_tipo not in ('gasto','retiro') then raise exception 'tipo_invalido'; end if;
  if p_cuenta not in ('efectivo','transferencia') then raise exception 'cuenta_invalida'; end if;
  if p_monto is null or p_monto <= 0 then raise exception 'monto_invalido'; end if;
  select id into v_turno from public.turnos_caja where negocio_id = p_negocio and estado = 'abierto' limit 1;
  insert into public.movimientos_dinero (negocio_id, tipo, concepto, categoria, clase, cuenta, monto, turno_id, usuario)
  values (p_negocio, p_tipo, coalesce(nullif(trim(p_concepto), ''), initcap(p_tipo)), nullif(p_categoria, ''),
          case when p_tipo = 'gasto' then coalesce(nullif(p_clase, ''), 'variable') end, p_cuenta, p_monto, v_turno, auth.uid())
  returning id into v_id;
  insert into public.auditoria (negocio_id, usuario, accion, entidad, entidad_id, despues)
  values (p_negocio, auth.uid(), 'registrar_' || p_tipo, 'movimiento', v_id, jsonb_build_object('monto', p_monto, 'cuenta', p_cuenta));
  return v_id;
end $$;

create or replace function public.eliminar_movimiento(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.movimientos_dinero%rowtype;
begin
  select * into m from public.movimientos_dinero where id = p_id for update;
  if not found then raise exception 'movimiento_invalido'; end if;
  if not public.es_gestor(m.negocio_id) then raise exception 'sin_permiso'; end if;
  if m.tipo = 'ingreso' then raise exception 'movimiento_no_eliminable'; end if;
  if m.turno_id is not null and not exists (select 1 from public.turnos_caja where id = m.turno_id and estado = 'abierto') then
    raise exception 'turno_cerrado: pertenece a un turno cerrado';
  end if;
  delete from public.movimientos_dinero where id = p_id;
  insert into public.auditoria (negocio_id, usuario, accion, entidad, entidad_id, antes)
  values (m.negocio_id, auth.uid(), 'eliminar_movimiento', 'movimiento', p_id, to_jsonb(m));
end $$;

create or replace function public.cobrar_deuda(p_cliente uuid, p_monto bigint, p_medio text) returns void
language plpgsql security definer set search_path = public as $$
declare c public.clientes%rowtype; v_turno uuid;
begin
  select * into c from public.clientes where id = p_cliente for update;
  if not found then raise exception 'cliente_invalido'; end if;
  if not public.es_gestor(c.negocio_id) then raise exception 'sin_permiso'; end if;
  if p_medio not in ('efectivo','transferencia') then raise exception 'cuenta_invalida'; end if;
  if p_monto is null or p_monto <= 0 then raise exception 'monto_invalido'; end if;
  if p_monto > c.saldo_cc then raise exception 'pago_supera_deuda'; end if;
  select id into v_turno from public.turnos_caja where negocio_id = c.negocio_id and estado = 'abierto' limit 1;
  if p_medio = 'efectivo' and v_turno is null then raise exception 'turno_no_abierto'; end if;
  insert into public.cuenta_corriente_mov (negocio_id, cliente_id, tipo, monto, medio, usuario)
  values (c.negocio_id, c.id, 'pago', -p_monto, p_medio, auth.uid());
  insert into public.movimientos_dinero (negocio_id, tipo, concepto, cuenta, monto, cliente_id, turno_id, usuario)
  values (c.negocio_id, 'ingreso', 'Cobro de deuda · ' || c.nombre, p_medio, p_monto, c.id, v_turno, auth.uid());
end $$;

-- ───────────── Reportes calculados en el servidor ─────────────
-- Neto de cada línea = total de línea − su parte del descuento de la venta. Ganancia = neto − costo congelado.
create or replace function public.estadisticas(
  p_negocio uuid, p_desde timestamptz, p_hasta timestamptz,
  p_medio text default 'todos', p_categoria uuid default null, p_producto uuid default null, p_cliente text default ''
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.es_gestor(p_negocio) then raise exception 'sin_permiso'; end if;
  with vf as (
    select v.id, v.ts, v.total, v.descuento_pct
      from public.ventas v
     where v.negocio_id = p_negocio and v.estado = 'cobrada' and v.ts >= p_desde and v.ts < p_hasta
       and (p_medio = 'todos' or exists (select 1 from public.pagos pg where pg.venta_id = v.id and pg.medio = p_medio))
       and (coalesce(p_cliente, '') = '' or (p_cliente = '0' and v.cliente_id is null) or v.cliente_id::text = p_cliente)
  ), it as (
    select vf.id as venta_id, vf.ts, vf.total as vtotal, vi.nombre, coalesce(c.nombre, '—') as categoria,
           (vi.total - round(vi.total * vf.descuento_pct / 100)::bigint) as neto,
           (vi.total - round(vi.total * vf.descuento_pct / 100)::bigint) - round(coalesce(vc.costo_unit, 0) * vi.cantidad)::bigint as ganancia
      from vf
      join public.venta_items vi on vi.venta_id = vf.id
      join public.productos p on p.id = vi.producto_id
      left join public.categorias c on c.id = p.categoria_id
      left join public.venta_item_costos vc on vc.venta_item_id = vi.id
     where (p_categoria is null or p.categoria_id = p_categoria) and (p_producto is null or vi.producto_id = p_producto)
  ), rv as (
    select venta_id, sum(neto) as rv, max(vtotal) as vtotal from it group by venta_id
  )
  select jsonb_build_object(
    'total',    coalesce((select sum(neto) from it), 0),
    'tickets',  (select count(*) from rv),
    'ganancia', coalesce((select sum(ganancia) from it), 0),
    'por_producto', coalesce((select jsonb_agg(jsonb_build_object('n', nombre, 'v', s) order by s desc)
                       from (select nombre, sum(neto) s from it group by nombre order by s desc limit 8) x), '[]'::jsonb),
    'por_categoria', coalesce((select jsonb_agg(jsonb_build_object('n', categoria, 'v', s) order by s desc)
                       from (select categoria, sum(neto) s from it group by categoria order by s desc limit 8) x), '[]'::jsonb),
    'por_medio', coalesce((select jsonb_object_agg(medio, m) from (
                       select pg.medio, round(sum(pg.monto::numeric * rv.rv / nullif(rv.vtotal, 0)))::bigint m
                         from rv join public.pagos pg on pg.venta_id = rv.venta_id group by pg.medio) y), '{}'::jsonb),
    'por_hora', coalesce((select jsonb_agg(jsonb_build_object('h', h, 'v', s)) from (
                       select extract(hour from ts at time zone 'America/Argentina/Buenos_Aires')::int h, sum(neto) s from it group by 1) z), '[]'::jsonb),
    'por_dow',  coalesce((select jsonb_agg(jsonb_build_object('d', d, 'v', s)) from (
                       select extract(isodow from ts at time zone 'America/Argentina/Buenos_Aires')::int d, sum(neto) s from it group by 1) w), '[]'::jsonb),
    'serie',    coalesce((select jsonb_agg(jsonb_build_object('d', d, 'v', s) order by d) from (
                       select (ts at time zone 'America/Argentina/Buenos_Aires')::date d, sum(neto) s from it group by 1) u), '[]'::jsonb)
  ) into r;
  return r;
end $$;

create or replace function public.resumen_periodo(p_negocio uuid, p_desde timestamptz, p_hasta timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e jsonb;
begin
  if not public.es_gestor(p_negocio) then raise exception 'sin_permiso'; end if;
  e := public.estadisticas(p_negocio, p_desde, p_hasta, 'todos', null, null, '');
  return jsonb_build_object(
    'total', e->'total', 'tickets', e->'tickets', 'ganancia', e->'ganancia',
    'por_medio', (select coalesce(jsonb_object_agg(medio, m), '{}'::jsonb) from (
                    select p.medio, sum(p.monto) m from public.pagos p join public.ventas v on v.id = p.venta_id
                     where v.negocio_id = p_negocio and v.estado = 'cobrada' and v.ts >= p_desde and v.ts < p_hasta group by p.medio) x),
    'gastos',       coalesce((select sum(monto) from public.movimientos_dinero where negocio_id = p_negocio and tipo = 'gasto' and ts >= p_desde and ts < p_hasta), 0),
    'gastos_fijos', coalesce((select sum(monto) from public.movimientos_dinero where negocio_id = p_negocio and tipo = 'gasto' and clase = 'fijo' and ts >= p_desde and ts < p_hasta), 0),
    'retiros',      coalesce((select sum(monto) from public.movimientos_dinero where negocio_id = p_negocio and tipo = 'retiro' and ts >= p_desde and ts < p_hasta), 0),
    'cobros_deuda', coalesce((select sum(monto) from public.movimientos_dinero where negocio_id = p_negocio and tipo = 'ingreso' and ts >= p_desde and ts < p_hasta), 0)
  );
end $$;

create or replace function public.clientes_periodo(p_negocio uuid, p_desde timestamptz, p_hasta timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_gestor(p_negocio) then raise exception 'sin_permiso'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', cliente_id, 'n', n, 't', t)) from (
            select v.cliente_id, count(*) n, sum(v.total) t from public.ventas v
             where v.negocio_id = p_negocio and v.estado = 'cobrada' and v.cliente_id is not null
               and v.ts >= p_desde and v.ts < p_hasta group by v.cliente_id) x), '[]'::jsonb);
end $$;

-- ───────────── Datos de ejemplo (solo si el negocio no tiene productos) ─────────────
create or replace function public.cargar_ejemplo(p_negocio uuid) returns int
language plpgsql security definer set search_path = public as $$
declare it jsonb; n int := 0;
begin
  if not public.es_gestor(p_negocio) then raise exception 'sin_permiso'; end if;
  if exists (select 1 from public.productos where negocio_id = p_negocio) then raise exception 'ya_hay_productos'; end if;
  for it in select * from jsonb_array_elements('[
    {"codigo":"000701","nombre":"Tomate","categoria":"Verdulería","unidad":"kg","precio":220000,"costo":150000,"stock_delta":20,"stock_minimo":5},
    {"codigo":"000702","nombre":"Papa","categoria":"Verdulería","unidad":"kg","precio":120000,"costo":80000,"stock_delta":35,"stock_minimo":8},
    {"codigo":"000703","nombre":"Cebolla","categoria":"Verdulería","unidad":"kg","precio":110000,"costo":70000,"stock_delta":25,"stock_minimo":6},
    {"codigo":"000704","nombre":"Banana","categoria":"Verdulería","unidad":"kg","precio":180000,"costo":120000,"stock_delta":15,"stock_minimo":4},
    {"codigo":"000706","nombre":"Lechuga","categoria":"Verdulería","unidad":"unidad","precio":90000,"costo":55000,"stock_delta":18,"stock_minimo":5},
    {"codigo":"000123","nombre":"Milanesa vacuna","categoria":"Carnicería","unidad":"kg","precio":980000,"costo":607600,"stock_delta":12.4,"stock_minimo":3},
    {"codigo":"000124","nombre":"Carne picada","categoria":"Carnicería","unidad":"kg","precio":820000,"costo":533000,"stock_delta":18,"stock_minimo":3},
    {"codigo":"000131","nombre":"Pollo entero","categoria":"Carnicería","unidad":"kg","precio":390000,"costo":276900,"stock_delta":8,"stock_minimo":5},
    {"codigo":"000140","nombre":"Chorizo","categoria":"Carnicería","unidad":"kg","precio":650000,"costo":455000,"stock_delta":9,"stock_minimo":3},
    {"codigo":"000210","nombre":"Alfajor triple","categoria":"Kiosco","unidad":"unidad","precio":120000,"costo":70800,"stock_delta":48,"stock_minimo":10},
    {"codigo":"000220","nombre":"Papas fritas","categoria":"Kiosco","unidad":"unidad","precio":170000,"costo":121000,"stock_delta":25,"stock_minimo":8},
    {"codigo":"000305","nombre":"Gaseosa 1,5 L","categoria":"Kiosco","unidad":"unidad","precio":180000,"costo":131400,"stock_delta":36,"stock_minimo":12},
    {"codigo":"000411","nombre":"Pan francés","categoria":"Kiosco","unidad":"kg","precio":250000,"costo":175000,"stock_delta":6,"stock_minimo":2},
    {"codigo":"000601","nombre":"Yerba 1 kg","categoria":"Kiosco","unidad":"unidad","precio":420000,"costo":319000,"stock_delta":22,"stock_minimo":6}
  ]'::jsonb) loop
    perform public.guardar_producto(p_negocio, it);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ───────────── Permisos de ejecución ─────────────
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.f_norm(text), public.rol_en(uuid), public.es_miembro(uuid), public.es_gestor(uuid), public.es_dueno(uuid),
  public.crear_negocio(text), public.siguiente_codigo(uuid), public.abrir_turno(uuid, bigint),
  public.resumen_turno(uuid), public.cerrar_turno(uuid, bigint, text),
  public.registrar_venta(uuid, uuid, uuid, uuid, jsonb, jsonb, numeric, bigint, text, text),
  public.anular_venta(uuid, text, boolean), public.guardar_producto(uuid, jsonb),
  public.registrar_movimiento(uuid, text, text, text, text, text, bigint), public.eliminar_movimiento(uuid),
  public.cobrar_deuda(uuid, bigint, text),
  public.estadisticas(uuid, timestamptz, timestamptz, text, uuid, uuid, text),
  public.resumen_periodo(uuid, timestamptz, timestamptz), public.clientes_periodo(uuid, timestamptz, timestamptz),
  public.cargar_ejemplo(uuid)
  to authenticated;
