-- ARGYR · Actualización v2 — SOLO si ya tenés la base creada con la versión anterior.
-- Ejecutar UNA vez en Supabase → SQL Editor → New query → Run.
-- Agrega: detalle y productos vendidos por turno.

create or replace function public.estadisticas_turno(p_turno uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t public.turnos_caja%rowtype; r jsonb; e jsonb;
begin
  select * into t from public.turnos_caja where id = p_turno;
  if not found then raise exception 'turno_invalido'; end if;
  if not public.es_gestor(t.negocio_id) then raise exception 'sin_permiso'; end if;
  r := public.resumen_turno(p_turno);
  with it as (
    select vi.nombre, vi.unidad, vi.cantidad,
           (vi.total - round(vi.total * v.descuento_pct / 100)::bigint) as neto,
           (vi.total - round(vi.total * v.descuento_pct / 100)::bigint) - round(coalesce(vc.costo_unit, 0) * vi.cantidad)::bigint as ganancia
      from public.ventas v
      join public.venta_items vi on vi.venta_id = v.id
      left join public.venta_item_costos vc on vc.venta_item_id = vi.id
     where v.turno_id = p_turno and v.estado = 'cobrada'
  )
  select jsonb_build_object(
    'ganancia', coalesce((select sum(ganancia) from it), 0),
    'productos', coalesce((select jsonb_agg(jsonb_build_object('n', nombre, 'u', unidad, 'q', q, 'v', s) order by s desc)
                   from (select nombre, unidad, sum(cantidad) q, sum(neto) s from it group by nombre, unidad) x), '[]'::jsonb)
  ) into e;
  return r || e || jsonb_build_object(
    'apertura', t.apertura_ts, 'cierre', t.cierre_ts, 'estado', t.estado,
    'esperado', t.esperado_efectivo, 'conteo', t.conteo_efectivo, 'diferencia', t.diferencia,
    'gastos',  coalesce((select sum(monto) from public.movimientos_dinero where turno_id = p_turno and tipo = 'gasto'), 0),
    'retiros', coalesce((select sum(monto) from public.movimientos_dinero where turno_id = p_turno and tipo = 'retiro'), 0));
end $$;

grant execute on function public.estadisticas_turno(uuid) to authenticated;
